# Architecture

Flutter handles presentation and user interaction.

Flutter communicates with Rust through Flutter Rust Bridge. Rust owns playback state and will exclusively control MPV through its native C API.

Android Kotlin provides platform integration, including MediaStore.

## Rust crates
- nexus_types
- nexus_core
- nexus_audio
- nexus_bridge

## Current audio status
libmpv and its ARM64 dependencies are packaged in the Android application. Runtime initialization and actual playback integration remain incomplete.

## Next integration stages
1. Initialize MPV from Rust.
2. Connect Android content URIs through file descriptors.
3. Connect playback commands and events to Flutter.
4. Implement MediaSession, foreground service and audio focus.