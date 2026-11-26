# Nexus-Player

Premium Android local music player built with Flutter and Rust.

**Status: Early Alpha - v0.1.0-alpha.1**

## Implemented
- Flutter application and premium interface.
- Android local audio discovery through MediaStore.
- Rust workspace and Flutter Rust Bridge 2.13.
- Playback queue and state logic in Rust.
- Android ARM64 native library packaging.
- Launcher icon and Nexus-Player branding.
- Successful installation and launch on a physical Redmi 12.

## In development
- MPV runtime initialization and actual audio playback.
- Android content URI integration.
- MediaSession and lock-screen controls.
- Foreground playback service.
- Audio focus and Bluetooth controls.
- Persistent library and playback state.

**Important:** MPV is packaged but real audio playback is not connected yet. This is an early development build, not a production-ready music player.

## Architecture

| Component | Technology |
|---|---|
| UI | Flutter / Dart |
| Bridge | Flutter Rust Bridge 2.13 |
| Core | Rust |
| Audio engine | MPV / libmpv |
| Android integration | Kotlin |
| Database | SQLite (planned) |

### Rust workspace
- `nexus_types`: shared data types.
- `nexus_core`: queue and playback logic.
- `nexus_audio`: audio engine.
- `nexus_bridge`: Dart/Rust interface.

## Build

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```

## Compatibility
Android ARM64 (`arm64-v8a`).

## Releases
Download the APK from the GitHub Releases page.

## License
No license has been assigned yet. All rights reserved.