import 'dart:async';
import 'package:flutter/services.dart';

const _method = MethodChannel('com.falconone/bodycam');
const _event  = EventChannel('com.falconone/bodycam_events');

enum BtState { disconnected, connecting, connected, error }

class BodyCamService {
  static final BodyCamService _instance = BodyCamService._();
  factory BodyCamService() => _instance;
  BodyCamService._();

  final _stateCtrl = StreamController<BtState>.broadcast();
  final _dataCtrl  = StreamController<String>.broadcast();

  Stream<BtState> get stateStream => _stateCtrl.stream;
  Stream<String>  get dataStream  => _dataCtrl.stream;

  BtState _currentState = BtState.disconnected;
  BtState get state => _currentState;

  StreamSubscription? _eventSub;

  void init() {
    _eventSub = _event.receiveBroadcastStream().listen((event) {
      final map = Map<String, dynamic>.from(event as Map);
      switch (map['type']) {
        case 'bt_state':
          final s = _parseState(map['state'] as String);
          _currentState = s;
          _stateCtrl.add(s);
        case 'bt_data':
          _dataCtrl.add(map['data'] as String);
      }
    });
  }

  Future<void> connect({String? mac}) async {
    await _method.invokeMethod('connect', mac != null ? {'mac': mac} : null);
  }

  Future<void> disconnect() async {
    await _method.invokeMethod('disconnect');
  }

  Future<bool> isConnected() async {
    return await _method.invokeMethod<bool>('isConnected') ?? false;
  }

  Future<bool> startRecording() async {
    return await _method.invokeMethod<bool>('startRecording') ?? false;
  }

  Future<bool> stopRecording() async {
    return await _method.invokeMethod<bool>('stopRecording') ?? false;
  }

  Future<bool> takePhoto() async {
    return await _method.invokeMethod<bool>('takePhoto') ?? false;
  }

  Future<bool> sendRaw(String data) async {
    return await _method.invokeMethod<bool>('sendRaw', {'data': data}) ?? false;
  }

  Future<Map<String, dynamic>> getBodycamInfo() async {
    final result = await _method.invokeMapMethod<String, dynamic>('getBodycamInfo');
    return result ?? {};
  }

  Future<void> setWifiAlwaysOn() async {
    await _method.invokeMethod('setWifiAlwaysOn');
  }

  void dispose() {
    _eventSub?.cancel();
    _stateCtrl.close();
    _dataCtrl.close();
  }

  BtState _parseState(String s) => switch (s) {
    'CONNECTED'    => BtState.connected,
    'CONNECTING'   => BtState.connecting,
    'DISCONNECTED' => BtState.disconnected,
    _              => BtState.error,
  };
}
