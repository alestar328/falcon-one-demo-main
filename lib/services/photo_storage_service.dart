import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the app's own dedicated photo folder (incident photos taken from the
/// phone camera or captured from the bodycam livestream). Durable across app
/// launches and fully app-managed — no system-gallery permissions needed, and
/// the app can list/delete its files freely.
class PhotoStorageService {
  static const String _folderName = 'incident_photos';

  Directory? _cachedDir;

  Future<Directory> _dir() async {
    if (_cachedDir != null) return _cachedDir!;
    // External app-specific dir when available (more room for media); falls back
    // to the documents dir. Both persist until the app is uninstalled.
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_folderName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cachedDir = dir;
    return dir;
  }

  /// A fresh, timestamped destination path for a new capture.
  Future<String> newPhotoPath() async {
    final dir = await _dir();
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${dir.path}/photo_$ts.jpg';
  }

  /// All stored photos, newest first.
  Future<List<File>> listPhotos() async {
    final dir = await _dir();
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (e) {
      debugPrint('PhotoStorageService.listPhotos error: $e');
      return <File>[];
    }
  }

  Future<void> deletePhoto(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('PhotoStorageService.deletePhoto error: $e');
    }
  }
}
