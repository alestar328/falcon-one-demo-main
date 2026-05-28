import 'dart:async';
import 'dart:io';

import 'package:falcon_one_demo/services/glasses_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

class GlassesController extends GetxController {
  GlassesController({GlassesService? service})
      : _glasses = service ?? Get.find<GlassesService>();

  final GlassesService _glasses;

  // API key: pass via --dart-define=BLEEQUP_API_KEY=xxx, or any value works
  // (SDK validation is disabled in this build — any non-empty string is accepted)
  static const String _apiKey =
      String.fromEnvironment('BLEEQUP_API_KEY', defaultValue: 'falcon-one');

  // WiFi password for glasses AP: must be exactly 8 alphanumeric chars
  static const String _wifiPassword = 'falcon01';

  final RxBool isConnected      = false.obs;
  final RxBool isRecording      = false.obs;
  final RxBool isDownloading    = false.obs;
  final RxDouble downloadProgress = 0.0.obs;
  final RxString statusMessage  = 'Tap to connect glasses'.obs;
  final Rxn<String> lastVideoPath = Rxn<String>();
  final RxBool downloadFailed   = false.obs;
  final RxBool isPreparingVideo = false.obs;
  final RxBool isScanning       = false.obs;
  final RxBool scanTimedOut     = false.obs;
  final RxList<Map<String, String>> discoveredDevices =
      <Map<String, String>>[].obs;

  bool _recordingActionInFlight  = false;
  bool _downloadPipelineInFlight = false;
  String? _pendingFileName;
  Timer? _scanTimer;

  StreamSubscription<GlassesConnectionState>? _connSub;
  StreamSubscription<bool>?                   _recSub;
  StreamSubscription<double>?                 _progSub;
  StreamSubscription<String>?                 _videoSub;
  StreamSubscription<String>?                 _errSub;
  StreamSubscription<Map<String, String>>?    _devSub;

  @override
  void onInit() {
    super.onInit();
    _connSub  = _glasses.connectionState.listen(_onConnection);
    _recSub   = _glasses.recordingState.listen(_onRecording);
    _progSub  = _glasses.downloadProgress.listen(_onProgress);
    _videoSub = _glasses.videoReady.listen(_onVideoReady);
    _errSub   = _glasses.nativeErrors.listen(_onError);
    _devSub   = _glasses.deviceFound.listen(_onDeviceFound);
  }

  @override
  void onClose() {
    _scanTimer?.cancel();
    _connSub?.cancel();
    _recSub?.cancel();
    _progSub?.cancel();
    _videoSub?.cancel();
    _errSub?.cancel();
    _devSub?.cancel();
    super.onClose();
  }

  // ── Stream handlers ─────────────────────────────────────────────────────────

  void _onConnection(GlassesConnectionState s) {
    if (s == GlassesConnectionState.connected) {
      isConnected.value = true;
      statusMessage.value = lastVideoPath.value != null
          ? 'Glasses connected — video ready'
          : 'Glasses connected';
    } else {
      isConnected.value = false;
      isRecording.value = false;
      isDownloading.value = false;
      isPreparingVideo.value = false;
      downloadProgress.value = 0;
      _downloadPipelineInFlight = false;
      _recordingActionInFlight  = false;
      lastVideoPath.value = null;
      downloadFailed.value = false;
      discoveredDevices.clear();
      statusMessage.value = 'Tap to connect glasses';
    }
  }

  void _onRecording(bool on) {
    isRecording.value = on;
    if (on) statusMessage.value = 'Glasses recording…';
  }

  void _onProgress(double p) {
    downloadProgress.value = p;
    if (isDownloading.value) {
      statusMessage.value = 'Downloading… ${(p * 100).round()}%';
    }
  }

  void _onVideoReady(String fileName) {
    if (_downloadPipelineInFlight) return;
    _startDownloadPipeline(fileName);
  }

  void _onError(String msg) {
    downloadFailed.value = true;
    statusMessage.value = 'Error: $msg';
    isDownloading.value = false;
    isPreparingVideo.value = false;
    _downloadPipelineInFlight = false;
  }

  void _onDeviceFound(Map<String, String> m) {
    final addr = m['address'] ?? '';
    if (addr.isEmpty) return;
    if (discoveredDevices.any((e) => e['address'] == addr)) return;
    discoveredDevices.add(Map<String, String>.from(m));
  }

  // ── Public actions ──────────────────────────────────────────────────────────

  /// Main button tap: if not connected → scan + pick device; if connected → toggle recording.
  Future<void> onGlassesButtonTapped() async {
    if (!isConnected.value) {
      await beginConnectFlow();
    } else if (isRecording.value) {
      await stopRecording();
    } else {
      await startRecording();
    }
  }

