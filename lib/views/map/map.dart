import 'package:falcon_one_demo/components/panel_button.dart';
import 'package:falcon_one_demo/controllers/glasses_controller.dart';
import 'package:falcon_one_demo/controllers/map_controller.dart';
import 'package:falcon_one_demo/views/camera/camera_livestream_view.dart';
import 'package:falcon_one_demo/views/emergency/sos_notifications_sheet.dart';
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
        _buildTopRightControls(),
        _buildMyLocationButton(),
        _buildButtonPanel(),
        _buildCameraSwipeHandle(),
      ]),
    );
  }

  /// Top-right cluster: the SOS notification bell (with an unread count badge).
  Widget _buildTopRightControls() {
    return Positioned(
      top: 0,
      right: 12,
      child: SafeArea(
        child: Obx(() {
          final count = controller.sosNotifications.length;
          return GestureDetector(
            onTap: () => showSosNotificationsSheet(controller),
            child: Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    count > 0
                        ? Icons.notifications_active
                        : Icons.notifications_none,
                    color: count > 0 ? const Color(0xFFFFC107) : Colors.white,
                    size: 24,
                  ),
                  if (count > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        constraints:
                            const BoxConstraints(minWidth: 16, minHeight: 16),
                        decoration: const BoxDecoration(
                          color: Color(0xFFE53935),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          count > 99 ? '99+' : '$count',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  /// "My location" button — recenters the map on the user's own GPS, like
  /// Google Maps. Sits just above the control panel on the right.
  Widget _buildMyLocationButton() {
    return Positioned(
      right: 20,
      bottom: 280,
      child: GestureDetector(
        onTap: () => controller.recenterOnSelf(),
        child: Container(
          width: 48,
          height: 48,
          decoration: const BoxDecoration(
            color: Colors.black54,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.my_location, color: Colors.white, size: 24),
        ),
      ),
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

  Widget _buildButtonPanel() {
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
            // ══ ButtonsPanel ══════════════════════════════════════════════
            // The 6-button control grid (2 rows × 3), left column of the panel:
            //   Row 1:  speaker  |  mic  |  bodycam
            //   Row 2:  photo    |  SOS  |  glasses
            // The SOS button (row 2, centre — directly below the mic) broadcasts
            // the emergency / recording-signal warning.
            Expanded(
              child: Obx(() {
                final state     = controller.bodyCamState.value;
                final recording = controller.isRecording.value;
                final connected = state == 'connected';

                // A bodycam counts as present if it's linked over Bluetooth OR
                // live in Agora. The speaker/mic panel controls act on the
                // bodycam's audio, so without one they have nothing to control:
                // they're disabled (greyed) and effectively off.
                final bodyCamPresent =
                    connected || controller.bodyCamLiveInAgora.value;

                final glassesConnected = glasses.isConnected.value;
                final glassesRecording = glasses.isRecording.value;
                final glassesScanning  = glasses.isScanning.value;

                return Column(
                  spacing: 8.0,
                  children: [
                    // ButtonsPanel · Row 1: speaker | mic | bodycam
                    Expanded(
                      child: Row(
                        spacing: 8.0,
                        children: [
                          // [1] Speaker route toggle — bodycam audio only.
                          // Disabled (greyed) when no bodycam is present.
                          Expanded(
                            child: Obx(() => PanelButton(
                              iconData: controller.isSpeakerMuted.value
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                              iconColor:
                                  bodyCamPresent ? null : Colors.white24,
                              onTap: bodyCamPresent
                                  ? () async => controller.toggleSpeakerMute()
                                  : null,
                            )),
                          ),
                          // [2] Bodycam audio listen toggle (mute/unmute the
                          // bodycam's voice). Muted by default; disabled when no
                          // bodycam is present.
                          Expanded(
                            child: Obx(() => PanelButton(
                              iconData: controller.isMicrophoneMuted.value
                                  ? Icons.mic_off
                                  : Icons.mic,
                              iconColor:
                                  bodyCamPresent ? null : Colors.white24,
                              onTap: bodyCamPresent
                                  ? () async => controller.toggleMicrophoneMute()
                                  : null,
                            )),
                          ),
                          // [3] Bodycam Bluetooth CONNECT/DISCONNECT toggle.
                          // This button only manages the BT link; livestream
                          // (emergency) and normal recording are driven by the
                          // bodycam's own physical buttons. Icon shows the link
                          // state (red record dot while it's recording).
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
                              onTap: controller.toggleBodyCamConnection,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // ButtonsPanel · Row 2: photo | SOS | glasses
                    Expanded(
                      child: Row(
                        spacing: 8.0,
                        children: [
                          // [4] Take photo — opens the photo-capture screen.
                          // Always enabled. If the bodycam is live, a chooser
                          // asks bodycam vs phone; otherwise it's the phone cam.
                          Expanded(
                            child: PanelButton(
                              iconData: Icons.camera_alt,
                              iconColor: Colors.white,
                              onTap: () async => controller.openPhotoCapture(),
                            ),
                          ),
                          // [5] SOS — directly below the mic. Broadcasts an
                          // emergency / recording-signal warning to every other
                          // device in the channel and starts publishing this
                          // phone's camera. Tap again to cancel (red while a
                          // broadcast is active). Was the old livestream/stream
                          // toggle, now repurposed as the SOS button.
                          Expanded(
                            child: Obx(() {
                              final active =
                                  controller.emergencyBroadcastActive.value;
                              return PanelButton(
                                iconData: Icons.sos,
                                iconColor:
                                    active ? Colors.red : Colors.white,
                                onTap: () async =>
                                    controller.triggerEmergencyBroadcast(),
                              );
                            }),
                          ),
                          // [6] Glasses connect / scan / record.
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
            ),
            // ── Right column: status info + glasses banner ────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 10.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                            connected ? 'Bodycam' : 'No bodycam',
                            style: TextStyle(
                              color: connected
                                  ? Colors.greenAccent
                                  : Colors.white38,
                            ),
                          ),
                        ],
                      );
                    }),
                    // DIAGNOSTIC (2026-06-02): last GPS-looking line received
                    // from the bodycam over BT. Stays hidden until/unless the
                    // bodycam actually emits something. Temporary — remove with
                    // the GPS diagnostic in MapController._onBodyCamData.
                    Obx(() {
                      final raw = controller.bodyCamGpsRaw.value;
                      if (raw.isEmpty) return const SizedBox.shrink();
                      return Row(
                        spacing: 10.0,
                        children: [
                          const Icon(Icons.my_location,
                              size: 16, color: Colors.amber),
                          Expanded(
                            child: Text(
                              raw,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.amber, fontSize: 10),
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
