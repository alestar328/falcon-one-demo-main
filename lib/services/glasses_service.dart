import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

const _method = MethodChannel('com.falconone/glasses');
const _event  = EventChannel('com.falconone/glasses_events');

enum GlassesConnectionState { disconnected, connecting, connected }

class GlassesService extends GetxService {
  final _connectionState  = StreamController<GlassesConnectionState>.broadcast();
  final _recordingState   = StreamController<bool>.broadcast();
  final _downloadProgress = StreamController<double>.broadcast();
  final _videoReady       = StreamController<String>.broadcast();
  final _nativeErrors     = StreamController<String>.broadcast();
  final _deviceFound      = StreamController<Map<String, String>>.broadcast();

  Stream<GlassesConnectionState> get connectionState   => _connectionState.stream;
  Stream<bool>                   get recordingState    => _recordingState.stream;
  Stream<double>                 get downloadProgress  => _downloadProgress.stream;
  Stream<String>                 get videoReady        => _videoReady.stream;
  Stream<String>                 get nativeErrors      => _nativeErrors.stream;
  Stream<Map<String, String>>    get deviceFound       => _deviceFound.stream;

  StreamSubscription<dynamic>? _eventSub;

  @override
  void onInit() {
    super.onInit();
    _eventSub = _event.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (Object e, StackTrace st) =>
          debugPrint('[GlassesService] event stream error: $e\n$st'),
    );
  }

  @override
  void onClose() {
    _eventSub?.cancel();
    _eventSub = null;
    _connectionState.close();
    _recordingState.close();
    _downloadProgress.close();
    _videoReady.close();
    _nativeErrors.close();
    _deviceFound.close();
    super.onClose();
  }

  void _onNativeEvent(dynamic raw) {
    if (raw is! Map) return;
    final map = Map<Object?, Object?>.from(raw);
    final event = map['event']?.toString();
    if (event == null) return;

    switch (event) {
      case 'onConnected':
        _connectionState.add(GlassesConnectionState.connected);
      case 'onDisconnected':
        _connectionState.add(GlassesConnectionState.disconnected);
      case 'onRecordingStarted':
        _recordingState.add(true);
      case 'onRecordingStopped':
        _recordingState.add(false);
      case 'onVideoReady':
        final name = map['fileName']?.toString() ?? '';
        if (name.isNotEmpty) _videoReady.add(name);
      case 'onDownloadProgress':
        final p = map['progress'];
        if (p is num) _downloadProgress.add(p.clamp(0.0, 1.0).toDouble());
      case 'onDownloadComplete':
        _downloadProgress.add(1.0);
      case 'onError':
        final msg = map['message']?.toString() ?? 'Unknown glasses error';
        _nativeErrors.add(msg);
      case 'onDeviceFound':
        final name    = map['name']?.toString()    ?? '';
        final address = map['address']?.toString() ?? '';
        if (address.isNotEmpty) {
          _deviceFound.add({'name': name, 'address': address});
        }
      case 'onWifiOn':
        // WiFi AP active on glasses — Flutter can now prompt user to connect
        break;
      default:
        debugPrint('[GlassesService] unhandled event: $event');
    }
  }

  Future<void> initSdk(String apiKey) async {
    await _method.invokeMethod<void>('initSdk', {'apiKey': apiKey});
  }

  Future<List<Map<String, String>>> getBondedDevices() async {
    final raw = await _method.invokeListMethod<Object?>('getBondedDevices');
    if (raw == null) return [];
    return raw
        .whereType<Map>()
        .map((m) => {
              'name': m['name']?.toString() ?? '',
              'address': m['address']?.toString() ?? '',
            })
        .where((m) => m['address']!.isNotEmpty)
        .toList();
  }

  Future<void> startScan() async {
    await _method.invokeMethod<void>('startScan');
  }

  Future<void> stopScan() async {
    await _method.invokeMethod<void>('stopScan');
  }

  Future<void> connectDevice({String? address}) async {
    await _method.invokeMethod<void>(
      'connectDevice',
      {if (address != null && address.isNotEmpty) 'address': address},
    );
  }

  Future<void> disconnect() async {
    await _method.invokeMethod<void>('disconnect');
  }

  Future<void> startRecording() async {
    await _method.invokeMethod<void>('startRecording');
  }

  Future<void> stopRecording() async {
    await _method.invokeMethod<void>('stopRecording');
  }

  Future<void> takePhoto() async {
    await _method.invokeMethod<void>('takePhoto');
  }

  Future<Map<String, String>?> turnOnWifi(String password) async {
    final res = await _method.invokeMapMethod<String, String>(
      'turnOnWifi', {'password': password},
    );
    return res;
  }

  Future<void> turnOffWifi() async {
    await _method.invokeMethod<void>('turnOffWifi');
  }

  Future<String?> downloadFile(String fileName, {int fileSize = 0}) async {
    final res = await _method.invokeMapMethod<String, dynamic>(
      'downloadFile', {'fileName': fileName, 'fileSize': fileSize},
    );
    return res?['path']?.toString();
  }

  Future<bool> isConnected() async {
    return await _method.invokeMethod<bool>('isConnected') ?? false;
  }

  Future<void> release() async {
    await _method.invokeMethod<void>('release');
  }
}
