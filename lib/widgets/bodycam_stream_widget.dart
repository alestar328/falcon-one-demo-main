import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:falcon_one_demo/data/call_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Displays the live video stream from the bodycam (Agora UID 9001).
///
/// Shows a black placeholder with status text when no stream is active.
/// Automatically reacts to [CallService.bodyCamVideoUidRx] changes.
class BodyCamStreamWidget extends StatelessWidget {
  const BodyCamStreamWidget({super.key, this.borderRadius = 12.0});

  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final callService = Get.isRegistered<CallService>()
        ? Get.find<CallService>()
        : null;

    if (callService == null) {
      return _placeholder('Agora not initialized');
    }

    return Obx(() {
      final uid = callService.bodyCamVideoUidRx.value;
      if (uid == null) {
        return _placeholder('No video signal');
      }
      // Bodycam stream now arrives 90° to the RIGHT on both the phone and the
      // Agora console (same raw sensor orientation). Rotate the phone view 90°
      // to the LEFT to stand it upright. RotatedBox turns CLOCKWISE, so 90° CCW
      // (left) = quarterTurns: 3. If it ever comes out mirrored/over-rotated,
      // flip this to 1. (The Agora web console can't be rotated from here.)
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: RotatedBox(
          quarterTurns: 3,
          child: AgoraVideoView(
            controller: VideoViewController.remote(
              rtcEngine: callService.engine,
              canvas: VideoCanvas(uid: uid),
              connection: RtcConnection(channelId: callService.config.channelId),
              useFlutterTexture: true,
            ),
          ),
        ),
      );
    });
  }

  Widget _placeholder(String label) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, color: Colors.white38, size: 36),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
