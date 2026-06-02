import 'package:falcon_one_demo/app.dart';
import 'package:falcon_one_demo/mapbox_config.dart';
import 'package:falcon_one_demo/services/photo_storage_service.dart';
import 'package:falcon_one_demo/services/upload_service.dart';
import 'package:falcon_one_demo/services/w1_service.dart';
import 'package:falcon_one_demo/utils/call_foreground_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:get/get.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();

  try {
    await dotenv.load(fileName: 'assets/mapbox.env');
  } catch (e, st) {
    debugPrint('Could not load assets/mapbox.env ($e). Using dart-define only.');
    debugPrint('$st');
  }

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await CallForegroundTaskManager.ensureInitialized();

  await initializeServices();

  runApp(WithForegroundTask(child: const FalconOneDemoApp()));
}

Future<void> initializeServices() async {
  // Mapbox token: dart-define wins; falls back to assets/mapbox.env; then hardcoded key.
  const fromDefine = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  final fromFile = dotenv.env['MAPBOX_ACCESS_TOKEN']?.trim() ?? '';
  const hardcoded = 'pk.eyJ1IjoiZmlkZGxpZS1lZCIsImEiOiJjbWM5Z3NqcXkxc2FtMmxzYTBzOWdnMWN5In0.mMlisxM4Qz8CgLANWs7R4w';
  final token = fromDefine.isNotEmpty ? fromDefine : (fromFile.isNotEmpty ? fromFile : hardcoded);

  mapboxAccessTokenConfigured = token.isNotEmpty;
  MapboxOptions.setAccessToken(token);

  Get.put(W1Service(), permanent: true);
  Get.put(UploadService(), permanent: true);
  Get.put(PhotoStorageService(), permanent: true);

  await Permission.locationWhenInUse.request();
}

