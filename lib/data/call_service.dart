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

  bool get isInitialized => _isInitialized;
  bool get hasJoinedChannel => _hasJoined.value;
  bool get isMicrophoneMuted => _isMicrophoneMuted.value;
  bool get isSpeakerMuted => _isSpeakerMuted.value;
  int? get currentUid => _currentUid;
  bool get bodyCamVideoActive => _bodyCamVideoUid.value != null;

  void setBodyCamVideoActive(bool active) {
    _bodyCamVideoUid.value = active ? bodyCamAgoraUid : null;
    final engine = _engine;
    if (active && engine != null) {
      // Force subscription — autoSubscribeVideo may not trigger for existing hosts
      engine.muteRemoteVideoStream(uid: bodyCamAgoraUid, mute: false).catchError(
        (dynamic e) => debugPrint('CallService: video subscribe error: $e'),
      );
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
          _connectedUsersCount.value++;
          debugPrint('CallService: remote user $remoteUid joined ${connection.channelId}');
          // Re-broadcast our position so the newcomer sees us immediately,
          // without waiting for the next GPS fix or heartbeat tick.
          _sendLatestLocalLocationSnapshot();
          if (remoteUid == bodyCamAgoraUid) {
            _bodyCamVideoUid.value = remoteUid;
            debugPrint('CallService: bodycam detected → activating video uid=$remoteUid');
          }
        },
        onUserOffline: (connection, remoteUid, reason) {
          if (_connectedUsersCount.value > 1) _connectedUsersCount.value--;
          if (remoteUid == bodyCamAgoraUid) _bodyCamVideoUid.value = null;
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
          if (remoteUid != bodyCamAgoraUid) return;
          if (state == RemoteVideoState.remoteVideoStateDecoding ||
              state == RemoteVideoState.remoteVideoStateStarting) {
            _bodyCamVideoUid.value = remoteUid;
          } else if (state == RemoteVideoState.remoteVideoStateFailed) {
            _bodyCamVideoUid.value = null;
          }
          // STOPPED and FROZEN: don't clear — onUserOffline handles definitive exit
        },
        onLeaveChannel: (connection, stats) {
          _hasJoined.value = false;
          _connectedUsersCount.value = 0;
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

    // Phone is receive-only: enable audio module for playback but permanently
    // block the local mic. Only the bodycam (UID 9001) ever publishes audio.
    await rtcEngine.enableAudio();
    await rtcEngine.muteLocalAudioStream(true);
    await rtcEngine.setDefaultAudioRouteToSpeakerphone(true);
    _isMicrophoneMuted.value = true;
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
        autoSubscribeAudio: true,
        autoSubscribeVideo: true,
      ),
    );

    unawaited(_startLocalLocationUpdates());

    _isInitialized = true;
    return this;
  }

  /// Mutes or unmutes the local microphone and synchronises the observable state.
  Future<void> setMicrophoneMuted({required bool muted}) async {
    final rtcEngine = _engine;
    if (rtcEngine == null) {
      throw StateError('CallService microphone toggle attempted before init');
    }

    // Phone is receive-only — mute/unmute controls the remote audio subscription,
    // never the local mic (which is permanently blocked).
    await rtcEngine.muteAllRemoteAudioStreams(muted);
    _isMicrophoneMuted.value = muted;
    debugPrint('CallService remote audio muted set to $muted');
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
    final rtcEngine = _engine;
    final streamId = _locationStreamId;

    if (rtcEngine == null || streamId == null) {
      return;
    }

    try {
      final payload = jsonEncode(location.toJson());
      final bytes = Uint8List.fromList(utf8.encode(payload));
      await rtcEngine.sendStreamMessage(
        streamId: streamId,
        data: bytes,
        length: bytes.length,
      );
    } catch (error, stackTrace) {
      debugPrint('CallService: failed to send location update $error');
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
