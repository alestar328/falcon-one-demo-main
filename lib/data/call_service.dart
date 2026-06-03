import 'dart:async';
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:falcon_one_demo/utils/call_foreground_task.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';

class AgoraCallConfig {
  /// Configuration values required to establish an Agora RTC session.
  const AgoraCallConfig({
    required this.appId,
    this.token,
    this.channelId = _defaultChannelId,
    this.localUid = 0,
  });

  final String appId;
  final String? token;
  final String channelId;
  final int localUid;

  static const String _defaultChannelId = 'falcon_group_channel';
}

class ParticipantLocation {
  /// Represents a participant location payload exchanged over the Agora data stream.
  const ParticipantLocation({
    required this.uid,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
  });

  final int uid;
  final double latitude;
  final double longitude;
  final DateTime timestamp;

  /// Returns a copy with any provided fields replaced.
  ParticipantLocation copyWith({
    int? uid,
    double? latitude,
    double? longitude,
    DateTime? timestamp,
  }) {
    return ParticipantLocation(
      uid: uid ?? this.uid,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  /// Serialises this location into a JSON payload for transmission.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'location',
      'uid': uid,
      'lat': latitude,
      'lng': longitude,
      'ts': timestamp.millisecondsSinceEpoch,
    };
  }

  /// Builds a [ParticipantLocation] from a JSON payload received over the wire.
  factory ParticipantLocation.fromJson(Map<String, dynamic> json) {
    final dynamic timestampValue = json['ts'];
    DateTime resolvedTimestamp;
    if (timestampValue is int) {
      resolvedTimestamp = DateTime.fromMillisecondsSinceEpoch(
        timestampValue,
        isUtc: true,
      ).toLocal();
    } else if (timestampValue is String) {
      resolvedTimestamp =
          DateTime.tryParse(timestampValue)?.toLocal() ?? DateTime.now();
    } else {
      resolvedTimestamp = DateTime.now();
    }

    final dynamic uidValue = json['uid'];

    return ParticipantLocation(
      uid: uidValue is int
          ? uidValue
          : int.tryParse(uidValue?.toString() ?? '') ?? 0,
      latitude: (json['lat'] as num).toDouble(),
      longitude: (json['lng'] as num).toDouble(),
      timestamp: resolvedTimestamp,
    );
  }
}

/// An emergency/recording signal exchanged over the Agora data stream. Emitted
/// when an agent presses the map livestream button; received by every OTHER
/// device in the channel (Agora never echoes a sender its own data messages, so
/// the trigger naturally never popups on the sender itself).
class EmergencySignal {
  const EmergencySignal({
    required this.officer,
    required this.uid,
    required this.timestamp,
    this.latitude,
    this.longitude,
  });

  /// Officer code of the broadcasting agent (e.g. 'off-001'). Shown to the
  /// receiver as the source of the emergency.
  final String officer;
  final int uid;

  /// Time the SOS SESSION started. Stable across heartbeat re-broadcasts so
  /// receivers can dedupe (uid + ts) and only alert once per emergency.
  final DateTime timestamp;

  /// Emitter's location at the time of the SOS, if known.
  final double? latitude;
  final double? longitude;

  /// Stable per-session key used to dedupe heartbeat repeats.
  String get sessionKey => '$uid@${timestamp.millisecondsSinceEpoch}';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': 'emergency',
        'officer': officer,
        'uid': uid,
        'ts': timestamp.millisecondsSinceEpoch,
        if (latitude != null) 'lat': latitude,
        if (longitude != null) 'lng': longitude,
      };

  factory EmergencySignal.fromJson(Map<String, dynamic> json, {int? uid}) {
    final dynamic ts = json['ts'];
    final DateTime resolved = ts is int
        ? DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true).toLocal()
        : DateTime.now();
    final dynamic rawUid = json['uid'];
    final dynamic lat = json['lat'];
    final dynamic lng = json['lng'];
    return EmergencySignal(
      officer: (json['officer'] ?? '').toString(),
      uid: uid ??
          (rawUid is int ? rawUid : int.tryParse(rawUid?.toString() ?? '') ?? 0),
      timestamp: resolved,
      latitude: lat is num ? lat.toDouble() : null,
      longitude: lng is num ? lng.toDouble() : null,
    );
  }
}

/// Cancellation of a previously broadcast emergency. Carries the emitter's last
/// known location (if available) and the time it cut the signal, so receivers
/// can show a "Signal cut at <time> — location: …" notice.
class EmergencyCancel {
  const EmergencyCancel({
    required this.officer,
    required this.uid,
    required this.timestamp,
    this.latitude,
    this.longitude,
  });

  final String officer;
  final int uid;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;

  factory EmergencyCancel.fromJson(Map<String, dynamic> json, {int? uid}) {
    final dynamic ts = json['ts'];
    final DateTime resolved = ts is int
        ? DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true).toLocal()
        : DateTime.now();
    final dynamic rawUid = json['uid'];
    final dynamic lat = json['lat'];
    final dynamic lng = json['lng'];
    return EmergencyCancel(
      officer: (json['officer'] ?? '').toString(),
      uid: uid ??
          (rawUid is int ? rawUid : int.tryParse(rawUid?.toString() ?? '') ?? 0),
      timestamp: resolved,
      latitude: lat is num ? lat.toDouble() : null,
      longitude: lng is num ? lng.toDouble() : null,
    );
  }
}

