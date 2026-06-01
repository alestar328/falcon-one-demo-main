/// LiveKit connection settings for the camera / livestream screen.
///
/// Scoped to that screen only — Agora still powers the bodycam video, audio and
/// GPS data stream. Both values are injected at build/run time, e.g.:
///
///   flutter run \
///     --dart-define=LIVEKIT_URL=wss://your-project.livekit.cloud \
///     --dart-define=LIVEKIT_TOKEN=your-access-token
///
/// For a quick test you can paste a temporary access token generated from the
/// LiveKit Cloud dashboard (Settings → Keys → "Generate token") or the LiveKit
/// CLI (`lk token create --room falcon-cam --identity phone --valid-for 24h`).
class LiveKitConfig {
  const LiveKitConfig._();

  static const String url =
      String.fromEnvironment('LIVEKIT_URL', defaultValue: '');

  static const String token =
      String.fromEnvironment('LIVEKIT_TOKEN', defaultValue: '');

  /// Optional default room name (informational; the room a token grants access
  /// to is baked into the token itself).
  static const String roomName =
      String.fromEnvironment('LIVEKIT_ROOM', defaultValue: 'falcon-cam');

  static bool get isConfigured => url.isNotEmpty && token.isNotEmpty;
}
