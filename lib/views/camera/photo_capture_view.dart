import 'dart:io';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:falcon_one_demo/data/call_service.dart';
import 'package:falcon_one_demo/models/upload_result.dart';
import 'package:falcon_one_demo/services/photo_storage_service.dart';
import 'package:falcon_one_demo/services/upload_service.dart';
import 'package:falcon_one_demo/widgets/bodycam_stream_widget.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

/// Photo-source chooser shown when the bodycam is live and the user taps the
/// photo button. Returns true = bodycam, false = phone, null = cancelled.
Future<bool?> showPhotoSourceDialog() {
  return Get.dialog<bool>(
    AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text(
        'Take photo with',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
      content: const Text(
        'The bodycam is connected. Choose which camera to use.',
        style: TextStyle(color: Colors.white70),
      ),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.videocam),
          label: const Text('Bodycam'),
          onPressed: () => Get.back<bool>(result: true),
        ),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF424242),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.smartphone),
          label: const Text('Phone'),
          onPressed: () => Get.back<bool>(result: false),
        ),
      ],
    ),
    barrierDismissible: true,
  );
}

/// Full-screen photo-capture screen, styled like the livestream view but only
/// for taking photos. [sourceUid] picks the frame source:
///   • null / 0 → this phone's rear camera,
///   • 9001     → the bodycam livestream (frame grabbed on the phone).
/// Captured photos go to the app's dedicated folder; from here the user can
/// open the gallery to view, delete, or send a photo to the server.
class PhotoCaptureView extends StatefulWidget {
  const PhotoCaptureView({super.key, this.sourceUid});

  final int? sourceUid;

  @override
  State<PhotoCaptureView> createState() => _PhotoCaptureViewState();
}

enum _State { initializing, ready, error, noPermission, noAgora }

class _PhotoCaptureViewState extends State<PhotoCaptureView> {
  CallService? _call;
  final PhotoStorageService _store = Get.find<PhotoStorageService>();
  _State _state = _State.initializing;
  String _detail = '';
  File? _lastPhoto;
  bool _capturing = false;

  bool get _isBodycam => widget.sourceUid == CallService.bodyCamAgoraUid;
  int get _snapshotUid => _isBodycam ? CallService.bodyCamAgoraUid : 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    if (!_isBodycam) {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        setState(() {
          _state = _State.noPermission;
          _detail = 'Camera permission denied';
        });
        return;
      }
    }

    final call = Get.isRegistered<CallService>() ? Get.find<CallService>() : null;
    if (call == null || !call.isInitialized) {
      setState(() {
        _state = _State.noAgora;
        _detail = 'Agora connection unavailable';
      });
      return;
    }
    _call = call;

    if (_isBodycam) {
      await call.watchRemoteVideo(CallService.bodyCamAgoraUid);
    } else {
      // Preview the phone camera locally WITHOUT publishing it to the channel.
      await call.startLocalPreview();
    }

    await _refreshThumbnail();
    if (!mounted) return;
    setState(() => _state = _State.ready);
  }

  Future<void> _refreshThumbnail() async {
    final photos = await _store.listPhotos();
    if (!mounted) return;
    setState(() => _lastPhoto = photos.isNotEmpty ? photos.first : null);
  }

  @override
  void dispose() {
    if (!_isBodycam) _call?.stopLocalPreview();
    super.dispose();
  }

  Future<void> _capture() async {
    final call = _call;
    if (call == null || _capturing) return;
    setState(() => _capturing = true);
    final path = await _store.newPhotoPath();
    final saved = await call.takeSnapshot(uid: _snapshotUid, filePath: path);
    if (!mounted) return;
    setState(() => _capturing = false);
    if (saved != null) {
      await _refreshThumbnail();
      Get.snackbar(
        'Photo',
        'Captured',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: const Color(0xFF2E7D32),
        colorText: Colors.white,
        duration: const Duration(seconds: 1),
      );
    } else {
      Get.snackbar(
        'Photo',
        'Capture failed',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: const Color(0xFFB71C1C),
        colorText: Colors.white,
      );
    }
  }

  Future<void> _openGallery() async {
    await Get.to<void>(
      () => PhotoGalleryView(source: _isBodycam ? 'bodycam' : 'phone'),
      transition: Transition.cupertino,
    );
    await _refreshThumbnail();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 250) Get.back<void>();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildPreview(),
            _buildTopBar(),
            if (_state == _State.ready) _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    switch (_state) {
      case _State.initializing:
        return _centerInfo(
          const CircularProgressIndicator(color: Colors.white54),
          _isBodycam ? 'Connecting to bodycam…' : 'Opening camera…',
        );
      case _State.noPermission:
        return _centerInfo(
          const Icon(Icons.no_photography, color: Colors.white38, size: 40),
          _detail,
        );
      case _State.noAgora:
        return _centerInfo(
          const Icon(Icons.cloud_off, color: Colors.white38, size: 40),
          _detail,
        );
      case _State.error:
        return _centerInfo(
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
          _detail,
        );
      case _State.ready:
        if (_isBodycam) return const BodyCamStreamWidget(borderRadius: 0);
        return AgoraVideoView(
          controller: VideoViewController(
            rtcEngine: _call!.engine,
            canvas: const VideoCanvas(uid: 0),
            useFlutterTexture: true,
          ),
        );
    }
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
              tooltip: 'Back to map',
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _isBodycam ? 'PHOTO · BODYCAM' : 'PHOTO · PHONE',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        minimum: const EdgeInsets.only(bottom: 24, left: 24, right: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Gallery thumbnail (or placeholder).
            GestureDetector(
              onTap: _openGallery,
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white54),
                  image: _lastPhoto != null
                      ? DecorationImage(
                          image: FileImage(_lastPhoto!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: _lastPhoto == null
                    ? const Icon(Icons.photo_library, color: Colors.white70)
                    : null,
              ),
            ),
            // Shutter.
            GestureDetector(
              onTap: _capture,
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white24,
                  border: Border.all(color: Colors.white, width: 4),
                ),
                child: _capturing
                    ? const Padding(
                        padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 3,
                        ),
                      )
                    : const Icon(Icons.camera_alt,
                        color: Colors.white, size: 30),
              ),
            ),
            // Flip camera (phone only).
            Opacity(
              opacity: _isBodycam ? 0.0 : 1.0,
              child: IgnorePointer(
                ignoring: _isBodycam,
                child: GestureDetector(
                  onTap: () => _call?.switchCamera(),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Colors.black45,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.cameraswitch, color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
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
          Text(label, style: const TextStyle(color: Colors.white60)),
        ],
      ),
    );
  }
}