class CallService extends GetxService {
  /// Manages the shared Agora channel, audio state, and per-user location updates.
  CallService({required AgoraCallConfig config}) : _config = config;

  final AgoraCallConfig _config;
  final RxBool _hasJoined = false.obs;
  final RxBool _isMicrophoneMuted = false.obs;
  final RxBool _isSpeakerMuted = false.obs;
  final RxMap<int, ParticipantLocation> _remoteLocations =
      <int, ParticipantLocation>{}.obs;
  final Rxn<ParticipantLocation> _localLocation = Rxn<ParticipantLocation>();
  final RxInt _satelliteCount = 0.obs;
  final RxInt _connectedUsersCount = 0.obs;

  RtcEngine? _engine;
  bool _isInitialized = false;
  StreamSubscription<Position>? _positionSubscription;
  int? _locationStreamId;
  int? _currentUid;
  Timer? _locationHeartbeatTimer;
  DateTime? _lastLocationSendAt;

  // Last time we received a data-stream message from each remote uid. The
  // marker itself is kept indefinitely (last-known position) so an agent that
  // loses signal — e.g. driving through a tunnel — does NOT vanish from the
  // map; it is only removed on a graceful quit / channel leave. Consumers read
  // [remoteLastSeen] to tell whether a peer has gone silent ("lost signal")
  // and how stale its position is.
  final Map<int, DateTime> _remoteLastSeen = <int, DateTime>{};
  static const Duration _minSendInterval = Duration(seconds: 1);

  // UID fijo de la bodycam en Agora — se activa cuando el dispositivo emite video
  static const int bodyCamAgoraUid = 9001;
  final Rxn<int> _bodyCamVideoUid = Rxn<int>();

  // True while THIS phone is publishing its own camera to the channel (the
  // local agent's livestream). Independent of the bodycam (uid 9001).
  final RxBool _isPublishingCamera = false.obs;

  // True while THIS phone is publishing its microphone (broadcasting voice with
  // the livestream). Goes on together with the camera in [startCameraPublish],
  // but the agent can mute/unmute it independently via [setBroadcastMicMuted].
  final RxBool _isPublishingAudio = false.obs;

  // Pending snapshot capture; completed by onSnapshotTaken with the saved file
  // path (or null on failure).
  Completer<String?>? _snapshotCompleter;

  // Set to a remote AGENT's uid (never the bodycam) the moment its video stops
  // — the publisher muted/stopped it or went offline. The livestream WATCH view
  // watches this to show a "Signal cut" notice over the frozen last frame.
  // Reset to null when that uid's video resumes.
  final Rxn<int> _remoteVideoStopped = Rxn<int>();

  // Latest emergency signal received from another agent over the data stream.
  // Consumers (MapController) react and then clear it via [consumeEmergency].
  final Rxn<EmergencySignal> _incomingEmergency = Rxn<EmergencySignal>();

  // Set each time a remote agent cancels their emergency, carrying the emitter's
  // last location + cut time. Consumers dismiss the popup, stop the siren, and
  // show a "Signal cut" notice, then clear it via [consumeEmergencyCancel].
  final Rxn<EmergencyCancel> _incomingEmergencyCancel = Rxn<EmergencyCancel>();

  bool get isInitialized => _isInitialized;
  bool get hasJoinedChannel => _hasJoined.value;
  bool get isMicrophoneMuted => _isMicrophoneMuted.value;
  bool get isSpeakerMuted => _isSpeakerMuted.value;
  int? get currentUid => _currentUid;
  bool get bodyCamVideoActive => _bodyCamVideoUid.value != null;
  bool get isPublishingCamera => _isPublishingCamera.value;
  bool get isPublishingAudio => _isPublishingAudio.value;

  void setBodyCamVideoActive(bool active) {
    _bodyCamVideoUid.value = active ? bodyCamAgoraUid : null;
    final engine = _engine;
    if (active && engine != null) {
      // Force subscription — autoSubscribeVideo may not trigger for existing hosts
      engine.muteRemoteVideoStream(uid: bodyCamAgoraUid, mute: false).catchError(
        (dynamic e) => debugPrint('CallService: video subscribe error: $e'),
      );
      _applyBodyCamAudioMute();
    }
  }

  /// Re-asserts the panel mute state on the bodycam's audio (uid 9001). The
  /// bodycam's voice is the ONLY thing the panel "mic" button controls, and it
  /// starts muted by default — so when the bodycam (re)joins we apply the
  /// current [_isMicrophoneMuted] state instead of letting autoSubscribe play it
  /// unsolicited.
  void _applyBodyCamAudioMute() {
    final engine = _engine;
    if (engine == null) return;
    engine
        .muteRemoteAudioStream(
            uid: bodyCamAgoraUid, mute: _isMicrophoneMuted.value)
        .catchError(
      (dynamic e) => debugPrint('CallService: bodycam audio mute error: $e'),
    );
  }

