# Android APK export — later project stage

APK export was intentionally not run for this delivery. The project must first be opened and tested with Godot **4.7.2 Stable** and the matching export templates.

When the build reaches its export milestone:

1. Open this project in Godot 4.7.2 and confirm `scenes/main.tscn` runs without script errors.
2. Install the same-version export templates from Godot's editor. Install/configure Android SDK, platform-tools, build-tools, and Java per the official Godot Android export documentation.
3. In **Project → Export**, add an Android preset. Use an application ID that you control, choose the required ABI(s), and select a debug APK for the first device test. `project.godot` already sets `display/window/handheld/orientation=0`, which Godot defines as `SCREEN_LANDSCAPE`; confirm the exported APK launches in landscape on the test device.
4. Export the APK, install it on a test device, and verify touch controls, persistence, memory/performance, world mesh collision, and application suspend/resume.
5. Only after those tests should a release/signing configuration and GitHub Actions build be added.

Official references:
- Godot Android export: https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html
- Godot 4.7.2 stable release/archive: https://godotengine.org/download/archive/4.7.2-stable/

The Android export setup is not bundled with fake SDK paths or a fabricated APK. The project has not yet been exported or device-tested.
