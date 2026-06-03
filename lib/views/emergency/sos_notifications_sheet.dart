import 'package:falcon_one_demo/controllers/map_controller.dart';
import 'package:falcon_one_demo/models/sos_notification.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Bottom sheet listing every SOS this device has received (newest first). Each
/// alert shows the emitting officer, GPS coordinates and date/time, and can be
/// Accepted or Closed (both just dismiss it for now).
void showSosNotificationsSheet(MapController controller) {
  Get.bottomSheet(
    Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.sos, color: Color(0xFFE53935)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'SOS alerts',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                ),
                Obx(() => controller.sosNotifications.isEmpty
                    ? const SizedBox.shrink()
                    : TextButton(
                        onPressed: controller.clearSosNotifications,
                        child: const Text('Clear all',
                            style: TextStyle(color: Colors.white54)),
                      )),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: Obx(() {
                final items = controller.sosNotifications;
                if (items.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'No SOS alerts.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38),
                    ),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: Colors.white12, height: 1),
                  itemBuilder: (_, i) =>
                      _SosTile(controller: controller, item: items[i]),
                );
              }),
            ),
          ],
        ),
      ),
    ),
    isScrollControlled: true,
  );
}

class _SosTile extends StatelessWidget {
  const _SosTile({required this.controller, required this.item});

  final MapController controller;
  final SosNotification item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Color(0xFFFFC107), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${item.displayOfficer} — Emergency',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _row(Icons.schedule, item.timeLabel),
          const SizedBox(height: 2),
          _row(Icons.place, item.coordsLabel),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => controller.dismissSosNotification(item),
                child: const Text('Close',
                    style: TextStyle(color: Colors.white54)),
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => controller.dismissSosNotification(item),
                child: const Text('Accept'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: Colors.white38, size: 15),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ),
      ],
    );
  }
}
