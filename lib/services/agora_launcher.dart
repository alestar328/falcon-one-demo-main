import 'dart:convert';
import 'dart:math';

import 'package:falcon_one_demo/data/call_service.dart';
import 'package:falcon_one_demo/utils/call_foreground_task.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

const String agoraAppId = String.fromEnvironment(
  'AGORA_APP_ID',
  defaultValue: 'ff51540c357447f7bf060b3150bf6a3e',
);
const String agoraChannelId = String.fromEnvironment(
  'AGORA_CHANNEL',
  defaultValue: 'falcon_group_channel',
);
const String agoraTokenServer = String.fromEnvironment(
  'AGORA_TOKEN_SERVER',
  defaultValue: 'https://agora-token-service-production-ba0dd.up.railway.app',
);

/// Connects to Agora on demand (mic permission + channel join).
/// Safe to call multiple times — no-ops if already connected.
Future<bool> ensureAgoraStarted() async {
  if (Get.isRegistered<CallService>()) return true;

  final micStatus = await Permission.microphone.request();
  if (!micStatus.isGranted) {
    debugPrint('ensureAgoraStarted: mic permission denied');
    return false;
  }

  await CallForegroundTaskManager.ensureNotificationPermissions();

  if (agoraAppId.isEmpty) return false;

  final localUid = Random().nextInt(0x7FFFFFFF);
  final token = await _fetchAgoraToken(
    baseUrl: agoraTokenServer,
    channelId: agoraChannelId,
    uid: localUid,
  );

  final config = AgoraCallConfig(
    appId: agoraAppId,
    channelId: agoraChannelId,
    token: token,
    localUid: localUid,
  );

  try {
    await Get.putAsync<CallService>(
      () async => CallService(config: config).init(),
      permanent: true,
    );
    return true;
  } catch (e, st) {
    debugPrint('ensureAgoraStarted failed: $e\n$st');
    return false;
  }
}

Future<String?> _fetchAgoraToken({
  required String baseUrl,
  required String channelId,
  required int uid,
}) async {
  try {
    final uri = Uri.parse(baseUrl).resolve('getToken');
    final response = await http.post(
      uri,
      headers: const {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'tokenType': 'rtc',
        'channel': channelId,
        'role': 'publisher',
        'uid': uid.toString(),
      }),
    );
    if (response.statusCode != 200) return null;
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final t = payload['rtcToken'] as String? ?? payload['token'] as String?;
    return (t != null && t.isNotEmpty) ? t : null;
  } catch (e) {
    debugPrint('_fetchAgoraToken: $e');
    return null;
  }
}
