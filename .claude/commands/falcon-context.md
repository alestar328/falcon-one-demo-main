# Falcon One Demo — Project Context

You are working on **Falcon One Demo**, a Flutter + Kotlin Android app for law enforcement.

## Architecture

**Two physical devices:**
- **Bodycam W1** (YIMAO, Android 9, UNISOC SL8541E) — runs `BodyCamServer` APK
- **Officer's phone** — runs this Flutter app (`Falcon-One-Demo`). Phone is a **controller/monitor only** — it does not contribute audio or video to any stream.

**Communication paths:**
- Phone ↔ Bodycam: **Bluetooth RFCOMM** (Classic BT, custom UUID `FA1C0000-1337-4242-CAFE-DEADBEEF0001`)
- Phone ↔ BleequP Glasses: **BLE GATT** via `bleequplibrary-release.aar` SDK
- Livestream: Bodycam → Agora (UID 9001, broadcaster). Phone → Agora (subscriber/receive-only, never publishes audio or video)
- Video download from glasses: WiFi AP on glasses → HTTP via `BleeqUpWifiManager`

## Key files

### Android (Kotlin)
- `BluetoothSppController.kt` — RFCOMM BT to bodycam
- `GlassesChannel.kt` — BleequP SDK bridge (MethodChannel `com.falconone/glasses` + EventChannel)
- `MainActivity.kt` — registers both channels

### Flutter (Dart)
- `lib/main.dart` — startup: Mapbox token, W1Service, UploadService. **Agora is NOT started here.**
- `lib/services/agora_launcher.dart` — `ensureAgoraStarted()`: on-demand Agora init, idempotent
- `lib/data/call_service.dart` — Agora engine wrapper. Phone joins **receive-only** (`muteLocalAudioStream(true)`, `publishMicrophoneTrack: false`). Mic button controls `muteAllRemoteAudioStreams`.
- `lib/controllers/map_controller.dart` — main controller. Agora starts only on **livestream button** press. Implements `WidgetsBindingObserver` to shutdown Agora on app pause/detach.
- `lib/controllers/glasses_controller.dart` — scan → connect → record → download pipeline
- `lib/services/glasses_service.dart` — GetxService wrapping GlassesChannel
- `lib/views/map/map.dart` — main screen: Mapbox 3D map + 2 rows of 3 buttons each

## BT Bodycam protocol (text, newline-delimited)
PING→PONG, REC_START, REC_STOP, STATUS (JSON), IR_ON/OFF, LED:N, GPS_ON/OFF

## Agora
- App ID: `ff51540c357447f7bf060b3150bf6a3e`
- Channel: `falcon_group_channel`
- Bodycam UID: `9001` (broadcaster, publishes audio+video)
- Phone UID: random (receive-only, never publishes)
- Token server: `https://agora-token-service-production-ba0dd.up.railway.app`

## Mapbox
- Token: hardcoded in `lib/main.dart` + `assets/mapbox.env` (same value, correct one ends in `c2FtMmxz`)
- Style: `mapbox://styles/fiddlie-ed/cmc9h7ar2035801sm6361cdtc`

## BleequP Glasses
- Device: `BleeqUp-Ranger-901FC` — MAC `F0:74:E4:79:7C:B1`
- AAR: `android/app/libs/bleequplibrary-release.aar`
- `BleeqUpDevice` constructor is `internal` (Kotlin) → bypass via reflection in `deviceFromBondedAddress()`
- SDK must be initialized with `BleeqUpSDK.init()` BEFORE any other SDK class is accessed
- Glasses must be power-cycled before connecting (BLE devices don't advertise when already bonded)

## Active branch
`merge/alejandro-w1-integration`

## Critical rules
- Phone **never** publishes audio or video to Agora
- Agora only connects when user presses the **livestream button**
- BT bodycam connects when user presses the **camera button**
- Agora shuts down completely (foreground service included) when livestream stops or app goes to background
