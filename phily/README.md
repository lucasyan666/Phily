# Phily

Brick by Brick.

A composition-aware camera for iOS. Phily overlays classic composition guides
(rule of thirds, golden ratio / spiral, harmonious triangles, a gravity-based
horizon, and more) and uses on-device detection (faces, pets, horizon) to nudge
your framing in real time — then keeps your shots in a fast, gesture-driven
gallery.

## Run

```sh
flutter pub get
flutter run
```

## Notes

- `camera_avfoundation` is vendored under `vendor/` with a finite-value guard for
  an `exposureDuration` crash; keep that patch when upgrading the camera plugins
  (see the note in `pubspec.yaml`).
