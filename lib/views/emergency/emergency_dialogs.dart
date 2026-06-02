import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// How the receiving agent chooses to treat an incoming recording/emergency
/// signal. With a single physical bodycam, this chooser is the demo mechanism
/// to present the same real signal as either "our own" or "someone else's".
enum EmergencyTreatment { own, external }

/// Drives the full incoming-signal flow:
///   1. "Tratar como: Propio / Externo" chooser.
///   2a. Propio  → open the livestream straight away (no alarm).
///   2b. Externo → warning popup with siren + "Recibir livestream" button.
///
/// [agentLabel] is the source shown on the external path (e.g. "Agente off-001"
/// from the broadcaster payload, or the simulated "Agente 007"). [onOpenLivestream]
/// opens the swipe livestream screen.
Future<void> showEmergencyTreatmentFlow({
  required String agentLabel,
  required Future<void> Function() onOpenLivestream,
}) async {
  final treatment = await Get.dialog<EmergencyTreatment>(
    const _TreatAsDialog(),
    barrierDismissible: false,
  );

  if (treatment == EmergencyTreatment.own) {
    await onOpenLivestream();
  } else if (treatment == EmergencyTreatment.external) {
    await Get.dialog<void>(
      _ExternalEmergencyDialog(
        agentLabel: agentLabel,
        onReceiveLivestream: onOpenLivestream,
      ),
      barrierDismissible: false,
    );
  }
}

/// "Tratar como:" — Externo (yellow) / Propio (blue).
class _TreatAsDialog extends StatelessWidget {
  const _TreatAsDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text(
        'Tratar como:',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
      content: const Text(
        'Señal de grabación recibida.',
        style: TextStyle(color: Colors.white70),
      ),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        _choiceButton(
          label: 'Externo',
          color: const Color(0xFFFFC107), // amarillo
          textColor: Colors.black,
          onTap: () => Get.back<EmergencyTreatment>(
            result: EmergencyTreatment.external,
          ),
        ),
        _choiceButton(
          label: 'Propio',
          color: const Color(0xFF1565C0), // azul
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
/// [initState], stopped in [dispose]) and offers "Recibir livestream".
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
            'Emergencia',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
        ],
      ),
      content: Text(
        '${widget.agentLabel} - estado: Emergencia',
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
            'Descartar',
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
            'Recibir livestream',
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
