import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:falcon_one_demo/controllers/map_controller.dart';
import 'package:falcon_one_demo/data/call_service.dart';
import 'package:falcon_one_demo/widgets/bodycam_stream_widget.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

/// Full-screen livestream view.
///
/// Reached by swiping right-to-left from the main map ([MapView]). Shows live
/// video and lets the agent publish their phone camera to the Agora channel:
///   • If the bodycam (Agora UID 9001) is live, its video is shown — the
///     bodycam is the source of truth when connected.
///   • Otherwise the phone's own camera is previewed locally, and the
///     livestream button publishes it to the channel so other agents can watch.
///
/// Saving the stream as incident evidence (Nexus / Agora Cloud Recording) is
/// handled server-side and wired separately; this screen only drives the live
/// transport.
class CameraLivestreamView extends StatefulWidget {
  const CameraLivestreamView({super.key});

  @override
  State<CameraLivestreamView> createState() => _CameraLivestreamViewState();
}

enum _CamState { initializing, ready, error, noPermission, noAgora }

class _CameraLivestreamViewState extends State<CameraLivestreamView> {
  CallService? _call;
  _CamState _state = _CamState.initializing;
  String _detail = '';

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _state = _CamState.noPermission;
        _detail = 'Permiso de cámara denegado';
      });
      return;
    }

    final call = Get.isRegistered<CallService>() ? Get.find<CallService>() : null;
    if (call == null || !call.isInitialized) {
      setState(() {
        _state = _CamState.noAgora;
        _detail = 'Conexión Agora no disponible';
      });
      return;
    }
    _call = call;

    // Opening this screen IS the "go live" gesture: if the bodycam isn't the
    // source, start publishing the phone camera to Agora right away. When the
    // bodycam is live it's the source of truth, so we don't publish the phone.
    if (!call.bodyCamVideoActive) {
      await call.startCameraPublish();
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

    if (call.isPublishingCamera) {
      await call.stopCameraPublish();
    } else {
      await call.startCameraPublish();
    }
  }

  Future<void> _flipCamera() async {
    await _call?.switchCamera();
  }

  @override
  void dispose() {
    // Stop sending and turn the camera off when leaving the screen.
    _call?.stopCameraPublish(stopPreview: true);
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
            if (_state == _CamState.ready) _buildControls(),
            if (_state == _CamState.ready) _buildLiveBadge(),
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
          'Abriendo cámara…',
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
          'Error de cámara\n$_detail',
        );
      case _CamState.ready:
        return _buildPreview();
    }
  }

  /// Fills the screen with the active video source.
  Widget _buildPreview() {
    final call = _call;
    if (call == null) return const SizedBox.shrink();
    return Obx(() {
      // Bodycam is the source of truth whenever it's live in the channel.
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
              tooltip: 'Volver al mapa',
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
