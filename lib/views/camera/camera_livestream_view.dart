import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:falcon_one_demo/controllers/map_controller.dart';
import 'package:falcon_one_demo/data/call_service.dart';
import 'package:falcon_one_demo/views/emergency/emergency_dialogs.dart';
import 'package:falcon_one_demo/widgets/bodycam_stream_widget.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

/// Full-screen livestream view, with two modes:
///
/// • PUBLISH mode (default — reached by swiping right-to-left from the map):
///   shows live video and lets the agent publish their own phone camera. If the
///   bodycam (Agora UID 9001) is live it's shown as the source of truth;
///   otherwise the phone's own camera is PREVIEWED only. Opening the screen does
///   NOT auto-go-live (disabled 2026-06-02): the user must tap the livestream
///   button to start publishing. See the AUTO-GO-LIVE note in _prepare.
///
/// • WATCH mode ([watchUid] != null — opened from an incoming emergency popup):
///   renders the video of the agent/bodycam that raised the signal (their Agora
///   uid) WITHOUT publishing this phone's camera. uid 9001 = the bodycam, any
///   other uid = another agent's phone. This is what differentiates whether the
///   signal came from a phone or from the bodycam.
///
/// Saving the stream as incident evidence (Nexus / Agora Cloud Recording) is
/// handled server-side and wired separately; this screen only drives the live
/// transport.
class CameraLivestreamView extends StatefulWidget {
  const CameraLivestreamView({super.key, this.watchUid, this.agentLabel});

  /// When non-null, render this remote participant's video instead of going
  /// live with our own camera. 9001 = bodycam, anything else = another phone.
  final int? watchUid;

  /// When non-null, the watched source is presented as an EXTERNAL AGENT: the
  /// badge shows the agent tag ("LIVE · <label>") and a "Signal cut" notice
  /// pops when the feed dies — even for the bodycam (the demo's external-agent
  /// simulation). When null, the bodycam reads "REC · BODYCAM" with no cut alarm.
  final String? agentLabel;

  @override
  State<CameraLivestreamView> createState() => _CameraLivestreamViewState();
}

enum _CamState { initializing, ready, error, noPermission, noAgora }

class _CameraLivestreamViewState extends State<CameraLivestreamView> {
  CallService? _call;
  _CamState _state = _CamState.initializing;
  String _detail = '';

  // Watch mode: fires when the source we're watching stops, to show the cut
  // notice exactly once.
  Worker? _sourceStoppedWorker;
  bool _cutShown = false;

  // Watch mode: whether we've silenced the source we're listening to.
  bool _audioMuted = false;

  bool get _isWatching => widget.watchUid != null;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    // WATCH mode renders a remote source — no local capture, so no permissions
    // needed. PUBLISH mode needs camera + microphone (the livestream now carries
    // the agent's voice, so the mic must be granted to broadcast audio).
    if (!_isWatching) {
      final camera = await Permission.camera.request();
      if (!camera.isGranted) {
        setState(() {
          _state = _CamState.noPermission;
          _detail = 'Camera permission denied';
        });
        return;
      }
      // Mic is best-effort: if denied we still go live, just without voice.
      await Permission.microphone.request();
    }

    final call = Get.isRegistered<CallService>() ? Get.find<CallService>() : null;
    if (call == null || !call.isInitialized) {
      setState(() {
        _state = _CamState.noAgora;
        _detail = 'Agora connection unavailable';
      });
      return;
    }
    _call = call;

