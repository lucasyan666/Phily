# Phily

A composition-aware iOS camera: live composition guides (rule of thirds, phi
grid, golden spiral, horizon level and more), face/pet detection that lights up
alignment targets, and an in-app gallery.

Flutter app; the project root is `phily/`, so run all Flutter commands there:

```
cd phily && flutter run          # debug, on a physical device
cd phily && flutter test         # unit + widget tests
cd phily && flutter analyze
```

## Platform support

**iOS only, in practice.** `android/`, `web/`, `windows/`, `linux/` and `macos/`
exist because `flutter create` made them — they are not tested and would not
currently work (see "Porting" below). Minimum deployment target is **iOS 15.5**.

**The iOS Simulator cannot run this app.** The ML Kit pods ship no arm64
simulator slices, so `flutter run` must target a physical device. `flutter build
ios --simulator` still compiles, which makes it useful as a build check.

## Things that will bite you

### The vendored camera plugin
`camera_avfoundation` is **vendored and patched** in `phily/vendor/`, wired up
through `dependency_overrides` in `pubspec.yaml`. The patch adds a finite-value
guard in `DefaultCamera.handleSampleBufferStreaming`: upstream casts a `CMTime`
to `Int` unguarded, which traps with a fatal error when `exposureDuration` is
indefinite (this happens during camera switchover and exposure-mode changes).

**Do not drop this override when upgrading the camera plugin** unless you have
confirmed upstream guards that conversion. Losing it reintroduces a hard crash.

### `kPhilyDebug` must be false before an App Store release
`lib/debug.dart` has a master switch for in-app debug affordances. While it is
`true`, a **"DBG" button that can expire the trial and toggle subscriptions is
live in the UI** — i.e. a paywall bypass.

- Internal TestFlight: `true` is fine and genuinely useful (testers can expire
  the trial instead of waiting seven days).
- External TestFlight and App Store: **must be `false`.**

### Preview FPS is a first-class concern
Frame rate matters more here than in a typical app. Two structural decisions
follow from it:

- The level indicator and composition overlay are separate `CustomPaint`s inside
  their own `RepaintBoundary`s, so ~50 Hz gravity updates repaint only the small
  indicator, never the expensive guide overlay.
- Small floating chrome uses `glassChipDecoration` (gradient-faked glass) rather
  than a real `BackdropFilter`, because a live blur over the preview
  re-rasterises every frame.

Detection cadence is **adaptive** (`_noteDetectionCost` in `camera_page.dart`):
it measures how long each ML Kit pass takes and keeps detection to roughly half
the frame interval, so capable devices run at ~16 fps detection while slower
ones back off instead of stuttering. Don't replace it with a fixed interval.

### Device-dependent capture
`ResolutionPreset.max` is "the most this sensor offers" — 48MP on a recent Pro,
much less on an SE or an older iPhone. The UI therefore labels the toggle
**HIGH / MAX**, not megapixels. Any model-specific claim ("48MP") belongs in the
App Store description, not the UI.

Face detection is also meaningfully slower on older chips; an iPhone SE or 11
will not feel like a current Pro even with the adaptive cadence.

## Layout

- `lib/camera_page.dart` — the camera screen; also the `part` host for the two
  files below, so they share its private state.
- `lib/camera_overlays.dart` — all overlay painters (composition guides, the
  gravity level line / bubble level, zoom meter, focus bracket).
- `lib/compositions.dart` — the composition registry: one `CompositionSpec` per
  mode holding its label, "best for" tip, guide copy, controls and power points.
  Adding or retuning a mode should be a one-line edit here.
- `lib/composition_guide.dart` — the per-mode guide sheet.
- `lib/level_line_state.dart` — the adaptive level-line state machine. Pure
  Dart, no Flutter: all tuning constants live in `LevelLineConfig`, in degrees
  and milliseconds.
- `lib/screens/` — gallery, paywall, first-launch welcome, branded loader.
- `lib/services/shot_guide_log.dart` — per-photo record of the guide a shot
  was taken with (mode, locked, which crossing, roll), keyed by photo-library
  asset id and stored as a small JSON file in the app documents directory. The
  camera writes it after each save; the gallery reads it for the gold lozenge on landed shots, the LANDED
  percentage and the viewer's guide recall. (The BY PHILY filter is the app's
  album — every in-app capture, landed or not.)
- `lib/services/phily_pro.dart` — trial clock and StoreKit entitlement.
- `lib/theme.dart` — the single definition of the app's gold/glass language.
  Prefer reusing `GlassSurface`, `glassChipDecoration`, `MetalRingPainter`,
  `GildedHairline`, `brandDisplay`/`brandLabel` over new one-off styling.
  Interaction lives here too: every small control is `PopTap` (selection tick
  + 114% bubble), `GlassRoundButton` (46pt circle — camera grid toggle, gallery
  share/favourite/delete) or `GlassSquareButton` (48pt, radius 16 — the guide
  "i", the gallery back button); every text bubble is `HintPill`. The camera
  and gallery are built from the same objects — keep it that way rather than
  restyling one side.

## Redesign (Sept 2026)

The UI follows a Claude Design canvas (boards 1a–1g; the decoded template is
kept out of the repo). Its one rule: the viewfinder has three layers — Guide
(persistent, quiet), Targets (reactive, gold, the only thing allowed to move
over the subject) and Status (one rail, one slot, one message, docked above
the gilded lip). Implemented so far: the top settings cluster + `i` guide
button and the bottom hint dock (1b); the gallery's guide recall (1g); the
one-screen first launch that replaced the trial popup (1f). Not yet built:
1e (scene-aware mode suggestion + grouped mode sheet), 1f's after-the-shutter
teaching card, and 1b's level glyph in the rail (which retires the
centre-frame level line in portrait — a decision still open).

First launch is gated by `LaunchGate` in `main.dart` (`phily_onboarded` pref).

## Trial and paywall

The trial clock is **local only** — `SharedPreferences`, 7 days from first
launch, no server involvement. Deleting and reinstalling resets it.

TestFlight builds run against the **StoreKit sandbox**: purchases are free, and
sandbox subscriptions expire in minutes rather than months. IAP product IDs
(`phily_pro_monthly`, `phily_pro_yearly`, `phily_pro_lifetime`) must exist in App
Store Connect or the paywall shows no prices and a lapsed trial becomes a dead
end.

## Porting to Android (currently blocked)

Most of the app is portable — every painter, the level state machine, the trial
logic, the gallery and theme are pure Dart. What isn't:

- `applicationId` is still `com.example.phily`; Google Play rejects `com.example.*`.
- The manifest declares only `CAMERA`. Video needs `RECORD_AUDIO`, and the
  gallery needs media-read permissions (`READ_MEDIA_IMAGES`/`READ_MEDIA_VIDEO`
  on 13+, `READ_EXTERNAL_STORAGE` below).
- The app label is lowercase `phily`, and there are no Android icons.
- The vendored camera patch is iOS-only; Android goes through `camera_android`
  and has its own untested camera behaviour.

## Conventions

- Comments explain **why**, not what. The existing code is written that way;
  match it.
- Prefer extending `CompositionSpec` / `LevelLineConfig` over threading new
  parameters through call sites.
- Animation timing that must survive an uneven sensor or frame rate uses
  wall-clock `dt` easing, never a fixed per-tick step. Getting this wrong makes
  a fade's duration depend on frame rate (it stretched to ~5s at 8 Hz once).
- When editing overlay painters, keep `canvas.save`/`restore` balanced —
  an imbalance silently corrupts everything drawn afterward and neither the
  analyzer nor the tests will catch it.
