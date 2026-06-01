import 'package:falcon_one_demo/components/panel_button.dart';
import 'package:falcon_one_demo/controllers/glasses_controller.dart';
import 'package:falcon_one_demo/controllers/map_controller.dart';
import 'package:falcon_one_demo/views/camera/camera_livestream_view.dart';
import 'package:falcon_one_demo/widgets/bodycam_stream_widget.dart';
import 'package:falcon_one_demo/widgets/glasses_status_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_liquid_glass/liquid_glass.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

final LiquidGlassConfig glassConfig = LiquidGlassConfig(
  border: Border.all(color: Colors.white12),
  baseColor: Colors.black,
  opacity: 0.4,
  enableSpecularHighlight: false,
  blurAmount: 15.0,
  borderRadius: BorderRadius.circular(30.0),
  frostIntensity: 0.1,
);

class MapView extends GetView<MapController> {
  const MapView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        _buildMap(),
        _buildStreamOverlay(),
        _buildButtonPanel(),
        _buildCameraSwipeHandle(),
      ]),
    );
  }

  void _openCamera() {
    Get.to(
      () => const CameraLivestreamView(),
      transition: Transition.rightToLeft,
      duration: const Duration(milliseconds: 280),
    );
  }

  /// Right-edge affordance: swipe right-to-left (or tap) to open the camera /
  /// livestream view. Lives on the screen edge so it never steals the map's
  /// own horizontal pan gestures.
  Widget _buildCameraSwipeHandle() {
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _openCamera,
          onHorizontalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (v < -250) _openCamera();
          },
          child: SafeArea(
            child: Container(
              width: 30,
              height: 72,
              decoration: const BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                ),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chevron_left, color: Colors.white70, size: 22),
                  Icon(Icons.videocam, color: Colors.white70, size: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMap() {
    return MapWidget(
      onMapCreated: controller.onMapCreated,
      onStyleLoadedListener: controller.onStyleLoaded,
      styleUri: "mapbox://styles/fiddlie-ed/cmc9h7ar2035801sm6361cdtc",
      cameraOptions: CameraOptions(
        zoom: 16.0,
        pitch: 60.0,
        center: Point(coordinates: Position(0.031085, 51.501435)),
        padding: MbxEdgeInsets(bottom: 200.0, top: 0.0, left: 0.0, right: 0.0),
      ),
    );
  }

  Widget _buildStreamOverlay() {
    return Obx(() {
      final streaming = controller.isStreaming.value;
      if (!streaming) return const SizedBox.shrink();
      return Positioned(
        top: 0,
        left: 20.0,
        right: 20.0,
        child: LiquidGlassContainer(
          config: glassConfig,
          child: SafeArea(
            minimum: const EdgeInsets.only(top: 10.0),
            child: SizedBox(
              height: 220,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const BodyCamStreamWidget(borderRadius: 20),
                  Positioned(
                    top: 8,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, color: Colors.white, size: 8),
                          SizedBox(width: 4),
                          Text('LIVE',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold)),
                          Text('LIVE',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildButtonPanel() {
    final glasses = Get.find<GlassesController>();

    final glasses = Get.find<GlassesController>();

    return Positioned(
      bottom: 20.0,
      left: 20.0,
      right: 20.0,
      child: LiquidGlassContainer(
        config: glassConfig,
        height: 250.0,
        padding: const EdgeInsets.all(15.0),
        child: Row(
          spacing: 10.0,
          children: [
            // ── Left column: audio+bodycam row / photo+stream+glasses row ──
            Expanded(
              child: Obx(() {
                final state     = controller.bodyCamState.value;
                final recording = controller.isRecording.value;
                final streaming = controller.isStreaming.value;
                final connected = state == 'connected';

                final glassesConnected = glasses.isConnected.value;
                final glassesRecording = glasses.isRecording.value;
                final glassesScanning  = glasses.isScanning.value;

                return Column(
                  spacing: 8.0,
                  children: [
                    // Row 1: speaker | mic | bodycam
                    Expanded(
                      child: Row(
                        spacing: 8.0,
            // ── Left column: audio+bodycam row / photo+stream+glasses row ──
            Expanded(
              child: Obx(() {
                final state     = controller.bodyCamState.value;
                final recording = controller.isRecording.value;
                final streaming = controller.isStreaming.value;
                final connected = state == 'connected';

                final glassesConnected = glasses.isConnected.value;
                final glassesRecording = glasses.isRecording.value;
                final glassesScanning  = glasses.isScanning.value;

                return Column(
                  spacing: 8.0,
                  children: [
                    // Row 1: speaker | mic | bodycam
                    Expanded(
                      child: Row(
                        spacing: 8.0,
                        children: [
                          Expanded(
                            child: Obx(() => PanelButton(
                              iconData: controller.isSpeakerMuted.value
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                              onTap: () async => controller.toggleSpeakerMute(),
                            )),
                          ),
                          Expanded(
                            child: Obx(() => PanelButton(
                              iconData: controller.isMicrophoneMuted.value
                                  ? Icons.mic_off
                                  : Icons.mic,
                              onTap: () async => controller.toggleMicrophoneMute(),
                            )),
                          ),
                          Expanded(
                            child: Obx(() => PanelButton(
                              iconData: controller.isSpeakerMuted.value
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                              onTap: () async => controller.toggleSpeakerMute(),
                            )),
                          ),
                          Expanded(
                            child: Obx(() => PanelButton(
                              iconData: controller.isMicrophoneMuted.value
                                  ? Icons.mic_off
                                  : Icons.mic,
                              onTap: () async => controller.toggleMicrophoneMute(),
                            )),
                          ),
                          Expanded(
                            child: PanelButton(
                              iconData: recording
                                  ? Icons.fiber_manual_record
                                  : connected
                                      ? Icons.videocam
                                      : state == 'connecting'
                                          ? Icons.sync
                                          : Icons.videocam_off,
                              iconColor: recording ? Colors.red : null,
                              onTap: controller.toggleBodyCam,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Row 2: photo | livestream | glasses
                    Expanded(
                      child: Row(
                        spacing: 8.0,
                        children: [
                        ],
                      ),
                    ),
                    // Row 2: photo | livestream | glasses
                    Expanded(
                      child: Row(
                        spacing: 8.0,
                        children: [
                          Expanded(
                            child: PanelButton(
                              iconData: Icons.camera_alt,
                              iconColor: connected ? Colors.white : Colors.white38,
                              onTap: connected ? controller.takePhoto : null,
                            ),
                          ),
                          Expanded(
                            child: PanelButton(
                              iconData: streaming
                                  ? Icons.sensors
                                  : Icons.sensors_off,
                              iconColor: streaming
                                  ? Colors.red
                                  : connected
                                      ? Colors.white
                                      : Colors.white38,
                              onTap: controller.toggleStream,
                            ),
                          ),
                          Expanded(
                            child: PanelButton(
                              iconData: glassesScanning
                                  ? Icons.search
                                  : FontAwesomeIcons.glasses,
                              iconColor: glassesRecording
                                  ? Colors.red
                                  : glassesConnected
                                      ? Colors.white
                                      : Colors.white38,
                              onTap: glasses.onGlassesButtonTapped,
                            ),
                          ),
                        ],
                      ),
                          Expanded(
                            child: PanelButton(
                              iconData: glassesScanning
                                  ? Icons.search
                                  : FontAwesomeIcons.glasses,
                              iconColor: glassesRecording
                                  ? Colors.red
                                  : glassesConnected
                                      ? Colors.white
                                      : Colors.white38,
                              onTap: glasses.onGlassesButtonTapped,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }),
                  ],
                );
              }),
            ),
            // ── Right column: status info + glasses banner ────────────────
            // ── Right column: status info + glasses banner ────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 10.0),
                padding: const EdgeInsets.only(left: 10.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8.0,
                  spacing: 8.0,
                  children: [
                    // Phone battery always; bodycam battery appended (with a
                    // camera icon) only when the bodycam is connected.
                    Obx(() {
                      final bodycamConnected =
                          controller.bodyCamState.value == 'connected' ||
                          controller.bodyCamLiveInAgora.value;
                      return Row(
                        spacing: 10.0,
                        children: [
                          const Icon(Icons.battery_3_bar),
                          Text("${controller.phoneBatteryLevel.value}%"),
                          if (bodycamConnected) ...[
                            const Icon(Icons.videocam, size: 18),
                            Text("${controller.batteryLevel.value}%"),
                          ],
                        ],
                      );
                    }),
                    Row(
                      spacing: 10.0,
                      children: [
                        const Icon(Icons.people),
                        Obx(() => Text(
                            controller.numUsers.value.toString())),
                      ],
                    ),
                    // Connection signal: reflects whether the phone is joined to
                    // the Agora channel (green) or not (grey).
                    Obx(() {
                      final connected = controller.agoraConnected.value;
                      return Row(
                        spacing: 10.0,
                        children: [
                          Icon(
                            connected
                                ? Icons.signal_wifi_4_bar
                                : Icons.signal_wifi_off,
                            color: connected
                                ? Colors.greenAccent
                                : Colors.white38,
                          ),
                          Text(
                            connected ? 'Online' : 'Sin red',
                            style: TextStyle(
                              color: connected
                                  ? Colors.greenAccent
                                  : Colors.white38,
                            ),
                          ),
                        ],
                      );
                    }),
                    Row(
                      spacing: 10.0,
                      children: [
                        const Icon(Icons.satellite_alt),
                        Obx(() => Text(
                            controller.numSatellites.value.toString())),
                      ],
                    ),
                    // Bodycam connection indicator. "Connected" means the bodycam
                    // is reachable: BT-linked OR live in the Agora channel (the
                    // latter is the reliable signal in the current setup).
                    Obx(() {
                      final connected =
                          controller.bodyCamState.value == 'connected' ||
                          controller.bodyCamLiveInAgora.value;
                      return Row(
                        spacing: 10.0,
                        children: [
                          Icon(
                            connected ? Icons.videocam : Icons.videocam_off,
                            color: connected
                                ? Colors.greenAccent
                                : Colors.white38,
                          ),
                          Text(
                            connected ? 'Bodycam' : 'Sin bodycam',
                            style: TextStyle(
                              color: connected
                                  ? Colors.greenAccent
                                  : Colors.white38,
                            ),
                          ),
                        ],
                      );
                    }),
                    const GlassesStatusBanner(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
