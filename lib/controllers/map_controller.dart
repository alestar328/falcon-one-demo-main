import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:falcon_one_demo/app_ui_keys.dart';
import 'package:falcon_one_demo/data/call_service.dart';
import 'package:falcon_one_demo/services/agora_launcher.dart';
import 'package:falcon_one_demo/models/sos_notification.dart';
import 'package:falcon_one_demo/models/w1_recording.dart';
import 'package:falcon_one_demo/services/bodycam_service.dart';
import 'package:falcon_one_demo/services/photo_storage_service.dart';
import 'package:falcon_one_demo/services/upload_service.dart';
import 'package:falcon_one_demo/services/w1_service.dart';
import 'package:falcon_one_demo/views/camera/camera_livestream_view.dart';
import 'package:falcon_one_demo/views/emergency/emergency_dialogs.dart';
import 'package:falcon_one_demo/widgets/w1_recording_import_sheet.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart' as img_picker;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

enum IncidentUploadUiPhase {
  idle,
  uploading,
  success,
  error,
}

class MapController extends GetxController with WidgetsBindingObserver {
  MapboxMap? mapboxMap;

  CallService? _callService;
  final RxBool _fallbackSpeakerMuted = false.obs;
  final RxBool _fallbackMicrophoneMuted = false.obs;
  Worker? _remoteLocationsWorker;
  Worker? _localLocationWorker;
  Worker? _satelliteCountWorker;
  Worker? _connectedUsersWorker;
  Worker? _bodyCamVideoWorker;
  Worker? _agoraConnectedWorker;
  Worker? _incomingEmergencyWorker;
  Worker? _incomingEmergencyCancelWorker;

  // Officer code broadcast with an emergency signal so receivers can show the
  // source. Mirrors UploadService's default ('off-001').
  static const String officerCode = 'off-001';
  // Label used when the recording signal arrives locally over BT and the
  // presenter treats it as "Externo": there is no real remote payload (it's our
  // own bodycam pretending to be another agent), so we show this simulated id.
  static const String simulatedExternalAgentLabel = 'Officer 007';

  // Guards against stacking the emergency popup if a second signal arrives
  // while the first dialog is still open.
  bool _emergencyDialogOpen = false;
  // True while THIS device has an outstanding emergency broadcast it can cancel
  // (drives the map button's emit ⇄ cancel toggle).
  final RxBool emergencyBroadcastActive = false.obs;

  // ── SOS broadcast heartbeat ────────────────────────────────────────────────
  // The emergency is re-broadcast on this interval while active, so a device
  // that opens the app mid-emergency still receives it (data-stream messages are
  // ephemeral and only reach already-connected peers). Same idea as the GPS
  // heartbeat. The session's start time is reused so receivers dedupe repeats.
  Timer? _emergencyHeartbeatTimer;
  DateTime? _emergencyStartedAt;
  static const Duration _emergencyHeartbeatInterval = Duration(seconds: 3);

  // ── SOS notification centre ────────────────────────────────────────────────
  // Every distinct SOS this device receives (deduped by session key) is kept
  // here so the user sees a bell badge with the count and can review each alert
  // (officer, GPS, date/time) and accept/close it — even if it arrived while
  // they were elsewhere on the map.
  final RxList<SosNotification> sosNotifications = <SosNotification>[].obs;
  final Set<String> _seenSosKeys = <String>{};

  static const _kAgentSourceId = 'falcon-remote-agents';
  static const _kAgentPulseLayerId = 'falcon-agent-pulse';
  static const _kAgentDotLayerId = 'falcon-agent-dot';
  static const _kAgentLabelLayerId = 'falcon-agent-label';

  // A remote agent is considered to have "lost signal" once we have not
  // received a data-stream message from it for longer than this. Peers send
  // every ~1 s (movement) plus a 3 s heartbeat, so 7 s ≈ two missed heartbeats.
  static const Duration _staleAfter = Duration(seconds: 7);

  bool _hasPositionedInitialCamera = false;
  bool _agentLayersReady = false;
  Timer? _pulseTimer;
  Timer? _staleRefreshTimer;
  double _pulsePhase = 0.0;

  final RxDouble incidentLatitude = 0.0.obs;
  final RxDouble incidentLongitude = 0.0.obs;
  final RxBool incidentGpsReady = false.obs;

  final Rxn<File> selectedVideo = Rxn<File>();

  final RxBool isUploading = false.obs;
  final RxBool isPickingVideo = false.obs;

  final Rx<IncidentUploadUiPhase> uploadUiPhase = IncidentUploadUiPhase.idle.obs;
  final Rxn<String> lastUploadedIncidentId = Rxn<String>();
  final RxString lastUploadedApiStatus = ''.obs;
  final RxString uploadErrorDetail = ''.obs;

  final Rxn<DateTime> videoSelectedAt = Rxn<DateTime>();

  W1Service get w1Service => Get.find<W1Service>();

  String? get w1BaseUrl => w1Service.baseUrl.value;

  final RxList<W1Recording> recordings = <W1Recording>[].obs;
  final RxBool isFetchingRecordings = false.obs;
  final RxBool isDownloading = false.obs;
  final Rxn<W1Recording> w1ActiveRecording = Rxn<W1Recording>();
  final RxString w1ImportError = ''.obs;

  final RxBool isW1Recording = false.obs;
  final RxBool isCheckingStatus = false.obs;
  final RxString w1StatusMessage = 'No active recording'.obs;

  bool _w1LastRecordingPoll = false;
  bool _w1EverSawRecordingTrue = false;
  bool _w1RecordingStopSnackShown = false;
  Timer? _w1StatusPollTimer;

  // ── Bodycam BT state ─────────────────────────────────────────────────────
  final _bodyCam = BodyCamService();
  final RxString bodyCamState = 'disconnected'.obs;
  final RxBool isRecording = false.obs;
  final RxBool isStreaming = false.obs;
  // True while the bodycam (Agora UID 9001) is live in the channel. This is the
  // reliable "bodycam connected" signal in the current setup, where the bodycam
  // joins Agora on its own — independent of the (still flaky) BT link.
  final RxBool bodyCamLiveInAgora = false.obs;
  // Real connection signal shown in the status panel: true while the phone is
  // joined to the Agora channel. Replaces the old hardcoded 'Good' string.
  final RxBool agoraConnected = false.obs;
  StreamSubscription? _bodyCamSub;
  StreamSubscription? _bodyCamDataSub;
  Timer? _statusPollTimer;

  // UI status fields used by map.dart
  RxInt batteryLevel = 0.obs; // bodycam battery (from BT STATUS JSON)
  RxInt phoneBatteryLevel = 0.obs; // this phone's battery (battery_plus)
  RxInt numSatellites = 0.obs;
  RxInt numUsers = 0.obs;

