/// A received SOS/emergency alert kept in the notification centre. Built from an
/// incoming [EmergencySignal]; one entry per emergency session (deduped by the
/// signal's sessionKey). For now the user can only acknowledge ("Accept") or
/// dismiss ("Close") it.
class SosNotification {
  SosNotification({
    required this.sessionKey,
    required this.officer,
    required this.uid,
    required this.receivedAt,
    required this.emittedAt,
    this.latitude,
    this.longitude,
  });

  /// Stable id of the emergency session (uid + start time) — used to dedupe
  /// heartbeat repeats so the same SOS isn't listed twice.
  final String sessionKey;

  /// Officer code of the emitter (e.g. 'off-001').
  final String officer;

  /// Agora uid of the emitter (the source to watch).
  final int uid;

  /// When THIS device first received the alert.
  final DateTime receivedAt;

  /// When the emitter started the SOS (from the signal).
  final DateTime emittedAt;

  final double? latitude;
  final double? longitude;

  String get displayOfficer => officer.isNotEmpty ? 'Officer $officer' : 'Officer (unknown)';

  bool get hasLocation => latitude != null && longitude != null;

  String get coordsLabel => hasLocation
      ? '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}'
      : 'unknown';

  String get timeLabel {
    final t = emittedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