  Future<void> beginConnectFlow() async {
    if (!Platform.isAndroid) {
      statusMessage.value = 'Glasses require Android';
      return;
    }
    final ok = await _ensurePermissions();
    if (!ok) {
      statusMessage.value = 'Bluetooth / location permission required';
      return;
    }
    discoveredDevices.clear();
    scanTimedOut.value = false;
    isScanning.value = true;
    downloadFailed.value = false;
    statusMessage.value = 'Scanning…';

    // Populate with already-bonded BT devices immediately so user can pick
    // even before the BLE scan finds anything.
    try {
      final bonded = await _glasses.getBondedDevices();
      for (final d in bonded) {
        _onDeviceFound(d);
      }
      debugPrint('[GlassesController] bonded devices: $bonded');
    } catch (e) {
      debugPrint('[GlassesController] getBondedDevices error: $e');
    }

    try {
      await _glasses.initSdk(_apiKey);
      await _glasses.startScan();
      _openDevicePickerSheet();
      // Native scan runs 10 s — flip timeout flag one second after it ends
      _scanTimer?.cancel();
      _scanTimer = Timer(const Duration(seconds: 11), () {
        scanTimedOut.value = true;
        isScanning.value = false;
      });
    } catch (e, st) {
      debugPrint('[GlassesController] beginConnectFlow: $e\n$st');
      downloadFailed.value = true;
      statusMessage.value = 'Scan failed';
      isScanning.value = false;
    }
  }

  void _openDevicePickerSheet() {
    Get.bottomSheet<void>(
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Select glasses',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 280,
                child: Obx(() {
                  if (discoveredDevices.isEmpty) {
                    if (scanTimedOut.value) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.bluetooth_searching,
                                color: Colors.white38, size: 40),
                            const SizedBox(height: 12),
                            const Text(
                              'No glasses found',
                              style: TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Make sure the glasses are on and nearby',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            TextButton(
                              onPressed: () {
                                Get.back<void>();
                                beginConnectFlow();
                              },
                              child: const Text('Retry scan'),
                            ),
                          ],
                        ),
                      );
                    }
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(strokeWidth: 2.5),
                          SizedBox(height: 12),
                          Text(
                            'Searching…',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.separated(
                    itemCount: discoveredDevices.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: Colors.white24),
                    itemBuilder: (context, i) {
                      final d = discoveredDevices[i];
                      final name = d['name'] ?? '';
                      final addr = d['address'] ?? '';
                      return ListTile(
                        title: Text(
                          name.isEmpty ? addr : name,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          addr,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        onTap: () => _connectToAddress(addr),
                      );
                    },
                  );
                }),
              ),
              TextButton(
                onPressed: () => Get.back<void>(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
    );
  }

  Future<void> _connectToAddress(String address) async {
    if (address.isEmpty) return;
    try {
      try { Get.back<void>(); } catch (_) {}
      statusMessage.value = 'Connecting… (glasses must be on)';
      await _glasses.connectDevice(address: address);
    } catch (e, st) {
      debugPrint('[GlassesController] _connectToAddress: $e\n$st');
      downloadFailed.value = true;
      final msg = e.toString();
      if (msg.contains('CONNECT')) {
        statusMessage.value = 'Timed out — power glasses off/on and retry';
      } else {
        statusMessage.value = 'Connect failed';
      }
    }
  }

  Future<void> startRecording() async {
    if (_recordingActionInFlight || isRecording.value) return;
    if (!isConnected.value) { statusMessage.value = 'Connect glasses first'; return; }
    if (isDownloading.value || isPreparingVideo.value) return;
    _recordingActionInFlight = true;
    try {
      await _glasses.startRecording();
    } catch (e, st) {
      debugPrint('[GlassesController] startRecording: $e\n$st');
      statusMessage.value = 'Start recording failed';
    } finally {
      _recordingActionInFlight = false;
    }
  }

  Future<void> stopRecording() async {
    if (_recordingActionInFlight || !isRecording.value) return;
    _recordingActionInFlight = true;
    try {
      await _glasses.stopRecording();
    } catch (e, st) {
      debugPrint('[GlassesController] stopRecording: $e\n$st');
      statusMessage.value = 'Stop recording failed';
    } finally {
      _recordingActionInFlight = false;
    }
  }

  Future<void> _startDownloadPipeline(String fileName) async {
    _downloadPipelineInFlight = true;
    _pendingFileName = fileName;
    downloadFailed.value = false;
    lastVideoPath.value = null;
    downloadProgress.value = 0;

    try {
      statusMessage.value = 'Enabling glasses WiFi…';
      isPreparingVideo.value = true;
      await _glasses.turnOnWifi(_wifiPassword);

      // Give the glasses AP time to come up before attempting HTTP
      await Future<void>.delayed(const Duration(seconds: 2));

      isDownloading.value = true;
      statusMessage.value = 'Downloading video…';
      final path = await _glasses.downloadFile(fileName);
      if (path == null || path.isEmpty) throw StateError('Download returned no path');

      await _glasses.turnOffWifi();

      lastVideoPath.value = path;
      statusMessage.value = 'Video saved';
      downloadFailed.value = false;
    } catch (e, st) {
      debugPrint('[GlassesController] _startDownloadPipeline: $e\n$st');
      downloadFailed.value = true;
      statusMessage.value = 'WiFi / download failed';
      try { await _glasses.turnOffWifi(); } catch (_) {}
    } finally {
      isDownloading.value = false;
      isPreparingVideo.value = false;
      _downloadPipelineInFlight = false;
    }
  }

  Future<void> retryLastDownload() async {
    final name = _pendingFileName;
    if (name == null || name.isEmpty) return;
    downloadFailed.value = false;
    await _startDownloadPipeline(name);
  }

  bool get canRetryDownload =>
      downloadFailed.value && (_pendingFileName?.isNotEmpty ?? false);

  Future<void> disconnect() async {
    try {
      await _glasses.disconnect();
    } catch (_) {}
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return false;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.nearbyWifiDevices,
    ].request();
    return statuses.values
        .every((s) => s == PermissionStatus.granted || s == PermissionStatus.limited);
  }
}
