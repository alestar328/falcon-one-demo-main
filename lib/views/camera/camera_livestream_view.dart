import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

/// Full-screen camera view.
///
/// Reached by swiping right-to-left from the main map ([MapView]). For now it
/// just opens the conventional device camera and shows a livestream icon; the
/// actual livestream transport (LiveKit) is wired but left disabled until we
/// have server credentials.
class CameraLivestreamView extends StatefulWidget {
  const CameraLivestreamView({super.key});

  @override
  State<CameraLivestreamView> createState() => _CameraLivestreamViewState();
}

enum _CamState { initializing, ready, error, noPermission }

class _CameraLivestreamViewState extends State<CameraLivestreamView> {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  _CamState _state = _CamState.initializing;
  String _detail = '';

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _state = _CamState.noPermission;
        _detail = 'Permiso de cámara denegado';
      });
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _state = _CamState.error;
          _detail = 'No se encontró ninguna cámara';
        });
        return;
      }
      // Prefer the back camera.
      _cameraIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _startController(_cameras[_cameraIndex]);
    } catch (e) {
      setState(() {
        _state = _CamState.error;
        _detail = e.toString();
      });
    }
  }

  Future<void> _startController(CameraDescription camera) async {
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
    );
    _controller = controller;
    await controller.initialize();
    if (!mounted) return;
    setState(() => _state = _CamState.ready);
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    final old = _controller;
    _controller = null;
    setState(() => _state = _CamState.initializing);
    await old?.dispose();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    try {
      await _startController(_cameras[_cameraIndex]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _CamState.error;
        _detail = e.toString();
      });
    }
  }

  void _onLivestreamTap() {
    Get.snackbar(
      'Livestream',
      'Transmisión en vivo: próximamente',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.black87,
      colorText: Colors.white,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 96),
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // Swipe left-to-right anywhere to return to the map.
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v > 250) Get.back();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildCameraArea(),
            _buildTopBar(),
            _buildBackHint(),
            if (_state == _CamState.ready) _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraArea() {
    switch (_state) {
      case _CamState.initializing:
        return _centerInfo(
          const CircularProgressIndicator(color: Colors.white54),
          'Abriendo cámara…',
        );
      case _CamState.noPermission:
        return _centerInfo(
          const Icon(Icons.no_photography, color: Colors.white38, size: 40),
          _detail,
        );
      case _CamState.error:
        return _centerInfo(
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
          'Error de cámara\n$_detail',
        );
      case _CamState.ready:
        return _buildPreview();
    }
  }

  /// Fills the screen with the camera preview, cropping to cover.
  Widget _buildPreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final size = MediaQuery.of(context).size;
    final preview = controller.value.previewSize;
    // previewSize is reported in sensor (landscape) orientation, so swap.
    final pw = preview?.height ?? size.width;
    final ph = preview?.width ?? size.height;
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: pw,
            height: ph,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
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
              tooltip: 'Volver al mapa',
            ),
            const Spacer(),
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
        minimum: const EdgeInsets.only(bottom: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Livestream icon (transport not wired yet).
            _circleButton(
              icon: Icons.sensors,
              color: Colors.white,
              size: 64,
              iconSize: 30,
              onTap: _onLivestreamTap,
            ),
            if (_cameras.length > 1) ...[
              const SizedBox(width: 28),
              _circleButton(
                icon: Icons.cameraswitch,
                color: Colors.white,
                size: 52,
                iconSize: 24,
                onTap: _flipCamera,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    required Color color,
    required double size,
    required double iconSize,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Colors.black45,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: iconSize),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// Left-edge hint reinforcing the swipe-back affordance.
  Widget _buildBackHint() {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          width: 26,
          height: 64,
          decoration: const BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.only(
              topRight: Radius.circular(12),
              bottomRight: Radius.circular(12),
            ),
          ),
          child: const Icon(Icons.chevron_left, color: Colors.white70, size: 20),
        ),
      ),
    );
  }
}