  // DIAGNOSTIC (2026-06-02): whether the bodycam emits GPS over BT. We auto-send
  // GPS_ON on connect and log every raw line; [bodyCamGpsRaw] holds the last
  // line that looks like GPS so it can be shown on screen. Remove this block
  // once we know the bodycam's GPS format (or confirm it sends none).
  final RxString bodyCamGpsRaw = ''.obs;

  final Battery _phoneBattery = Battery();
  StreamSubscription<BatteryState>? _phoneBatterySub;

  void setW1BaseUrl(String ip, int port) => w1Service.setBaseUrl(ip, port);

  double? get lat => incidentGpsReady.value ? incidentLatitude.value : null;
  double? get lng => incidentGpsReady.value ? incidentLongitude.value : null;

  void _resetUploadUiState() {
    uploadUiPhase.value = IncidentUploadUiPhase.idle;
    lastUploadedIncidentId.value = null;
    lastUploadedApiStatus.value = '';
    uploadErrorDetail.value = '';
  }

  // ── Bodycam BT methods ────────────────────────────────────────────────────

  Future<void> takePhoto() async {
    if (_bodyCam.state != BtState.connected) return;
    await _bodyCam.takePhoto();
  }

  Future<void> startStream() async {
    final ok = await ensureAgoraStarted();
    if (!ok) {
      debugPrint('startStream: Agora failed to start — stream aborted');
      return;
    }
    isStreaming.value = true;
    if (_bodyCam.state == BtState.connected) {
      await _bodyCam.startStream();
    }
  }

  Future<void> stopStream() async {
    isStreaming.value = false;
    _ensureCallService()?.setBodyCamVideoActive(false);
    if (_bodyCam.state == BtState.connected) {
      await _bodyCam.stopStream();
    }
    // Agora stays alive for GPS sharing — only shut down on background/close
  }

  Future<void> _shutdownAgora() async {
    if (!Get.isRegistered<CallService>()) {
      _callService = null;
      return;
    }
    try {
      await Get.find<CallService>().shutdown();
    } catch (e) {
      debugPrint('_shutdownAgora: $e');
    } finally {
      await Get.delete<CallService>(force: true);
    }
    _callService = null;
    _remoteLocationsWorker?.dispose();
    _remoteLocationsWorker = null;
    _localLocationWorker?.dispose();
    _localLocationWorker = null;
    _satelliteCountWorker?.dispose();
    _satelliteCountWorker = null;
    _connectedUsersWorker?.dispose();
    _connectedUsersWorker = null;
    _bodyCamVideoWorker?.dispose();
    _bodyCamVideoWorker = null;
    _agoraConnectedWorker?.dispose();
    _agoraConnectedWorker = null;
    _incomingEmergencyWorker?.dispose();
    _incomingEmergencyWorker = null;
    _incomingEmergencyCancelWorker?.dispose();
    _incomingEmergencyCancelWorker = null;
    _stopEmergencyHeartbeat();
    emergencyBroadcastActive.value = false;
    bodyCamLiveInAgora.value = false;
    agoraConnected.value = false;
    numUsers.value = 0;
    numSatellites.value = 0;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _staleRefreshTimer?.cancel();
    _staleRefreshTimer = null;
  }

  Future<void> _autoStartAgora() async {
    final ok = await ensureAgoraStarted();
    if (!ok) {
      debugPrint('MapController: auto Agora start failed');
      return;
    }
    _ensureCallService();
    if (_agentLayersReady && _pulseTimer == null) _startPulseAnimation();
    if (_agentLayersReady && _staleRefreshTimer == null) _startStaleRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Solo liberamos Agora cuando la app se cierra del todo (detached).
    // Cambiar de app (paused) NO debe cortar la conexión: el servicio en
    // primer plano (CallForegroundTaskManager) mantiene vivo el GPS sharing.
    if (state == AppLifecycleState.detached) {
      unawaited(_shutdownAgora());
    } else if (state == AppLifecycleState.resumed) {
      // Red de seguridad: si Agora se hubiera liberado estando fuera, re-arma.
      unawaited(_autoStartAgora());
    }
  }

  Future<void> toggleStream() async {
    if (isStreaming.value) {
      await stopStream();
    } else {
      await startStream();
    }
  }

  /// Panel bodycam button [3] = Bluetooth CONNECT/DISCONNECT toggle. This is the
  /// only thing the panel button does: manage the BT control link to the
  /// bodycam. The bodycam's OWN physical buttons drive everything else —
  /// livestream (which raises the emergency flow here) and normal recording.
  /// Tapping while disconnected connects; while connected, disconnects. Taps
  /// during 'connecting' are ignored.
  Future<void> toggleBodyCamConnection() async {
    final state = _bodyCam.state;
    if (state == BtState.connected) {
      try {
        await _bodyCam.disconnect();
      } catch (e) {
        debugPrint('toggleBodyCamConnection disconnect error: $e');
      }
    } else if (state == BtState.disconnected || state == BtState.error) {
      bodyCamState.value = 'connecting';
      try {
        await _bodyCam.connect();
      } catch (e) {
        debugPrint('toggleBodyCamConnection connect error: $e');
        bodyCamState.value = 'error';
      }
    }
  }