/// Grid of captured photos. Tap one to view it full-screen, where it can be
/// deleted or sent to the server.
class PhotoGalleryView extends StatefulWidget {
  const PhotoGalleryView({super.key, required this.source});

  /// 'phone' or 'bodycam' — recorded in the upload metadata.
  final String source;

  @override
  State<PhotoGalleryView> createState() => _PhotoGalleryViewState();
}

class _PhotoGalleryViewState extends State<PhotoGalleryView> {
  final PhotoStorageService _store = Get.find<PhotoStorageService>();
  List<File> _photos = <File>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final photos = await _store.listPhotos();
    if (!mounted) return;
    setState(() {
      _photos = photos;
      _loading = false;
    });
  }

  Future<void> _openPhoto(File file) async {
    await Get.to<void>(
      () => PhotoDetailView(file: file, source: widget.source),
      transition: Transition.fadeIn,
    );
    await _load(); // refresh after a possible delete
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Gallery'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white54))
          : _photos.isEmpty
              ? const Center(
                  child: Text('No photos yet',
                      style: TextStyle(color: Colors.white54)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemCount: _photos.length,
                  itemBuilder: (context, i) {
                    final file = _photos[i];
                    return GestureDetector(
                      onTap: () => _openPhoto(file),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(file, fit: BoxFit.cover),
                      ),
                    );
                  },
                ),
    );
  }
}

/// Full-screen single-photo view with delete + send actions.
class PhotoDetailView extends StatefulWidget {
  const PhotoDetailView({super.key, required this.file, required this.source});

  final File file;
  final String source;

  @override
  State<PhotoDetailView> createState() => _PhotoDetailViewState();
}

class _PhotoDetailViewState extends State<PhotoDetailView> {
  final PhotoStorageService _store = Get.find<PhotoStorageService>();
  final UploadService _upload = Get.find<UploadService>();
  bool _sending = false;

  Future<void> _delete() async {
    await _store.deletePhoto(widget.file);
    Get.back<void>();
    Get.snackbar(
      'Photo',
      'Deleted',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: const Color(0xFF424242),
      colorText: Colors.white,
      duration: const Duration(seconds: 1),
    );
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    final result = await _upload.uploadPhoto(widget.file, <String, dynamic>{
      'source': widget.source,
      'captured_at': DateTime.now().toIso8601String(),
    });
    if (!mounted) return;
    setState(() => _sending = false);
    final UploadResult r = result;
    Get.snackbar(
      'Upload',
      r.isSuccess ? 'Sent (${r.status})' : 'Failed: ${r.errorMessage}',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor:
          r.isSuccess ? const Color(0xFF2E7D32) : const Color(0xFFB71C1C),
      colorText: Colors.white,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(child: Image.file(widget.file, fit: BoxFit.contain)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                label: const Text('Delete',
                    style: TextStyle(color: Colors.redAccent)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  foregroundColor: Colors.white,
                ),
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload),
                label: Text(_sending ? 'Sending…' : 'Send to server'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
