# RustDesk Gubernia

## Build Commands

```bash
# Sciter (deprecated) - download sciter.dll first
cargo run

# Flutter (current)
cargo run --features flutter

# Windows release build
python build.py --flutter

# Full Flutter build with hardware codec
python build.py --flutter --hwcodec

# Portable Windows installer
python build.py --flutter --portable
```

## Dependencies

- **vcpkg** required: set `VCPKG_ROOT` env var
- Windows: `vcpkg install libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static`
- Linux/macOS: `vcpkg install libvpx libyuv opus aom`

## Project Structure

- `src/` - Rust backend (server, client, platform code)
- `flutter/` - Flutter UI (desktop/mobile/shared)
- `libs/hbb_common/` - Config, proto, networking, file transfer
- `libs/scrap/` - Screen capture (platform-specific)
- `libs/enigo/` - Keyboard/mouse input simulation
- `libs/clipboard/` - Clipboard (platform-specific)
- `libs/virtual_display/` - Virtual display driver (Windows)

## Rust Rules

- Avoid `unwrap()`/`expect()` in production code (tests excepted)
- Never create nested Tokio runtimes or call `block_on()` in async code
- Never hold locks across `.await`
- Use `spawn_blocking` for blocking work
- Prefer `Result` + `?` over `.unwrap()`
- Do not add dependencies without justification

## Flutter/Rust Bridge

- FFI bindings auto-generated to `flutter/lib/generated_bridge.dart`
- After modifying `src/flutter_ffi.rs`, regenerate with:
  ```bash
  cd flutter && flutter pub get && flutter_rust_bridge_codegen --rust-input ../src/flutter_ffi.rs --dart-output ./lib/generated_bridge.dart
  ```
- Post-codegen workaround required (sed replacement in generated_bridge.dart)

## Key Entry Points

- `src/main.rs` - Application entry
- `src/flutter.rs` - Flutter integration
- `src/flutter_ffi.rs` - FFI exports for Flutter
- `src/rendezvous_mediator.rs` - Server communication / NAT traversal
- `src/server.rs` - Audio/clipboard/input/video services
- `src/client.rs` - Peer connection handling

## Cargo Workspace

Members: `libs/scrap`, `libs/hbb_common`, `libs/enigo`, `libs/clipboard`, `libs/virtual_display`, `libs/portable`, `libs/remote_printer`