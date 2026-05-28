import 'package:falcon_one_demo/controllers/glasses_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class GlassesStatusBanner extends GetView<GlassesController> {
  const GlassesStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final connected  = controller.isConnected.value;
      final recording  = controller.isRecording.value;
      final prep       = controller.isPreparingVideo.value;
      final dl         = controller.isDownloading.value;
      final failed     = controller.downloadFailed.value;
      final hasFile    = controller.lastVideoPath.value != null;

      final Color bg;
      final Color fg;
      if (failed) {
        bg = Colors.orange.withValues(alpha: 0.22);
        fg = Colors.orange.shade200;
      } else if (recording) {
        bg = Colors.red.withValues(alpha: 0.20);
        fg = Colors.red.shade200;
      } else if (prep) {
        bg = Colors.amber.withValues(alpha: 0.18);
        fg = Colors.amber.shade100;
      } else if (dl) {
        bg = Colors.indigo.withValues(alpha: 0.20);
        fg = Colors.indigo.shade100;
      } else if (hasFile) {
        bg = Colors.green.withValues(alpha: 0.20);
        fg = Colors.green.shade200;
      } else if (!connected) {
        bg = Colors.deepPurple.withValues(alpha: 0.20);
        fg = Colors.deepPurple.shade100;
      } else {
        bg = Colors.teal.withValues(alpha: 0.18);
        fg = Colors.teal.shade100;
      }

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.remove_red_eye, size: 12, color: fg),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    controller.statusMessage.value,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (dl)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(
                  value: controller.downloadProgress.value,
                  color: fg,
                  backgroundColor: fg.withValues(alpha: 0.2),
                  minHeight: 2,
                ),
              ),
            if (controller.canRetryDownload)
              GestureDetector(
                onTap: controller.retryLastDownload,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Tap to retry download',
                    style: TextStyle(
                      color: fg,
                      fontSize: 10,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}
