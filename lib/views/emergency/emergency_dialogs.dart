import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:get/get.dart';

/// How the receiving agent chooses to treat an incoming recording/emergency
/// signal. With a single physical bodycam, this chooser is the demo mechanism
/// to present the same real signal as either "our own" or "someone else's".
enum EmergencyTreatment { own, external }

/// Drives the full incoming-signal flow:
///   1. "Treat as: Own / External" chooser (dismissible — tap outside or the
///      "Ignore" button to close without acting).
///   2a. Own      → open the livestream straight away (no alarm).
///   2b. External → warning popup with siren + "Receive livestream" button.
///
/// When [directExternal] is true the chooser is skipped and the external
/// emergency popup (siren) is shown straight away — used for signals coming from
/// another phone, which are always external by definition. The chooser is only
/// used for the bodycam (the demo's own/external simulation).
///
/// [agentLabel] is the source shown on the external path (e.g. "Officer off-001"
/// from the broadcaster payload, or the simulated "Officer 007"). [onOpenLivestream]
/// opens the swipe livestream screen.
Future<void> showEmergencyTreatmentFlow({
  required String agentLabel,
  required Future<void> Function() onOpenLivestream,
  bool directExternal = false,
}) async {
  if (directExternal) {
    await _showExternalEmergency(agentLabel, onOpenLivestream);
    return;
  }

  final treatment = await Get.dialog<EmergencyTreatment>(
    const _TreatAsDialog(),
    barrierDismissible: true,
  );

  if (treatment == EmergencyTreatment.own) {
    await onOpenLivestream();
  } else if (treatment == EmergencyTreatment.external) {
    await _showExternalEmergency(agentLabel, onOpenLivestream);
  }
}

Future<void> _showExternalEmergency(
  String agentLabel,
  Future<void> Function() onOpenLivestream,
) {
  return Get.dialog<void>(
    _ExternalEmergencyDialog(
      agentLabel: agentLabel,
      onReceiveLivestream: onOpenLivestream,
    ),
    barrierDismissible: false,
  );
}

/// "Treat as:" — External (yellow) / Own (blue). Closable via the title "X",
/// the "Ignore" action, or tapping outside (barrierDismissible).
class _TreatAsDialog extends StatelessWidget {
  const _TreatAsDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 8, 0),
      title: Row(
        children: [
          const Expanded(
            child: Text(
              'Treat as:',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white54),
            tooltip: 'Close',
            onPressed: () => Get.back<EmergencyTreatment>(),
          ),
        ],
      ),
      content: const Text(
        'Recording signal received.',
        style: TextStyle(color: Colors.white70),
      ),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        _choiceButton(
          label: 'External',
          color: const Color(0xFFFFC107), // yellow
          textColor: Colors.black,
          onTap: () => Get.back<EmergencyTreatment>(
            result: EmergencyTreatment.external,
          ),
        ),
        _choiceButton(
          label: 'Own',
          color: const Color(0xFF1565C0), // blue
          textColor: Colors.white,
          onTap: () => Get.back<EmergencyTreatment>(
            result: EmergencyTreatment.own,
          ),
        ),
      ],
    );
  }

  Widget _choiceButton({
    required String label,
    required Color color,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: textColor,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onTap,
      child: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    );
  }
}

/// External-emergency warning. Plays a looping siren while visible (started in
/// [initState], stopped in [dispose]) and offers "Receive livestream".
class _ExternalEmergencyDialog extends StatefulWidget {
  const _ExternalEmergencyDialog({
    required this.agentLabel,
    required this.onReceiveLivestream,
  });

  final String agentLabel;
  final Future<void> Function() onReceiveLivestream;

  @override
  State<_ExternalEmergencyDialog> createState() =>
      _ExternalEmergencyDialogState();
}

class _ExternalEmergencyDialogState extends State<_ExternalEmergencyDialog> {
  final AudioPlayer _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _startSiren();
  }

  Future<void> _startSiren() async {
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(1.0);
      await _player.play(AssetSource('sounds/emergency.wav'));
    } catch (e) {
      debugPrint('Emergency siren failed: $e');
    }
  }

  @override
  void dispose() {
    // Fire-and-forget: stop and release the siren when the popup closes.
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2A0E0E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE53935), width: 1.5),
      ),
      title: Row(
        children: const [
          Icon(Icons.warning_amber_rounded, color: Color(0xFFFFC107), size: 28),
          SizedBox(width: 10),
          Text(
            'Emergency',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
        ],
      ),
      content: Text(
        '${widget.agentLabel} — status: Emergency',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () => Get.back<void>(),
          child: const Text(
            'Dismiss',
            style: TextStyle(color: Colors.white54),
          ),
        ),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFE53935),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          icon: const Icon(Icons.sensors),
          label: const Text(
            'Receive livestream',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          onPressed: () async {
            // Close the popup first (dispose stops the siren), then navigate.
            Get.back<void>();
            await widget.onReceiveLivestream();
          },
        ),
      ],
    );
  }
}

/// Notice shown to a receiver when the emitting agent cuts the alert/livestream.
/// Closable. Shows the cut time and the emitter's location, reverse-geocoded to
/// "City, Country" when possible (falling back to raw coordinates).
Future<void> showSignalCutDialog({
  required DateTime time,
  double? latitude,
  double? longitude,
}) {
  return Get.dialog<void>(
    _SignalCutDialog(time: time, latitude: latitude, longitude: longitude),
    barrierDismissible: true,
  );
}

class _SignalCutDialog extends StatefulWidget {
  const _SignalCutDialog({
    required this.time,
    this.latitude,
    this.longitude,
  });

  final DateTime time;
  final double? latitude;
  final double? longitude;

  @override
  State<_SignalCutDialog> createState() => _SignalCutDialogState();
}

class _SignalCutDialogState extends State<_SignalCutDialog> {
  String? _place;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _resolvePlace();
  }

  Future<void> _resolvePlace() async {
    final lat = widget.latitude;
    final lng = widget.longitude;
    if (lat == null || lng == null) return;
    setState(() => _resolving = true);
    String? place;
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        final city = (p.locality != null && p.locality!.isNotEmpty)
            ? p.locality
            : p.administrativeArea;
        final parts = <String>[
          if (city != null && city.isNotEmpty) city,
          if (p.country != null && p.country!.isNotEmpty) p.country!,
        ];
        if (parts.isNotEmpty) place = parts.join(', ');
      }
    } catch (e) {
      debugPrint('Reverse geocode failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _place = place;
      _resolving = false;
    });
  }

  String get _timeStr {
    String two(int n) => n.toString().padLeft(2, '0');
    final t = widget.time;
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String get _locationStr {
    final lat = widget.latitude;
    final lng = widget.longitude;
    if (lat == null || lng == null) return 'unknown';
    final coords =
        '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
    if (_resolving) return '$coords  (resolving…)';
    if (_place != null) return '$_place\n$coords';
    return coords;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 8, 0),
      title: Row(
        children: [
          const Icon(Icons.signal_cellular_off,
              color: Colors.white70, size: 24),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Signal cut',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white54),
            tooltip: 'Close',
            onPressed: () => Get.back<void>(),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Signal cut at $_timeStr',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Location: $_locationStr',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back<void>(),
          child: const Text('OK', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