  /// Turns on the local camera preview (rendered by an AgoraVideoView with
  /// uid 0) WITHOUT publishing it to the channel. Used when the livestream
  /// screen opens so the agent sees their camera before going live.
  Future<void> startLocalPreview() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await _useRearCamera(engine);
      await engine.startPreview();
    } catch (e, st) {
      debugPrint('CallService: startLocalPreview error: $e');
      debugPrint('$st');
    }
  }

  /// Defaults the capture to the REAR camera (the scene-facing one — the
  /// sensible default for a bodycam, not the selfie/face camera). The user can
  /// still flip with [switchCamera].
  Future<void> _useRearCamera(RtcEngine engine) async {
    try {
      await engine.setCameraCapturerConfiguration(
        const CameraCapturerConfiguration(
          cameraDirection: CameraDirection.cameraRear,
        ),
      );
    } catch (e) {
      debugPrint('CallService: setCameraCapturerConfiguration error: $e');
    }
  }

  /// Stops the local camera preview and capture. Call when leaving the
  /// livestream screen.
  Future<void> stopLocalPreview() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.stopPreview();
    } catch (e, st) {
      debugPrint('CallService: stopLocalPreview error: $e');
      debugPrint('$st');
    }
  }

  /// Starts publishing THIS phone's camera AND microphone to the channel so
  /// other participants can watch and HEAR the local agent's livestream. The
  /// same captured frames feed the local preview (AgoraVideoView with uid 0).
  /// Idempotent. (RECORD_AUDIO/CAMERA runtime permissions must already be
  /// granted by the caller.)
  Future<void> startCameraPublish() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      // Re-enable mic capture (it's OFF by default / after watching) BEFORE
      // unmuting, so going live actually carries voice. Restore the recording
      // volume too (it's forced to 0 in receive-only mode).
      await engine.enableLocalAudio(true);
      await engine.adjustRecordingSignalVolume(100);
      await _useRearCamera(engine);
      await engine.startPreview();
      await engine.muteLocalVideoStream(false);
      // Unmute the local mic too — without this the livestream is silent (the
      // phone is muted-by-default / receive-only outside of going live).
      await engine.muteLocalAudioStream(false);
      await engine.updateChannelMediaOptions(
        const ChannelMediaOptions(
          publishCameraTrack: true,
          publishMicrophoneTrack: true,
        ),
      );
      _isPublishingCamera.value = true;
      _isPublishingAudio.value = true;
    } catch (e, st) {
      debugPrint('CallService: startCameraPublish error: $e');
      debugPrint('$st');
    }
  }

  /// Stops publishing the phone camera + microphone and returns to receive-only.
  /// Keeps the local preview alive unless [stopPreview] is set. Idempotent.
  Future<void> stopCameraPublish({bool stopPreview = false}) async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.updateChannelMediaOptions(
        const ChannelMediaOptions(
          publishCameraTrack: false,
          publishMicrophoneTrack: false,
        ),
      );
      await engine.muteLocalVideoStream(true);
      // Re-block the local mic AND kill its capture so we're fully receive-only
      // again (mic dead unless we publish a livestream).
      await engine.muteLocalAudioStream(true);
      await engine.enableLocalAudio(false);
      await engine.adjustRecordingSignalVolume(0);
      if (stopPreview) await engine.stopPreview();
      _isPublishingCamera.value = false;
      _isPublishingAudio.value = false;
    } catch (e, st) {
      debugPrint('CallService: stopCameraPublish error: $e');
      debugPrint('$st');
    }
  }

  /// Mutes/unmutes the OUTGOING microphone while live, so the broadcasting agent
  /// can toggle their voice without stopping the camera. Optimistic UI: flips
  /// the observable first, reverts on failure.
  Future<void> setBroadcastMicMuted(bool muted) async {
    final engine = _engine;
    if (engine == null) return;
    _isPublishingAudio.value = !muted;
    try {
      await engine.muteLocalAudioStream(muted);
    } catch (e) {
      _isPublishingAudio.value = muted;
      debugPrint('CallService: setBroadcastMicMuted error: $e');
    }
  }

  /// Mutes/unmutes the INCOMING audio of a specific remote participant — used by
  /// the livestream WATCH view so the receiver can listen to or silence the
  /// source they're watching (a peer agent or the bodycam).
  Future<void> setRemoteAudioMuted({required int uid, required bool muted}) async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.muteRemoteAudioStream(uid: uid, mute: muted);
    } catch (e) {
      debugPrint('CallService: setRemoteAudioMuted($uid) error: $e');
    }
  }

  /// Forces this phone into strict receive-only mode: stops publishing BOTH the
  /// camera and the microphone, and physically turns the mic capture OFF
  /// (`enableLocalAudio(false)`). Called when entering WATCH mode so a receiver
  /// who is merely viewing another agent's livestream can NEVER emit its own
  /// audio/video into the channel (its voice was leaking into the stream). The
  /// data stream (GPS) and remote playback are unaffected.
  Future<void> ensureReceiveOnly() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.updateChannelMediaOptions(
        const ChannelMediaOptions(
          publishMicrophoneTrack: false,
          publishCameraTrack: false,
        ),
      );
      await engine.muteLocalAudioStream(true);
      await engine.muteLocalVideoStream(true);
      await engine.enableLocalAudio(false);
      await engine.adjustRecordingSignalVolume(0);
      _isPublishingAudio.value = false;
      _isPublishingCamera.value = false;
    } catch (e) {
      debugPrint('CallService: ensureReceiveOnly error: $e');
    }
  }

  /// Ensures we're subscribed to a specific remote participant's video so we
  /// can render it — e.g. when opening the livestream to watch the agent (or
  /// bodycam) that raised an emergency, rather than our own camera.
  Future<void> watchRemoteVideo(int uid) async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.muteRemoteVideoStream(uid: uid, mute: false);
    } catch (e) {
      debugPrint('CallService: watchRemoteVideo($uid) error: $e');
    }
  }

  /// Captures a single frame to [filePath] from the given Agora [uid]:
  ///   • uid 0    → this phone's local camera,
  ///   • uid 9001 → the bodycam livestream,
  ///   • other    → another agent's camera.
  /// Returns the saved file path on success, or null. The frame is grabbed from
  /// the live video, so the source must be previewing/subscribed first.
  Future<String?> takeSnapshot({required int uid, required String filePath}) async {
    final engine = _engine;
    if (engine == null) return null;
    _snapshotCompleter = Completer<String?>();
    try {
      await engine.takeSnapshot(uid: uid, filePath: filePath);
    } catch (e) {
      debugPrint('CallService: takeSnapshot error: $e');
      _snapshotCompleter = null;
      return null;
    }
    return _snapshotCompleter!.future
        .timeout(const Duration(seconds: 5), onTimeout: () => null);
  }

  /// Flips between front and back camera while previewing/publishing.
  Future<void> switchCamera() async {
    try {
      await _engine?.switchCamera();
    } catch (e) {
      debugPrint('CallService: switchCamera error: $e');
    }
  }

  RxBool get hasJoinedRx => _hasJoined;
  RxBool get microphoneMutedRx => _isMicrophoneMuted;
  RxBool get speakerMutedRx => _isSpeakerMuted;
  RxMap<int, ParticipantLocation> get remoteLocationsRx => _remoteLocations;
  Rxn<ParticipantLocation> get localLocationRx => _localLocation;
  RxInt get satelliteCountRx => _satelliteCount;
  RxInt get connectedUsersCountRx => _connectedUsersCount;
  Rxn<int> get bodyCamVideoUidRx => _bodyCamVideoUid;
  RxBool get isPublishingCameraRx => _isPublishingCamera;
  RxBool get isPublishingAudioRx => _isPublishingAudio;
  Rxn<EmergencySignal> get incomingEmergencyRx => _incomingEmergency;
  Rxn<EmergencyCancel> get incomingEmergencyCancelRx => _incomingEmergencyCancel;
  Rxn<int> get remoteVideoStoppedRx => _remoteVideoStopped;

  /// Last known location of a remote participant (from the always-on GPS data
  /// stream), or null if we've never received one. Used to label where an
  /// agent's livestream was when it got cut.
  ParticipantLocation? remoteLocation(int uid) => _remoteLocations[uid];

  /// Clears the last consumed emergency so a later identical signal re-triggers.
  void consumeEmergency() => _incomingEmergency.value = null;

  /// Clears the last consumed cancellation so a later one re-triggers.
  void consumeEmergencyCancel() => _incomingEmergencyCancel.value = null;

  /// Broadcasts an emergency/recording signal to every other device in the
  /// channel over the always-on data stream. The sender does NOT receive its
  /// own message back from Agora, so its own popup never fires.
  /// [startedAt] lets the caller reuse the SOS session's start time across
  /// periodic heartbeat re-broadcasts, so a device that joins mid-emergency
  /// still gets alerted while receivers dedupe repeats. Defaults to now.
  Future<void> broadcastEmergency({
    required String officer,
    DateTime? startedAt,
  }) async {
    final loc = _localLocation.value;
    final signal = EmergencySignal(
      officer: officer,
      uid: _currentUid ?? _config.localUid,
      timestamp: startedAt ?? DateTime.now(),
      latitude: loc?.latitude,
      longitude: loc?.longitude,
    );
    await _sendDataStreamJson(signal.toJson());
  }

  /// Broadcasts a cancellation of a previously sent emergency so every other
  /// device dismisses the popup and silences the siren.
  Future<void> broadcastEmergencyCancel({required String officer}) async {
    final loc = _localLocation.value;
    await _sendDataStreamJson(<String, dynamic>{
      'type': 'emergency_cancel',
      'officer': officer,
      'uid': _currentUid ?? _config.localUid,
      'ts': DateTime.now().millisecondsSinceEpoch,
      if (loc != null) 'lat': loc.latitude,
      if (loc != null) 'lng': loc.longitude,
    });
  }

  /// Last time a data-stream message was received from each remote uid. Used by
  /// the map layer to flag peers that have gone silent (lost signal) and to
  /// render their "última conexión" timestamp.
  Map<int, DateTime> get remoteLastSeen => Map.unmodifiable(_remoteLastSeen);

  AgoraCallConfig get config => _config;

  RtcEngine get engine {
    final engine = _engine;
    if (engine == null) {
      throw StateError('CallService initialized state accessed before setup');
    }
    return engine;
  }

  /// Initializes the Agora engine, joins the target channel, and starts location streaming.
  Future<CallService> init() async {
    if (_isInitialized) {
      return this;
    }

    final rtcEngine = createAgoraRtcEngine();
    _engine = rtcEngine;

    await rtcEngine.initialize(RtcEngineContext(appId: _config.appId));

    rtcEngine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) {
          _hasJoined.value = true;
          _currentUid = connection.localUid;
          _connectedUsersCount.value = 1;
          final currentLocal = _localLocation.value;
          if (currentLocal != null && currentLocal.uid != _currentUid) {
            _localLocation.value = currentLocal.copyWith(
              uid: _currentUid ?? currentLocal.uid,
            );
          }
          debugPrint(
            'CallService: joined channel ${connection.channelId} as ${connection.localUid} after $elapsed ms',
          );
          _sendLatestLocalLocationSnapshot();
          _startLocationHeartbeat();
          unawaited(
            CallForegroundTaskManager.startOrUpdate(
              channelName: connection.channelId ?? _config.channelId,
            ),
          );
        },
        onUserJoined: (connection, remoteUid, elapsed) {
          // Only agents (phones) count as users. The bodycam (uid 9001) is a
          // device, not an agent, so it must NOT inflate the user count.
          if (remoteUid != bodyCamAgoraUid) _connectedUsersCount.value++;
          debugPrint('CallService: remote user $remoteUid joined ${connection.channelId}');
          // Re-broadcast our position so the newcomer sees us immediately,
          // without waiting for the next GPS fix or heartbeat tick.
          _sendLatestLocalLocationSnapshot();
          if (remoteUid == bodyCamAgoraUid) {
            _bodyCamVideoUid.value = remoteUid;
            // Fresh bodycam session → clear any stale "cut" flag so the next SOS
            // can fire the signal-cut notice again.
            if (_remoteVideoStopped.value == bodyCamAgoraUid) {
              _remoteVideoStopped.value = null;
            }
            // Honour the default-muted bodycam audio (panel mic controls it).
            _applyBodyCamAudioMute();
            debugPrint('CallService: bodycam detected → activating video uid=$remoteUid');
          }
        },
        onUserOffline: (connection, remoteUid, reason) {
          // Mirror onUserJoined: the bodycam (uid 9001) was never counted, so
          // don't decrement for it.
          if (remoteUid != bodyCamAgoraUid && _connectedUsersCount.value > 1) {
            _connectedUsersCount.value--;
          }
          if (remoteUid == bodyCamAgoraUid) _bodyCamVideoUid.value = null;
          // A source going offline = its livestream is cut → let the WATCH view
          // show the "Signal cut" notice. Applies to agent phones AND the
          // bodycam (when it's watched as the external-agent simulation; the
          // view gates the bodycam cut on agentLabel being set).
          _remoteVideoStopped.value = remoteUid;
          // Only drop the map marker on a graceful quit. A transient drop
          // (frequent while moving) keeps the last-known marker; the TTL sweep
          // removes it later if the peer never comes back.
          if (reason == UserOfflineReasonType.userOfflineQuit) {
            _remoteLocations.remove(remoteUid);
            _remoteLastSeen.remove(remoteUid);
          }
          debugPrint('CallService: remote user $remoteUid offline (reason=$reason)');
        },
        onRemoteVideoStateChanged: (connection, remoteUid, state, reason, elapsed) {
          debugPrint('CallService: video state uid=$remoteUid state=$state reason=$reason');
          final live = state == RemoteVideoState.remoteVideoStateDecoding ||
              state == RemoteVideoState.remoteVideoStateStarting;
          if (remoteUid == bodyCamAgoraUid) {
            if (live) {
              _bodyCamVideoUid.value = remoteUid;
              if (_remoteVideoStopped.value == bodyCamAgoraUid) {
                _remoteVideoStopped.value = null;
              }
              // Keep the bodycam's audio at the panel's mute state (default off).
              _applyBodyCamAudioMute();
            } else if (state == RemoteVideoState.remoteVideoStateFailed) {
              _bodyCamVideoUid.value = null;
              _remoteVideoStopped.value = bodyCamAgoraUid;
            }
            // STOPPED/FROZEN: don't clear — onUserOffline handles a real exit.
            return;
          }
          // Agent phone: track stop (publisher muted/stopped) vs resume, so the
          // WATCH view can show a "Signal cut" notice when the feed dies.
          if (state == RemoteVideoState.remoteVideoStateStopped ||
              state == RemoteVideoState.remoteVideoStateFailed) {
            _remoteVideoStopped.value = remoteUid;
          } else if (live && _remoteVideoStopped.value == remoteUid) {
            _remoteVideoStopped.value = null;
          }
        },
        onLeaveChannel: (connection, stats) {
          _hasJoined.value = false;
          _connectedUsersCount.value = 0;
          _isPublishingCamera.value = false;
          _isPublishingAudio.value = false;
          _remoteLocations.clear();
          _remoteLastSeen.clear();
          _locationHeartbeatTimer?.cancel();
          _locationHeartbeatTimer = null;
          debugPrint('CallService: left channel ${connection.channelId}');
          unawaited(CallForegroundTaskManager.stop());
        },
        onError: (error, message) {
          debugPrint('CallService error: $error -> $message');
        },
        onSnapshotTaken:
            (connection, uid, filePath, width, height, errCode) {
          debugPrint(
            'CallService: snapshot uid=$uid path=$filePath err=$errCode',
          );
          final completer = _snapshotCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.complete(errCode == 0 ? filePath : null);
          }
        },
        onStreamMessage:
            (connection, remoteUid, streamId, data, length, sentTs) {
              debugPrint('CallService[GPS-DBG]: onStreamMessage from uid=$remoteUid length=$length');
              _handleIncomingStreamMessage(remoteUid, data, length);
            },
        onStreamMessageError:
            (connection, remoteUid, streamId, error, missed, cached) {
              debugPrint(
                'CallService stream error from $remoteUid: $error (missed=$missed, cached=$cached)',
              );
            },
      ),
    );

    // Phone is receive-only by default: enable the audio module for playback but
    // keep the local mic muted AND physically OFF (enableLocalAudio(false) stops
    // mic capture entirely). The mic only turns on while THIS phone publishes
    // its own livestream — see startCameraPublish. Without this a receiver
    // watching an emergency could leak its own voice into the channel. The
    // bodycam's incoming audio also starts MUTED; the panel "mic" button unmutes
    // it on demand.
    await rtcEngine.enableAudio();
    await rtcEngine.muteLocalAudioStream(true);
    await rtcEngine.enableLocalAudio(false);
    await rtcEngine.adjustRecordingSignalVolume(0); // belt-and-suspenders: mic dead
    await rtcEngine.setDefaultAudioRouteToSpeakerphone(true);
    _isMicrophoneMuted.value = true; // bodycam audio muted by default
    _isSpeakerMuted.value = false;

    // Enable video module to receive bodycam stream; phone never publishes its own camera.
    await rtcEngine.enableVideo();
    await rtcEngine.muteLocalVideoStream(true);

    try {
      _locationStreamId = await rtcEngine.createDataStream(
        const DataStreamConfig(syncWithAudio: false, ordered: true),
      );
    } catch (error, stackTrace) {
      debugPrint('CallService: failed to create data stream: $error');
      debugPrint('$stackTrace');
    }

    await rtcEngine.joinChannel(
      token: '',  // bodycam joins with null — both must use no-auth mode
      channelId: _config.channelId,
      uid: _config.localUid,
      options: const ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        publishMicrophoneTrack: false,  // muted until user enables mic
        publishCameraTrack: false,
        // Do NOT auto-play everyone's audio. With auto-subscribe on, the moment
        // any phone went live every other phone in the channel started playing
        // its voice unsolicited (and fed the echo loop). Audio is now pulled
        // ON DEMAND: the WATCH view subscribes the source it's viewing, and the
        // panel "mic" button subscribes the bodycam (uid 9001).
        autoSubscribeAudio: false,
        autoSubscribeVideo: true,
      ),
    );

    unawaited(_startLocalLocationUpdates());

    _isInitialized = true;
    return this;
  }

  /// Mutes or unmutes the BODYCAM's incoming audio (uid 9001) — the only thing
  /// the panel "mic" button controls. It never touches the local mic (the phone
  /// only opens its mic while publishing its own livestream) nor a watched
  /// agent's audio (that's controlled per-uid by the WATCH screen). Starts muted
  /// by default; tapping the panel button unmutes the bodycam's voice.
  Future<void> setMicrophoneMuted({required bool muted}) async {
    final rtcEngine = _engine;
    if (rtcEngine == null) {
      throw StateError('CallService microphone toggle attempted before init');
    }

    // Optimistic UI: flip the observable first so the icon reacts on tap; the
    // native call below can take tens of ms. Revert if it throws.
    _isMicrophoneMuted.value = muted;
    try {
      await rtcEngine.muteRemoteAudioStream(
          uid: bodyCamAgoraUid, mute: muted);
    } catch (error) {
      _isMicrophoneMuted.value = !muted;
      rethrow;
    }
    debugPrint('CallService bodycam audio muted set to $muted');
  }

  /// Toggles the device speakerphone route and updates the mute observable.
  Future<void> setSpeakerMuted({required bool muted}) async {
    final rtcEngine = _engine;
    if (rtcEngine == null) {
      throw StateError('CallService speaker toggle attempted before init');
    }

    if (!_hasJoined.value) {
      _isSpeakerMuted.value = muted;
      debugPrint(
        'CallService speaker toggle applied locally (not joined to channel)',
      );
      return;
    }

    final bool previousState = _isSpeakerMuted.value;
    // Optimistic UI: flip the icon immediately. The end-of-method block below
    // confirms (keeps `muted`) or reverts (`previousState`) once the native
    // audio-route change resolves.
    _isSpeakerMuted.value = muted;
    var applied = false;
    var usedRemoteMuteFallback = false;

    final bool isIOS = defaultTargetPlatform == TargetPlatform.iOS;

    if (isIOS) {
      try {
        await rtcEngine.setDefaultAudioRouteToSpeakerphone(!muted);
        applied = true;
      } on AgoraRtcException catch (error, stackTrace) {
        debugPrint(
          'CallService setDefaultAudioRouteToSpeakerphone failed: $error',
        );
        debugPrint('$stackTrace');
      }
    }

    if (!applied) {
      try {
        await rtcEngine.setEnableSpeakerphone(!muted);
        applied = true;
      } on AgoraRtcException catch (error, stackTrace) {
        debugPrint('CallService setEnableSpeakerphone failed: $error');
        debugPrint('$stackTrace');
      }
    }

    if (!applied) {
      try {
        await rtcEngine.muteAllRemoteAudioStreams(muted);
        debugPrint(
          'CallService: fallback muteAllRemoteAudioStreams applied for speaker toggle',
        );
        applied = true;
        usedRemoteMuteFallback = true;
      } on AgoraRtcException catch (fallbackError, fallbackStackTrace) {
        debugPrint('CallService fallback mute failed: $fallbackError');
        debugPrint('$fallbackStackTrace');
      }
    }

    if (!muted && usedRemoteMuteFallback) {
      try {
        await rtcEngine.muteAllRemoteAudioStreams(false);
      } on AgoraRtcException catch (error, stackTrace) {
        debugPrint(
          'CallService: failed to unmute remote audio on speaker enable: $error',
        );
        debugPrint('$stackTrace');
      }
    }

    if (applied) {
      _isSpeakerMuted.value = muted;
      debugPrint('CallService speaker muted set to $muted');
    } else {
      _isSpeakerMuted.value = previousState;
      debugPrint(
        'CallService speaker toggle ignored; no audio route change applied',
      );
    }
  }

  /// Begins listening for high-accuracy location updates and shares them with peers.
  Future<void> _startLocalLocationUpdates() async {
    if (!await _ensureLocationPermissionGranted()) {
      return;
    }

    final locationServiceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!locationServiceEnabled) {
      debugPrint('CallService: location services disabled; skipping updates');
      return;
    }

    _positionSubscription?.cancel();

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 5,
    );

    _positionSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          _handlePositionUpdate,
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('CallService: location stream error $error');
            debugPrint('$stackTrace');
          },
        );

    try {
      final currentPosition = await Geolocator.getCurrentPosition();
      _handlePositionUpdate(currentPosition);
    } catch (error, stackTrace) {
      debugPrint('CallService: failed to fetch current position: $error');
      debugPrint('$stackTrace');
    }
  }

  /// Ensures location permissions are granted before attempting to read GPS updates.
  Future<bool> _ensureLocationPermissionGranted() async {
    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine) {
      debugPrint('CallService: location permission unavailable ($permission)');
      return false;
    }

    return true;
  }

  /// Handles a fresh position from the device and echoes it to the channel if connected.
  void _handlePositionUpdate(Position position) {
    final assignedUid = _currentUid ?? _config.localUid;
    final DateTime timestamp = position.timestamp;

    final latestLocation = ParticipantLocation(
      uid: assignedUid,
      latitude: position.latitude,
      longitude: position.longitude,
      timestamp: timestamp,
    );

    _localLocation.value = latestLocation;

    _updateSatelliteMetrics(position);

    // Throttle on-the-wire sends so fast movement can't flood the data stream.
    // The 3 s heartbeat still re-broadcasts the latest fix, so nothing is lost.
    if (_hasJoined.value) {
      final now = DateTime.now();
      final last = _lastLocationSendAt;
      if (last == null || now.difference(last) >= _minSendInterval) {
        _lastLocationSendAt = now;
        unawaited(_sendLocationUpdate(latestLocation));
      }
    }
  }

  /// Normalises the platform-specific satellite metadata into a shared signal.
  void _updateSatelliteMetrics(Position position) {
    if (position is AndroidPosition) {
      final double rawCount = position.satelliteCount;
      final int resolvedCount;

      if (rawCount.isFinite) {
        final double clamped = rawCount < 0 ? 0 : rawCount;
        resolvedCount = clamped.round();
      } else {
        resolvedCount = 0;
      }

      if (_satelliteCount.value != resolvedCount) {
        _satelliteCount.value = resolvedCount;
      }

      return;
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return;
    }

    if (_satelliteCount.value != 0) {
      _satelliteCount.value = 0;
    }
  }

  /// Serialises the current location and pushes it onto the Agora data stream.
  Future<void> _sendLocationUpdate(ParticipantLocation location) async {
    await _sendDataStreamJson(location.toJson());
  }

  /// Encodes [payload] as JSON and pushes it onto the shared Agora data stream.
  /// Used for both location and emergency messages.
  Future<void> _sendDataStreamJson(Map<String, dynamic> payload) async {
    final rtcEngine = _engine;
    final streamId = _locationStreamId;

    if (rtcEngine == null || streamId == null) {
      return;
    }

    try {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      await rtcEngine.sendStreamMessage(
        streamId: streamId,
        data: bytes,
        length: bytes.length,
      );
    } catch (error, stackTrace) {
      debugPrint('CallService: failed to send data-stream message $error');
      debugPrint('$stackTrace');
    }
  }

  /// Parses a data-stream payload from another participant and stores the location.
  void _handleIncomingStreamMessage(int remoteUid, Uint8List data, int length) {
    if (length <= 0) {
      return;
    }

    try {
      final payloadBytes = length == data.length
          ? data
          : Uint8List.fromList(data.sublist(0, length));
      final decoded = jsonDecode(utf8.decode(payloadBytes));

      if (decoded is! Map) {
        debugPrint('CallService[GPS-DBG]: non-map payload from $remoteUid');
        return;
      }

      final message = Map<String, dynamic>.from(decoded);

      // Emergency/recording signal from another agent (map livestream button).
      if (message['type'] == 'emergency') {
        _incomingEmergency.value =
            EmergencySignal.fromJson(message, uid: remoteUid);
        debugPrint('CallService: emergency signal from uid=$remoteUid officer=${message['officer']}');
        return;
      }

      // Cancellation of a previously broadcast emergency.
      if (message['type'] == 'emergency_cancel') {
        _incomingEmergencyCancel.value =
            EmergencyCancel.fromJson(message, uid: remoteUid);
        debugPrint('CallService: emergency cancel from uid=$remoteUid');
        return;
      }

      if (message['type'] != 'location') {
        debugPrint('CallService[GPS-DBG]: unknown type "${message['type']}" from $remoteUid');
        return;
      }

      final location = ParticipantLocation.fromJson(
        message,
      ).copyWith(uid: remoteUid);
      debugPrint('CallService[GPS-DBG]: stored location uid=$remoteUid lat=${location.latitude} lng=${location.longitude}');
      _remoteLocations[remoteUid] = location;
      _remoteLastSeen[remoteUid] = DateTime.now();
    } catch (error, stackTrace) {
      debugPrint(
        'CallService: failed to decode stream message from $remoteUid: $error',
      );
      debugPrint('$stackTrace');
    }
  }

  /// Re-sends the latest known local location, e.g. after the join completes.
  void _sendLatestLocalLocationSnapshot() {
    final latest = _localLocation.value;

    if (!_hasJoined.value || latest == null) {
      return;
    }

    final resolved = latest.copyWith(uid: _currentUid ?? latest.uid);
    unawaited(_sendLocationUpdate(resolved));
  }

  /// Periodically re-broadcasts the latest known local location so peers keep
  /// (or recover) our marker even when we are stationary, after packet loss, or
  /// when a peer joins/reconnects later. Agora data-stream messages are
  /// ephemeral, so without this heartbeat a still agent would silently stop
  /// appearing for any new viewer.
  void _startLocationHeartbeat() {
    _locationHeartbeatTimer?.cancel();
    _locationHeartbeatTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _sendLatestLocalLocationSnapshot(),
    );
  }

  /// Cancels the in-flight geolocator subscription.
  Future<void> _stopLocationUpdates() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _satelliteCount.value = 0;
  }

  /// Leaves the active Agora channel and clears transient participant state.
  Future<void> leaveChannel() async {
    final rtcEngine = _engine;
    if (rtcEngine == null) {
      return;
    }

    await rtcEngine.leaveChannel();
    _hasJoined.value = false;
    _remoteLocations.clear();
    unawaited(CallForegroundTaskManager.stop());
  }

  /// Releases the Agora engine and resets observable state.
  Future<void> shutdown() async {
    final rtcEngine = _engine;
    if (rtcEngine == null) {
      return;
    }

    await rtcEngine.leaveChannel();
    await rtcEngine.release();

    _engine = null;
    _isInitialized = false;
    _hasJoined.value = false;
    _isMicrophoneMuted.value = false;
    _isSpeakerMuted.value = false;
    _currentUid = null;
    _locationStreamId = null;
    _locationHeartbeatTimer?.cancel();
    _locationHeartbeatTimer = null;
    _lastLocationSendAt = null;
    _remoteLocations.clear();
    _remoteLastSeen.clear();
    _localLocation.value = null;
    _satelliteCount.value = 0;
    _connectedUsersCount.value = 0;
    await _stopLocationUpdates();
    await CallForegroundTaskManager.stop();
  }
}