  void _startStatusPoll() {
    _statusPollTimer?.cancel();
    _statusPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_bodyCam.state != BtState.connected) return;
      try {
        await _bodyCam.sendRaw('STATUS\n');
      } catch (_) {}
    });
  }

  /// DIAGNOSTIC (2026-06-02): turn the bodycam's GPS on/off. We auto-call
  /// [bodyCamGpsOn] on connect to observe (via the BODYCAM-RAW/BODYCAM-GPS logs
  /// in _onBodyCamData) whether the bodycam emits any location over BT. Public
  /// so it can be wired to a button. Drop the auto-call if it proves noisy.
  Future<void> bodyCamGpsOn() async {
    try {
      await Future.delayed(const Duration(milliseconds: 700));
      final ok = await _bodyCam.gpsOn();
      debugPrint('BODYCAM-GPS: sent GPS_ON (ack=$ok)');
    } catch (e) {
      debugPrint('bodyCamGpsOn error: $e');
    }
  }

  Future<void> bodyCamGpsOff() async {
    try {
      await _bodyCam.gpsOff();
      debugPrint('BODYCAM-GPS: sent GPS_OFF');
    } catch (e) {
      debugPrint('bodyCamGpsOff error: $e');
    }
  }

  void _onBodyCamData(String data) {
    // ── GPS DIAGNOSTIC (2026-06-02) ───────────────────────────────────────────
    // Dump every raw line so we can see exactly what the bodycam sends (visible
    // in `flutter run`). If a line looks like GPS (NMEA $GP/$GN sentence, or
    // contains lat/lng/satellite keywords), flag it loudly and surface the last
    // one via [bodyCamGpsRaw]. Remove once the GPS format is known.
    debugPrint('BODYCAM-RAW: ${data.trim()}');
    final looksLikeGps = RegExp(r'\$G[PNLA]', caseSensitive: false).hasMatch(data) ||
        RegExp(r'lat|lon|lng|gps|satellite', caseSensitive: false).hasMatch(data);
    if (looksLikeGps) {
      debugPrint('BODYCAM-GPS: ${data.trim()}');
      bodyCamGpsRaw.value = data.trim();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Bodycam physical buttons (keycodes VERIFIED via logcat 2026-06-03):
    //   • SOS button    = keycode 133 → BodyCamServer LIVESTREAMS → sends BTN_STREAM_*
    //   • Record button = keycode 134 → BodyCamServer RECORDS      → sends BTN_REC_*
    // The bodycam ONLY livestreams on SOS (normal recording stays local on the
    // device), therefore:
    //   ▸ BTN_STREAM_* / bodycam live in Agora (uid 9001)  =  SOS  → emergency popup
    //   ▸ BTN_REC_*                                        =  normal recording only
    // SOS is ALSO detected straight from Agora (see _bodyCamVideoWorker) so it
    // works even with NO Bluetooth link; these BT signals are the faster path.
    // ═══════════════════════════════════════════════════════════════════════

    // ── SOS / EMERGENCY · SOS button (133) → bodycam livestream → BTN_STREAM_* ──
    if (data.contains('BTN_STREAM_START')) {
      // The bodycam is livestreaming (uid 9001). Sync its Agora video so the SOS
      // popup's "Receive livestream" has a feed, then raise the SOS flow.
      unawaited(_onBodyCamStreamStarted());
      _onBodyCamSosSignal();
      return;
    }
    if (data.contains('BTN_STREAM_STOP')) {
      unawaited(_onBodyCamStreamStopped());
      _dismissEmergency();
      return;
    }

    // ── NORMAL RECORDING · record button (134) → BTN_REC_*. NEVER raises SOS ──
    if (data.contains('BTN_REC_START')) {
      isRecording.value = true;
      return;
    }
    if (data.contains('BTN_REC_STOP')) {
      isRecording.value = false;
      return;
    }

    // STATUS JSON polling response
    if (data.contains('"battery"') || data.contains('"recording"')) {
      try {
        final batMatch = RegExp(r'"battery":(\d+)').firstMatch(data);
        if (batMatch != null) batteryLevel.value = int.parse(batMatch.group(1)!);

        final recMatch = RegExp(r'"recording":(true|false)').firstMatch(data);
        if (recMatch != null) {
          // Normal recording (record button, keycode 134): just track the state
          // for the panel icon. NEVER raises SOS.
          isRecording.value = recMatch.group(1) == 'true';
        }

        final streamMatch = RegExp(r'"streaming":(true|false)').firstMatch(data);
        if (streamMatch != null) {
          final streaming = streamMatch.group(1) == 'true';
          if (streaming && !isStreaming.value) {
            // SOS backup: the bodycam is livestreaming (SOS button) — sync video
            // + raise the SOS popup, in case BTN_STREAM_START was missed. Guarded
            // by _emergencyDialogOpen so it won't double-pop.
            unawaited(_onBodyCamStreamStarted());
            _onBodyCamSosSignal();
          } else if (!streaming && isStreaming.value) {
            unawaited(_onBodyCamStreamStopped());
            _dismissEmergency();
          }
        }
      } catch (_) {}
    }
  }

  // Bodycam started stream via physical button — sync phone Agora (subscribe only)
  Future<void> _onBodyCamStreamStarted() async {
    final ok = await ensureAgoraStarted();
    if (!ok) return;
    isStreaming.value = true;
    _ensureCallService()?.setBodyCamVideoActive(true);
  }

  // Bodycam stopped stream via physical button — clear video overlay only
  Future<void> _onBodyCamStreamStopped() async {
    isStreaming.value = false;
    _ensureCallService()?.setBodyCamVideoActive(false);
  }

  /// BODYCAM SOS / EMERGENCY.
  /// The bodycam's SOS button (keycode 133) makes it livestream → it joins Agora
  /// as uid 9001 and (over BT) sends BTN_STREAM_*. EITHER path lands here and
  /// raises the emergency popup: the Own/External CHOOSER + siren ("Receive
  /// livestream" shows the bodycam feed, uid 9001, which is live).
  ///
  /// `directExternal` is left at its default (false) ON PURPOSE so the
  /// Own/External chooser is shown (the demo's own-vs-external simulation). Do
  /// NOT pass directExternal:true here — that would skip the chooser.
  ///
  /// Guarded by _showEmergencyFlow's `_emergencyDialogOpen`, so the BT trigger
  /// (BTN_STREAM_START) and the Agora trigger (uid 9001 going live, see
  /// _bodyCamVideoWorker) never stack two popups.
  void _onBodyCamSosSignal() {
    _showEmergencyFlow(
      simulatedExternalAgentLabel,
      sourceUid: CallService.bodyCamAgoraUid,
    );
  }

  // ── W1 HTTP methods ───────────────────────────────────────────────────────

  Future<void> fetchW1Status() async {
    if (w1BaseUrl == null || w1BaseUrl!.isEmpty) return;

    isCheckingStatus.value = true;
    try {
      final raw = await w1Service.getStatusRaw();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        w1StatusMessage.value = '⚠️ Unable to reach device';
        return;
      }
      final map = Map<String, dynamic>.from(decoded);
      final recording = _parseBoolField(map['recording']);

      String? batteryLabel;
      final batt = map['battery'];
      if (batt != null) {
        batteryLabel = batt.toString();
        final parsed = int.tryParse(batteryLabel);
        if (parsed != null && _bodyCam.state != BtState.connected) {
          batteryLevel.value = parsed;
        }
      }

      final prev = _w1LastRecordingPoll;

      if (recording) {
        if (!prev) _w1RecordingStopSnackShown = false;
        _w1EverSawRecordingTrue = true;
        isW1Recording.value = true;
        w1StatusMessage.value = batteryLabel != null && batteryLabel.isNotEmpty
            ? '🔴 Recording in progress — please wait · $batteryLabel'
            : '🔴 Recording in progress — please wait';
      } else {
        isW1Recording.value = false;
        if (prev) {
          w1StatusMessage.value = '✅ Recording complete — tap ⏱ to load video';
          if (!_w1RecordingStopSnackShown) {
            _w1RecordingStopSnackShown = true;
            _safeSnackBar(
              'W1',
              'Recording finished — ready to load',
              backgroundColor: const Color(0xFF2E7D32),
              colorText: Colors.white,
            );
          }
        } else if (!_w1EverSawRecordingTrue) {
          w1StatusMessage.value = 'No active recording';
        } else {
          w1StatusMessage.value = '✅ Recording complete — tap ⏱ to load video';
        }
      }

      _w1LastRecordingPoll = recording;
    } catch (e, st) {
      debugPrint('fetchW1Status: $e\n$st');
      w1StatusMessage.value = '⚠️ Unable to reach device';
    } finally {
      isCheckingStatus.value = false;
    }
  }

  static bool _parseBoolField(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final s = value.trim().toLowerCase();
      return s == 'true' || s == '1' || s == 'yes' || s == 'on';
    }
    if (value is num) return value != 0;
    return false;
  }

  void onTimerClick() {
    if (isW1Recording.value) return;
    w1ImportError.value = '';
    w1ActiveRecording.value = null;
    Get.bottomSheet<void>(
      const W1RecordingImportSheet(),
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: true,
    );
    unawaited(fetchLatestRecording());
  }

  Future<void> fetchRecordings() async {
    w1ImportError.value = '';
    if (w1BaseUrl == null || w1BaseUrl!.isEmpty) {
      throw StateError('W1 base URL is not set; call setW1BaseUrl(ip, port) first.');
    }
    isFetchingRecordings.value = true;
    try {
      final list = await w1Service.getRecordings();
      recordings.assignAll(list);
    } finally {
      isFetchingRecordings.value = false;
    }
  }

  Future<void> fetchLatestRecording() async {
    w1ImportError.value = '';
    w1ActiveRecording.value = null;
    selectedVideo.value = null;
    videoSelectedAt.value = null;

    if (w1BaseUrl == null || w1BaseUrl!.isEmpty) {
      const msg = 'W1 URL not set. Call setW1BaseUrl("192.168.x.x", 8080) first (phone on same Wi‑Fi as the camera).';
      w1ImportError.value = msg;
      _safeSnackBar('W1', msg, backgroundColor: Colors.red.shade900, colorText: Colors.white);
      return;
    }

    isFetchingRecordings.value = true;
    W1Recording? latest;
    try {
      latest = await w1Service.getLatestRecording();
    } catch (e, st) {
      debugPrint('fetchLatestRecording GET: $e\n$st');
      final msg = 'Failed to get latest recording: $e';
      w1ImportError.value = msg;
      _safeSnackBar('W1', msg, backgroundColor: Colors.red.shade900, colorText: Colors.white);
      return;
    } finally {
      isFetchingRecordings.value = false;
    }

    if (latest == null) {
      const msg = 'No latest recording (empty device or HTTP 404).';
      w1ImportError.value = msg;
      _safeSnackBar('W1', msg, backgroundColor: Colors.orange.shade900, colorText: Colors.white);
      return;
    }

    w1ActiveRecording.value = latest;
    isDownloading.value = true;
    try {
      final file = await w1Service.downloadRecording(latest);
      selectedVideo.value = file;
      videoSelectedAt.value = DateTime.now();
      _resetUploadUiState();
    } catch (e, st) {
      debugPrint('fetchLatestRecording download: $e\n$st');
      final msg = 'Download failed: $e';
      w1ImportError.value = msg;
      w1ActiveRecording.value = null;
      _safeSnackBar('W1', msg, backgroundColor: Colors.red.shade900, colorText: Colors.white);
    } finally {
      isDownloading.value = false;
    }
  }

  Future<File?> downloadLatestRecording() async {
    await fetchLatestRecording();
    return selectedVideo.value;
  }

  Future<void> uploadW1DownloadedRecording() async {
    final file = selectedVideo.value;
    if (file == null || !await file.exists()) {
      _safeSnackBar(
        'Upload',
        'No recording file. Use the clock icon to download from W1 first.',
        backgroundColor: Colors.red.shade800,
        colorText: Colors.white,
      );
      return;
    }
    videoSelectedAt.value = DateTime.now();
    _resetUploadUiState();
    await uploadVideo();
  }

  void onMapCreated(MapboxMap map) {
    mapboxMap = map;
    if (mapboxMap == null) return;
    // Chrome settings that don't depend on the style being loaded.
    mapboxMap!.logo.updateSettings(LogoSettings(enabled: false));
    mapboxMap!.attribution.updateSettings(AttributionSettings(enabled: false));
    mapboxMap!.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
    // Position the camera if a location is already available; otherwise the
    // CallService location worker positions it on the first fix.
    final service = _callService;
    if (service != null) {
      final local = service.localLocationRx.value;
      if (local != null) unawaited(_positionCameraOver(local));
    }
  }

  /// Style-dependent setup. MUST run here (not in [onMapCreated]) because the
  /// remote style URI is often not loaded yet when the map is first created —
  /// on a cold start that race made `addSource`/`addLayer` silently fail, so
  /// neither our own location puck nor the remote-agent markers ever appeared
  /// on the very first app launch. [onStyleLoaded] can fire more than once
  /// (e.g. a style reload), so every step is idempotent.
  void onStyleLoaded(StyleLoadedEventData _) {
    final map = mapboxMap;
    if (map == null) return;
    // Our own location puck (native blue dot).
    unawaited(
      map.location.updateSettings(
        LocationComponentSettings(enabled: true, pulsingEnabled: true),
      ),
    );
    unawaited(_setupAgentLayers(map));
  }

  void _safeSnackBar(
    String title,
    String message, {
    Color? backgroundColor,
    Color? colorText,
    Duration duration = const Duration(seconds: 4),
  }) {
    final fg = colorText ?? Colors.white;
    final bg = backgroundColor ?? const Color(0xFF323232);

    void showWithMessenger(ScaffoldMessengerState messenger) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 88),
          duration: duration,
          backgroundColor: bg,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.w700, color: fg, fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text(
                message,
                style: TextStyle(color: fg.withValues(alpha: 0.92), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    void attempt(int frame) {
      final messenger = AppUiKeys.scaffoldMessenger.currentState;
      if (messenger != null) {
        showWithMessenger(messenger);
        return;
      }
      if (frame >= 16) {
        debugPrint('[toast] $title — $message');
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => attempt(frame + 1));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => attempt(0));
  }

  Future<void> pickVideo() async {
    if (isUploading.value || isPickingVideo.value) return;
    isPickingVideo.value = true;
    update();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
        withReadStream: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final f = result.files.single;
      File? file;

      final path = f.path;
      if (path != null && path.isNotEmpty) {
        file = File(path);
        if (!await file.exists()) file = null;
      }

      if (file == null && f.bytes != null && f.bytes!.isNotEmpty) {
        final name = f.name.isNotEmpty ? f.name : 'video_${DateTime.now().millisecondsSinceEpoch}.mp4';
        final safe = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final out = File('${Directory.systemTemp.path}${Platform.pathSeparator}incident_$safe');
        await out.writeAsBytes(f.bytes!, flush: true);
        file = out;
      }

      if (file == null || !await file.exists()) {
        _safeSnackBar('Video', 'Could not access selected file', backgroundColor: Colors.red.shade800, colorText: Colors.white);
        return;
      }

      selectedVideo.value = file;
      videoSelectedAt.value = DateTime.now();
      _resetUploadUiState();
      update();
    } catch (e, st) {
      debugPrint('pickVideo ERROR: $e\n$st');
      _safeSnackBar('Video', 'Picker failed: $e', backgroundColor: Colors.red.shade800, colorText: Colors.white);
    } finally {
      isPickingVideo.value = false;
      update();
    }
  }

  Future<void> uploadVideo() async {
    if (isUploading.value) return;
    if (uploadUiPhase.value == IncidentUploadUiPhase.success) return;

    final file = selectedVideo.value;
    if (file == null || !await file.exists()) {
      _safeSnackBar(
        'Upload',
        'No video selected. Tap camera to choose a file.',
        backgroundColor: Colors.red.shade800,
        colorText: Colors.white,
      );
      return;
    }

    uploadUiPhase.value = IncidentUploadUiPhase.uploading;
    uploadErrorDetail.value = '';
    isUploading.value = true;
    update();
    try {
      final upload = Get.find<UploadService>();
      final metadata = buildIncidentMetadata();
      final res = await upload.uploadVideo(file, metadata);
      if (res.isSuccess) {
        final id = res.id?.trim();
        if (id == null || id.isEmpty) {
          uploadErrorDetail.value = 'Server returned success without incident id';
          uploadUiPhase.value = IncidentUploadUiPhase.error;
        } else {
          lastUploadedIncidentId.value = id;
          final st = res.status?.trim();
          lastUploadedApiStatus.value = (st != null && st.isNotEmpty) ? st : 'PENDING';
          uploadUiPhase.value = IncidentUploadUiPhase.success;
        }
      } else {
        uploadErrorDetail.value = res.errorMessage ?? 'Upload failed';
        uploadUiPhase.value = IncidentUploadUiPhase.error;
      }
    } catch (e, st) {
      debugPrint('UPLOAD ERROR: $e\n$st');
      uploadErrorDetail.value = e.toString();
      uploadUiPhase.value = IncidentUploadUiPhase.error;
    } finally {
      isUploading.value = false;
      update();
    }
  }

  Map<String, dynamic> buildIncidentMetadata() {
    final lat = incidentLatitude.value;
    final lon = incidentLongitude.value;
    final loc = incidentGpsReady.value ? '$lat,$lon' : 'N/A';
    return <String, dynamic>{
      'device': 'W1',
      'timestamp': DateTime.now().toIso8601String(),
      'location': loc,
    };
  }

  /// Mirrors the latest shared location into the incident-metadata fields and
  /// positions the camera. Fed by the [CallService] position stream.
  void _applyLocalLocation(ParticipantLocation location) {
    incidentLatitude.value = location.latitude;
    incidentLongitude.value = location.longitude;
    incidentGpsReady.value = true;
    unawaited(_positionCameraOver(location));
  }

  // ── Audio / CallService delegation ───────────────────────────────────────

  RxBool get isSpeakerMuted {
    final service = _ensureCallService();
    if (service != null) return service.speakerMutedRx;
    return _fallbackSpeakerMuted;
  }

  RxBool get isMicrophoneMuted {
    final service = _ensureCallService();
    if (service != null) return service.microphoneMutedRx;
    return _fallbackMicrophoneMuted;
  }

  MapController();

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    final service = _ensureCallService();
    if (service != null) {
      _attachCallService(service);
    }

    // BT bodycam
    _bodyCam.init();
    _bodyCamSub = _bodyCam.stateStream.listen((state) {
      bodyCamState.value = state.name;
      if (state == BtState.connected) {
        batteryLevel.value = 0;
        // Solo conectar: NO se auto-graba ni auto-stream. Grabación/livestream/PTT
        // los dispara únicamente la bodycam con sus botones físicos (BTN_* en
        // _onBodyCamData). GPS de la bodycam descartado (gpsOn solo enciende el
        // chip, no emite coords) — la ubicación sale del GPS del teléfono.
        _startStatusPoll(); // batería/almacenamiento para el panel; no graba ni transmite
      }
      if (state == BtState.disconnected || state == BtState.error) {
        isRecording.value = false;
        _statusPollTimer?.cancel();
        _statusPollTimer = null;
      }
    });
    _bodyCamDataSub = _bodyCam.dataStream.listen(_onBodyCamData);

    // Auto-start Agora for real-time GPS sharing between agents
    unawaited(_autoStartAgora());

    // Phone battery (always available, unlike the bodycam's BT-sourced level).
    unawaited(_refreshPhoneBattery());
    _phoneBatterySub = _phoneBattery.onBatteryStateChanged.listen((_) {
      unawaited(_refreshPhoneBattery());
    });

    // W1 HTTP status polling (GPS now comes from the shared CallService stream)
    _w1StatusPollTimer?.cancel();
    _w1StatusPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(fetchW1Status());
      unawaited(_refreshPhoneBattery());
    });
    unawaited(fetchW1Status());
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdownAgora());
    _bodyCamSub?.cancel();
    _bodyCamDataSub?.cancel();
    _phoneBatterySub?.cancel();
    _statusPollTimer?.cancel();
    _bodyCam.dispose();
    _w1StatusPollTimer?.cancel();
    _w1StatusPollTimer = null;
    _remoteLocationsWorker?.dispose();
    _localLocationWorker?.dispose();
    _satelliteCountWorker?.dispose();
    _connectedUsersWorker?.dispose();
    _bodyCamVideoWorker?.dispose();
    _agoraConnectedWorker?.dispose();
    _incomingEmergencyWorker?.dispose();
    _incomingEmergencyCancelWorker?.dispose();
    _emergencyHeartbeatTimer?.cancel();
    _emergencyHeartbeatTimer = null;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _staleRefreshTimer?.cancel();
    _staleRefreshTimer = null;
    super.onClose();
  }

  // ── SOS notification centre + my-location ──────────────────────────────────

  /// Removes a notification from the centre. "Accept" and "Close" both dismiss
  /// it (for now the alert is informational — accepting just acknowledges it).
  void dismissSosNotification(SosNotification n) {
    sosNotifications.removeWhere((e) => e.sessionKey == n.sessionKey);
  }

  /// Clears all SOS notifications at once.
  void clearSosNotifications() => sosNotifications.clear();

  /// Recenters the map on this device's own GPS position — the "my location"
  /// button (like Google Maps). No-op until we have a fix.
  Future<void> recenterOnSelf() async {
    final map = mapboxMap;
    if (map == null) return;
    if (!incidentGpsReady.value) {
      _safeSnackBar(
        'Location',
        'Waiting for GPS fix…',
        backgroundColor: const Color(0xFF424242),
        colorText: Colors.white,
      );
      return;
    }
    try {
      await map.flyTo(
        CameraOptions(
          center: Point(
            coordinates: Position(
              incidentLongitude.value,
              incidentLatitude.value,
            ),
          ),
          zoom: 16.0,
          pitch: 60.0,
          padding:
              MbxEdgeInsets(bottom: 200.0, top: 0.0, left: 0.0, right: 0.0),
        ),
        MapAnimationOptions(duration: 800),
      );
    } catch (error, stackTrace) {
      debugPrint('recenterOnSelf: $error\n$stackTrace');
    }
  }

  Future<void> _refreshPhoneBattery() async {
    try {
      final level = await _phoneBattery.batteryLevel;
      phoneBatteryLevel.value = level;
    } catch (error) {
      debugPrint('Phone battery read failed: $error');
    }
  }

  Future<void> toggleSpeakerMute() async {
    final service = _ensureCallService();
    if (service == null) {
      debugPrint('CallService not available; speaker toggle ignored');
      return;
    }
    final targetMuted = !service.isSpeakerMuted;
    try {
      await service.setSpeakerMuted(muted: targetMuted);
    } catch (error, stackTrace) {
      debugPrint('Speaker toggle failed: $error\n$stackTrace');
    }
  }

  Future<void> toggleMicrophoneMute() async {
    final service = _ensureCallService();
    if (service == null) {
      debugPrint('CallService not available; microphone toggle ignored');
      return;
    }
    final targetMuted = !service.isMicrophoneMuted;
    try {
      await service.setMicrophoneMuted(muted: targetMuted);
    } catch (error, stackTrace) {
      debugPrint('Microphone toggle failed: $error\n$stackTrace');
    }
  }

  CallService? _ensureCallService() {
    if (_callService != null) return _callService;

    if (Get.isRegistered<CallService>()) {
      try {
        _callService = Get.find<CallService>();
        _attachCallService(_callService!);
      } catch (error, stackTrace) {
        debugPrint('Failed to locate CallService: $error\n$stackTrace');
      }
    }

    return _callService;
  }

  void _attachCallService(CallService service) {
    _remoteLocationsWorker ??= ever<Map<int, ParticipantLocation>>(
      service.remoteLocationsRx,
      (_) => unawaited(_refreshParticipantAnnotations()),
    );

    // Incident GPS derives from the single CallService position stream — this
    // controller no longer runs its own Geolocator subscription.
    final initialLocation = service.localLocationRx.value;
    if (initialLocation != null) _applyLocalLocation(initialLocation);
    _localLocationWorker ??= ever<ParticipantLocation?>(
      service.localLocationRx,
      (location) {
        if (location != null) _applyLocalLocation(location);
        unawaited(_refreshParticipantAnnotations());
      },
    );

    numSatellites.value = service.satelliteCountRx.value;
    _satelliteCountWorker ??= ever<int>(service.satelliteCountRx, (count) {
      numSatellites.value = count;
    });

    numUsers.value = service.connectedUsersCountRx.value;
    _connectedUsersWorker ??= ever<int>(service.connectedUsersCountRx, (count) {
      final joined = count > numUsers.value;
      numUsers.value = count;
      // A new peer just joined while we have an active SOS — re-announce it
      // straight away so they get alerted without waiting for the next
      // heartbeat tick.
      if (joined && emergencyBroadcastActive.value) {
        final service = _callService;
        if (service != null) {
          unawaited(service.broadcastEmergency(
            officer: officerCode,
            startedAt: _emergencyStartedAt,
          ));
        }
      }
    });

    bodyCamLiveInAgora.value = service.bodyCamVideoUidRx.value != null;
    _bodyCamVideoWorker ??= ever<int?>(service.bodyCamVideoUidRx, (uid) {
      final wasLive = bodyCamLiveInAgora.value;
      final isLive = uid != null;
      bodyCamLiveInAgora.value = isLive;
      // SOS over Agora — NO Bluetooth required. The SOS button (keycode 133)
      // makes the bodycam livestream, so it joins Agora as uid 9001. The bodycam
      // ONLY streams on SOS (normal recording stays local), so uid 9001 going
      // live == SOS. This is the reliable trigger when the BT link is down.
      // Guarded by _emergencyDialogOpen so it won't stack with the BT
      // BTN_STREAM_START trigger.
      if (isLive && !wasLive) _onBodyCamSosSignal();
      if (!isLive && wasLive) _dismissEmergency();
    });

    agoraConnected.value = service.hasJoinedRx.value;
    _agoraConnectedWorker ??= ever<bool>(service.hasJoinedRx, (joined) {
      agoraConnected.value = joined;
    });

    // Emergency signal received from another agent (their map button). The
    // sender never receives its own data-stream message, so this only fires on
    // the OTHER devices in the channel.
    _incomingEmergencyWorker ??= ever<EmergencySignal?>(
      service.incomingEmergencyRx,
      (signal) {
        if (signal == null) return;
        service.consumeEmergency();
        // Heartbeat dedupe: the emitter re-broadcasts the SAME session every few
        // seconds so late joiners get it. Only the FIRST time we see a session
        // do we alert + log it; later repeats are ignored.
        if (_seenSosKeys.contains(signal.sessionKey)) return;
        _seenSosKeys.add(signal.sessionKey);

        // Record it in the notification centre (officer, GPS, time) so it's
        // reviewable later even if dismissed now.
        sosNotifications.insert(
          0,
          SosNotification(
            sessionKey: signal.sessionKey,
            officer: signal.officer.trim(),
            uid: signal.uid,
            receivedAt: DateTime.now(),
            emittedAt: signal.timestamp,
            latitude: signal.latitude,
            longitude: signal.longitude,
          ),
        );

        final officer = signal.officer.trim();
        // A signal from another phone is ALWAYS external — skip the Own/External
        // chooser and show the emergency popup (siren) directly. signal.uid is
        // the emitting agent's Agora uid — the camera the receiver should watch.
        _showEmergencyFlow(
          officer.isNotEmpty ? 'Officer $officer' : simulatedExternalAgentLabel,
          sourceUid: signal.uid,
          directExternal: true,
        );
      },
    );

    // Remote cancellation: dismiss the alert popup + stop the siren. The
    // "Signal cut" notice itself is shown by the livestream WATCH view when the
    // source's video actually stops (so it appears for whoever is watching the
    // feed, regardless of how the emitter cut it).
    _incomingEmergencyCancelWorker ??= ever<EmergencyCancel?>(
      service.incomingEmergencyCancelRx,
      (cancel) {
        if (cancel == null) return;
        service.consumeEmergencyCancel();
        _dismissEmergency();
      },
    );
  }

  // ── Emergency / recording-signal flow ─────────────────────────────────────

  /// Toggles the warning/recording broadcast to every other device in the
  /// channel. Wired to the map "livestream" button. First tap emits the
  /// emergency; a second tap cancels it (receivers dismiss the popup + silence
  /// the siren). The sender never sees its own popup (Agora doesn't echo its
  /// own data messages).
  Future<void> triggerEmergencyBroadcast() async {
    final ok = await ensureAgoraStarted();
    if (!ok) {
      debugPrint('triggerEmergencyBroadcast: Agora not available');
      return;
    }
    final service = _ensureCallService();
    if (service == null) return;

    if (emergencyBroadcastActive.value) {
      _stopEmergencyHeartbeat();
      await service.broadcastEmergencyCancel(officer: officerCode);
      // Stop publishing our camera once the emergency is cancelled.
      await service.stopCameraPublish(stopPreview: true);
      emergencyBroadcastActive.value = false;
      _safeSnackBar(
        'Emergency',
        'Signal cancelled',
        backgroundColor: const Color(0xFF424242),
        colorText: Colors.white,
      );
    } else {
      // The livestream now carries voice — make sure camera + mic are granted
      // before publishing, otherwise receivers get video without audio.
      await Permission.camera.request();
      await Permission.microphone.request();
      // Start publishing this phone's camera + mic so receivers can watch AND
      // hear our feed, then announce the emergency carrying our uid as source.
      await service.startCameraPublish();
      // One stable session start for this SOS — reused by every heartbeat so
      // receivers dedupe. Then begin re-broadcasting so late joiners get it.
      _emergencyStartedAt = DateTime.now();
      await service.broadcastEmergency(
        officer: officerCode,
        startedAt: _emergencyStartedAt,
      );
      _startEmergencyHeartbeat();
      emergencyBroadcastActive.value = true;
      _safeSnackBar(
        'Emergency',
        'Signal sent to connected devices',
        backgroundColor: const Color(0xFFB71C1C),
        colorText: Colors.white,
      );
    }
  }

  /// Periodically re-announces the active SOS so a device that opens the app
  /// mid-emergency still receives it. Reuses [_emergencyStartedAt] so receivers
  /// can tell repeats apart from new emergencies.
  void _startEmergencyHeartbeat() {
    _emergencyHeartbeatTimer?.cancel();
    _emergencyHeartbeatTimer = Timer.periodic(
      _emergencyHeartbeatInterval,
      (_) {
        final service = _callService;
        if (service == null || !emergencyBroadcastActive.value) return;
        unawaited(service.broadcastEmergency(
          officer: officerCode,
          startedAt: _emergencyStartedAt,
        ));
      },
    );
  }

  void _stopEmergencyHeartbeat() {
    _emergencyHeartbeatTimer?.cancel();
    _emergencyHeartbeatTimer = null;
    _emergencyStartedAt = null;
  }

  /// Dismisses an open emergency popup (which stops the looping siren via the
  /// dialog's dispose). Used on remote cancellation and on local bodycam
  /// REC_STOP. No-op if our emergency flow isn't currently showing.
  void _dismissEmergency() {
    if (!_emergencyDialogOpen) return;
    if (Get.isDialogOpen ?? false) Get.back<void>();
    _emergencyDialogOpen = false;
  }

  /// Shows the emergency flow, guarding against stacking. [sourceUid] is the
  /// Agora uid whose video to show if the presenter opens the livestream: 9001 =
  /// bodycam, any other uid = the emitting agent's phone. When [directExternal]
  /// is true the Own/External chooser is skipped and the siren popup shows right
  /// away (signals from another phone are always external).
  void _showEmergencyFlow(
    String agentLabel, {
    required int sourceUid,
    bool directExternal = false,
  }) {
    if (_emergencyDialogOpen) return;
    _emergencyDialogOpen = true;
    showEmergencyTreatmentFlow(
      agentLabel: agentLabel,
      onOpenLivestream: () => _openLivestreamScreen(watchUid: sourceUid),
      directExternal: directExternal,
    ).whenComplete(() => _emergencyDialogOpen = false);
  }

  /// Opens the livestream screen. With [watchUid] it renders that remote
  /// source's video (bodycam 9001 or an agent's phone) instead of going live
  /// with this phone's own camera; without it, it's the publish-mode screen
  /// (same as the map's right-edge handle).
  Future<void> _openLivestreamScreen({int? watchUid}) async {
    await Get.to<void>(
      () => CameraLivestreamView(watchUid: watchUid),
      transition: Transition.rightToLeft,
      duration: const Duration(milliseconds: 280),
    );
  }

  /// Panel photo button: opens the phone's NATIVE camera app (via image_picker),
  /// then saves the captured photo locally into the "falcon_pictures" folder.
  /// No Agora/bodycam involvement — the native camera handles orientation, so
  /// the picture isn't rotated/inverted like the Agora snapshot was.
  Future<void> openPhotoCapture() async {
    try {
      // CAMERA is declared in the manifest (Agora), so image_picker requires it
      // granted at runtime before launching the camera app.
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        _safeSnackBar(
          'Photo',
          'Camera permission denied',
          backgroundColor: Colors.red.shade900,
          colorText: Colors.white,
        );
        return;
      }

      final img_picker.XFile? shot = await img_picker.ImagePicker().pickImage(
        source: img_picker.ImageSource.camera,
        preferredCameraDevice: img_picker.CameraDevice.rear,
      );
      if (shot == null) return; // user backed out of the camera

      final store = Get.isRegistered<PhotoStorageService>()
          ? Get.find<PhotoStorageService>()
          : Get.put(PhotoStorageService(), permanent: true);
      final saved = await store.importFile(File(shot.path));

      _safeSnackBar(
        'Photo',
        'Saved to falcon_pictures',
        backgroundColor: const Color(0xFF1B5E20),
        colorText: Colors.white,
      );
      debugPrint('openPhotoCapture: saved ${saved.path}');
    } catch (error, stackTrace) {
      debugPrint('openPhotoCapture: $error\n$stackTrace');
      _safeSnackBar(
        'Photo',
        'Could not capture photo',
        backgroundColor: Colors.red.shade900,
        colorText: Colors.white,
      );
    }
  }

  Future<void> _setupAgentLayers(MapboxMap map) async {
    // Idempotent: [onStyleLoaded] can fire repeatedly. Add the source/layers
    // only if missing, and only mark ready once the source genuinely exists —
    // never assume success, so a failed add can't leave us "ready" with no
    // source (which silently drops every marker, the original first-launch bug).
    try {
      if (!await map.style.styleSourceExists(_kAgentSourceId)) {
        await map.style.addSource(
          GeoJsonSource(
            id: _kAgentSourceId,
            data: '{"type":"FeatureCollection","features":[]}',
          ),
        );
      }

      // Pulse ring — animates outward and fades. The filter hides the pulse for
      // agents that have lost signal (stale == true) so a frozen marker reads as
      // "no live position" rather than an active ping.
      if (!await map.style.styleLayerExists(_kAgentPulseLayerId)) {
        await map.style.addLayer(
          CircleLayer(
            id: _kAgentPulseLayerId,
            sourceId: _kAgentSourceId,
            slot: 'top',
            filter: <Object>['!', <Object>['get', 'stale']],
            circleColor: 0xFFFFD700,
            circleRadius: 8.0,
            circleOpacity: 0.5,
            circleStrokeWidth: 0.0,
            circleEmissiveStrength: 1.0,
          ),
        );
      }

      // Solid dot with white halo on top. Gold while live, grey once the agent
      // has lost signal (data-driven on the per-feature `stale` property).
      if (!await map.style.styleLayerExists(_kAgentDotLayerId)) {
        await map.style.addLayer(
          CircleLayer(
            id: _kAgentDotLayerId,
            sourceId: _kAgentSourceId,
            slot: 'top',
            circleColorExpression: <Object>[
              'case',
              <Object>['get', 'stale'],
              '#9E9E9E',
              '#FFD700',
            ],
            circleRadius: 8.0,
            circleOpacity: 1.0,
            circleStrokeColor: 0xFFFFFFFF,
            circleStrokeWidth: 3.0,
            circleStrokeOpacity: 1.0,
            circleEmissiveStrength: 1.0,
          ),
        );
      }

      // Text label below the dot, shown only when the agent has lost signal:
      // "Última conexión: HH:mm:ss". Fresh agents carry an empty label string.
      if (!await map.style.styleLayerExists(_kAgentLabelLayerId)) {
        await map.style.addLayer(
          SymbolLayer(
            id: _kAgentLabelLayerId,
            sourceId: _kAgentSourceId,
            slot: 'top',
            textFieldExpression: <Object>['get', 'label'],
            textSize: 11.0,
            textOffset: <double>[0.0, 1.6],
            textAnchor: TextAnchor.TOP,
            textColor: 0xFFFFFFFF,
            textHaloColor: 0xCC000000,
            textHaloWidth: 1.4,
            textAllowOverlap: true,
            textEmissiveStrength: 1.0,
          ),
        );
      }
    } catch (e) {
      debugPrint('_setupAgentLayers: $e');
    }

    _agentLayersReady = await map.style.styleSourceExists(_kAgentSourceId);
    if (!_agentLayersReady) {
      debugPrint('_setupAgentLayers: source missing after setup — will retry on next style load');
      return;
    }
    _startPulseAnimation();
    _startStaleRefresh();
    unawaited(_refreshParticipantAnnotations());
  }

  /// Re-evaluates marker staleness on a timer. Going silent fires no event, so
  /// without this tick a peer that lost signal would stay gold until its next
  /// (never-arriving) update; this flips it to grey + shows the label.
  void _startStaleRefresh() {
    _staleRefreshTimer?.cancel();
    _staleRefreshTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refreshParticipantAnnotations()),
    );
  }

  void _startPulseAnimation() {
    _pulseTimer?.cancel();
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      _pulsePhase = (_pulsePhase + 0.033) % 1.0;
      final radius = 8.0 + (_pulsePhase * 20.0);
      final opacity = (1.0 - _pulsePhase) * 0.55;
      final map = mapboxMap;
      if (map == null) return;
      unawaited(
        map.style
            .setStyleLayerProperty(_kAgentPulseLayerId, 'circle-radius', radius)
            .catchError((_) {}),
      );
      unawaited(
        map.style
            .setStyleLayerProperty(_kAgentPulseLayerId, 'circle-opacity', opacity)
            .catchError((_) {}),
      );
    });
  }

  Future<void> _refreshParticipantAnnotations() async {
    if (!_agentLayersReady) return;
    final map = mapboxMap;
    if (map == null) return;

    final service = _callService;
    final localUid = service?.localLocationRx.value?.uid;

    final features = <Map<String, dynamic>>[];
    if (service != null) {
      final lastSeen = service.remoteLastSeen;
      final now = DateTime.now();
      for (final entry in service.remoteLocationsRx.entries) {
        if (entry.key == localUid) continue;
        final seenAt = lastSeen[entry.key];
        final isStale = seenAt == null || now.difference(seenAt) > _staleAfter;
        features.add(<String, dynamic>{
          'type': 'Feature',
          'geometry': <String, dynamic>{
            'type': 'Point',
            'coordinates': <double>[entry.value.longitude, entry.value.latitude],
          },
          'properties': <String, dynamic>{
            'uid': entry.key,
            'stale': isStale,
            'label': isStale
                ? 'Last seen: ${_formatClock(seenAt ?? entry.value.timestamp)}'
                : '',
          },
        });
      }
    }

    final geoJson = jsonEncode(<String, dynamic>{
      'type': 'FeatureCollection',
      'features': features,
    });

    try {
      await map.style.setStyleSourceProperty(_kAgentSourceId, 'data', geoJson);
    } catch (e) {
      debugPrint('_refreshParticipantAnnotations: $e');
    }
  }

  /// Formats a local wall-clock time as HH:mm:ss for the "última conexión" label.
  static String _formatClock(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Future<void> _positionCameraOver(ParticipantLocation location) async {
    if (_hasPositionedInitialCamera) return;
    final map = mapboxMap;
    if (map == null) return;

    try {
      await map.setCamera(
        CameraOptions(
          center: Point(
            coordinates: Position(location.longitude, location.latitude),
          ),
          zoom: 16.0,
          pitch: 60.0,
          padding: MbxEdgeInsets(bottom: 200.0, top: 0.0, left: 0.0, right: 0.0),
        ),
      );
      _hasPositionedInitialCamera = true;
    } catch (error, stackTrace) {
      debugPrint('_positionCameraOver: $error\n$stackTrace');
    }
  }
}