    if (_isWatching) {
      // A receiver must be strictly receive-only — stop publishing camera+mic
      // and turn mic capture OFF so our own voice/video can never leak into the
      // stream we're only meant to be watching.
      await call.ensureReceiveOnly();
      // Just subscribe to the source's video + audio; never publish our own
      // camera/mic. Unmute the source's audio so we hear it by default.
      await call.watchRemoteVideo(widget.watchUid!);
      await call.setRemoteAudioMuted(uid: widget.watchUid!, muted: false);
      // When the source's feed dies (publisher stops / goes offline), show a
      // closable "Signal cut" notice over the frozen frame, with the emitter's
      // last known location reverse-geocoded to city/country.
      _sourceStoppedWorker = ever<int?>(call.remoteVideoStoppedRx, (uid) {
        if (uid != widget.watchUid || _cutShown || !mounted) return;
        // For the bodycam, only show the cut notice when it's the external-agent
        // simulation (agentLabel set). A bodycam watched as "own" has no alarm.
        final isBodycam = uid == CallService.bodyCamAgoraUid;
        if (isBodycam && widget.agentLabel == null) return;
        _cutShown = true;
        // The bodycam has no GPS of its own → fall back to THIS phone's location
        // (it's co-located with the bodycam). Agent phones carry their own GPS.
        final loc = isBodycam
            ? call.localLocationRx.value
            : call.remoteLocation(widget.watchUid!);
        showSignalCutDialog(
          time: DateTime.now(),
          latitude: loc?.latitude,
          longitude: loc?.longitude,
        );
      });
    } else {
      // ── AUTO-GO-LIVE: DISABLED (2026-06-02) ───────────────────────────────
      // Opening this screen no longer starts the livestream automatically. We
      // only PREVIEW the phone camera; the user must tap the livestream button
      // (_toggleLivestream) to actually publish. To restore auto-go-live, swap
      // startLocalPreview() back for startCameraPublish() here.
      if (!call.bodyCamVideoActive) {
        await call.startLocalPreview();
      }
    }
    if (!mounted) return;
    setState(() => _state = _CamState.ready);
  }

  Future<void> _toggleLivestream() async {
    final call = _call;
    if (call == null) return;

    // When the bodycam is the live source, "stop" means telling the bodycam to
    // stop emitting (STREAM_STOP over BT) via the map controller — just hiding
    // it locally wouldn't cut the actual signal.
    if (call.bodyCamVideoActive) {
      final map = Get.isRegistered<MapController>()
          ? Get.find<MapController>()
          : null;
      await map?.stopStream();
      // Bodycam gone: fall back to the phone camera preview (idle, not live).
      if (!call.bodyCamVideoActive) {
        await call.startLocalPreview();
      }
      return;
    }

    // Phone camera: this button is now the ONLY way to go live (auto-go-live on
    // open was disabled 2026-06-02). Tap to start publishing, tap again to stop.
    if (call.isPublishingCamera) {
      await call.stopCameraPublish();
    } else {
      await call.startCameraPublish();
    }
  }

  Future<void> _flipCamera() async {
    await _call?.switchCamera();
  }

  /// WATCH mode: mute/unmute the audio of the source we're listening to.
  Future<void> _toggleWatchAudio() async {
    final call = _call;
    if (call == null) return;
    final next = !_audioMuted;
    await call.setRemoteAudioMuted(uid: widget.watchUid!, muted: next);
    setState(() => _audioMuted = next);
  }

  /// PUBLISH mode: mute/unmute our OUTGOING mic while live (broadcast voice).
  Future<void> _toggleBroadcastMic() async {
    final call = _call;
    if (call == null) return;
    // isPublishingAudio == true means mic is live → tap mutes it, and vice versa.
    await call.setBroadcastMicMuted(call.isPublishingAudio);
  }

  @override
  void dispose() {
    _sourceStoppedWorker?.dispose();
    final call = _call;
    if (!_isWatching) {
      // Stop sending and turn the camera off when leaving the screen.
      call?.stopCameraPublish(stopPreview: true);
    } else if (call != null) {
      // Stop pulling the watched source's audio on leave so it doesn't keep
      // playing on the map (audio is on-demand now). For the bodycam, fall back
      // to the panel's mute state instead of forcing it muted.
      final uid = widget.watchUid!;
      final restoreMuted = uid == CallService.bodyCamAgoraUid
          ? call.isMicrophoneMuted
          : true;
      call.setRemoteAudioMuted(uid: uid, muted: restoreMuted);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // Swipe left-to-right anywhere to return to the map.
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v > 250) Get.back();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildVideoArea(),
            _buildTopBar(),
            _buildBackHint(),
            // Publish controls + LIVE badge only make sense when we're the
            // source. In watch mode we show a "viewing source" badge instead.
            if (_state == _CamState.ready && !_isWatching) _buildControls(),
            if (_state == _CamState.ready && !_isWatching) _buildLiveBadge(),
            if (_state == _CamState.ready && _isWatching) _buildWatchBadge(),
            if (_state == _CamState.ready && _isWatching) _buildWatchControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    switch (_state) {
      case _CamState.initializing:
        return _centerInfo(
          const CircularProgressIndicator(color: Colors.white54),
          _isWatching ? 'Connecting to source…' : 'Opening camera…',
        );
      case _CamState.noPermission:
        return _centerInfo(
          const Icon(Icons.no_photography, color: Colors.white38, size: 40),
          _detail,
        );
      case _CamState.noAgora:
        return _centerInfo(
          const Icon(Icons.cloud_off, color: Colors.white38, size: 40),
          _detail,
        );
      case _CamState.error:
        return _centerInfo(
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
          'Camera error\n$_detail',
        );
      case _CamState.ready:
        return _buildPreview();
    }
  }

  /// Fills the screen with the active video source.
  Widget _buildPreview() {
    final call = _call;
    if (call == null) return const SizedBox.shrink();

    // WATCH mode: render the remote source that raised the signal.
    if (_isWatching) {
      final watchUid = widget.watchUid!;
      // The bodycam (uid 9001) has its own widget (handles rotation + status).
      if (watchUid == CallService.bodyCamAgoraUid) {
        return const BodyCamStreamWidget(borderRadius: 0);
      }
      // Another agent's phone camera — render their remote Agora video.
      return AgoraVideoView(
        controller: VideoViewController.remote(
          rtcEngine: call.engine,
          canvas: VideoCanvas(uid: watchUid),
          connection: RtcConnection(channelId: call.config.channelId),
          useFlutterTexture: true,
        ),
      );
    }

    return Obx(() {
      // PUBLISH mode. Bodycam is the source of truth whenever it's live.
      if (call.bodyCamVideoUidRx.value != null) {
        return const BodyCamStreamWidget(borderRadius: 0);
      }
      // Otherwise show the phone's own camera (Agora local view, uid 0).
      return AgoraVideoView(
        controller: VideoViewController(
          rtcEngine: call.engine,
          canvas: const VideoCanvas(uid: 0),
          useFlutterTexture: true,
        ),
      );
    });
  }

  /// Badge shown in watch mode. An external-agent feed (incl. the bodycam
  /// simulated as one — [agentLabel] set) reads `LIVE · {agent}`; a bodycam
  /// watched as our own reads `REC · BODYCAM`.
  Widget _buildWatchBadge() {
    final isBodycam = widget.watchUid == CallService.bodyCamAgoraUid;
    final label = widget.agentLabel;
    final external = label != null;
    final text = external
        ? 'LIVE · ${label.toUpperCase()}'
        : (isBodycam ? 'REC · BODYCAM' : 'LIVE · OFFICER');
    final bodycamRec = isBodycam && !external;
    return Positioned(
      top: 0,
      right: 12,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.red,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(bodycamRec ? Icons.fiber_manual_record : Icons.circle,
                  color: Colors.white, size: bodycamRec ? 10 : 8),
              const SizedBox(width: 4),
              Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(8, 8, 12, 0),
        child: Row(
          children: [
            IconButton(
              onPressed: Get.back,
              icon: const Icon(Icons.chevron_left, color: Colors.white),
              tooltip: 'Back to map',
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  /// Red LIVE pill shown while publishing the phone camera, or while the
  /// bodycam is the live source.
  Widget _buildLiveBadge() {
    final call = _call;
    if (call == null) return const SizedBox.shrink();
    return Obx(() {
      final live =
          call.isPublishingCameraRx.value || call.bodyCamVideoUidRx.value != null;
      if (!live) return const SizedBox.shrink();
      return Positioned(
        top: 0,
        right: 12,
        child: SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, color: Colors.white, size: 8),
                SizedBox(width: 4),
                Text(
                  'LIVE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildControls() {
    final call = _call;
    if (call == null) return const SizedBox.shrink();
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        minimum: const EdgeInsets.only(bottom: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Livestream toggle. Red while live (phone publishing OR bodycam as
            // source); tapping stops whichever source is live.
            Obx(() {
              final bodycamLive = call.bodyCamVideoUidRx.value != null;
              final publishing = call.isPublishingCameraRx.value;
              final live = publishing || bodycamLive;
              return _circleButton(
                icon: live ? Icons.sensors : Icons.sensors_off,
                color: live ? Colors.red : Colors.white,
                size: 64,
                iconSize: 30,
                onTap: _toggleLivestream,
              );
            }),
            const SizedBox(width: 28),
            // Broadcast mic toggle. Only actionable while live (publishing or
            // bodycam source); reflects whether our outgoing voice is on.
            Obx(() {
              final live = call.isPublishingCameraRx.value ||
                  call.bodyCamVideoUidRx.value != null;
              final micOn = call.isPublishingAudioRx.value;
              return _circleButton(
                icon: micOn ? Icons.mic : Icons.mic_off,
                color: micOn ? Colors.white : Colors.redAccent,
                size: 52,
                iconSize: 24,
                onTap: (live && call.isPublishingCameraRx.value)
                    ? _toggleBroadcastMic
                    : null,
              );
            }),
            const SizedBox(width: 28),
            _circleButton(
              icon: Icons.cameraswitch,
              color: Colors.white,
              size: 52,
              iconSize: 24,
              onTap: _flipCamera,
            ),
          ],
        ),
      ),
    );
  }

  /// WATCH mode controls: a single listen/mute toggle so the receiver can
  /// silence or restore the source's audio.
  Widget _buildWatchControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        minimum: const EdgeInsets.only(bottom: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _circleButton(
              icon: _audioMuted ? Icons.volume_off : Icons.volume_up,
              color: _audioMuted ? Colors.redAccent : Colors.white,
              size: 60,
              iconSize: 28,
              onTap: _toggleWatchAudio,
            ),
          ],
        ),
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    required Color color,
    required double size,
    required double iconSize,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1.0,
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Colors.black45,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: iconSize),
        ),
      ),
    );
  }

  Widget _centerInfo(Widget icon, String label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// Left-edge hint reinforcing the swipe-back affordance.
  Widget _buildBackHint() {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          width: 26,
          height: 64,
          decoration: const BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.only(
              topRight: Radius.circular(12),
              bottomRight: Radius.circular(12),
            ),
          ),
          child: const Icon(Icons.chevron_left, color: Colors.white70, size: 20),
        ),
      ),
    );
  }
}
