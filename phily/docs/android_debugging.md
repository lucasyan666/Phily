# Android Debugging Quickstart

## Prerequisites
- Flutter SDK ([install guide](https://docs.flutter.dev/get-started/install))
- Android Studio with Flutter & Dart plugins
- Android SDK (set up via Android Studio SDK Manager)
- An Android device with USB debugging enabled

## Project setup

### 1. Open the Flutter project
Open the `phily/` directory in Android Studio:
```
File > Open > path/to/phily
```

### 2. Configure Dart SDK
If Android Studio prompts you, point the Dart SDK to the one bundled with Flutter:
- **Settings** > **Languages & Frameworks** > **Dart**
- Set **Dart SDK path** to:
  ```
  $HOME/<flutter-sdk>/bin/cache/dart-sdk
  ```
- Enable **Dart support for the project**

### 3. Install dependencies
```bash
cd path/to/phily
flutter pub get
```

### 4. Connect your Android device
- **Enable Developer Options**: Settings > About phone > tap **Build number** 7×
- **Enable USB Debugging**: Settings > Developer options > USB debugging
- When prompted on the device, select **File Transfer / MTP**
- Verify with:
  ```bash
  flutter devices
  ```
  Your device should appear in the list.

### 5. Run or Debug
- In Android Studio, the default **Flutter** run configuration targets `lib/main.dart`
- Select your device from the dropdown
- Click **Run** (▶) or **Debug** (🐛)

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Device not detected | Install USB drivers for your device model, try a different cable, re-plug |
| `flutter: command not found` | Add Flutter to your `PATH` or use the full path |
| Dart SDK not configured | Follow step 2 above |
| Build fails — license not accepted | Run `flutter doctor --android-licenses` |
| Build fails — Gradle sync error | Run `flutter clean` then `flutter pub get` |
