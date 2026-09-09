# Overnight polish — log

Branch: `overnight-polish` (off `main`). One pass per loop iteration. Every
pass ends green — `flutter analyze`, `flutter test`, `flutter build ios
--simulator` — or it is reverted. One commit per pass.

## Guardrails (do not cross without Lucas)
- Never touch `kPhilyDebug`, `pubspec` dependencies, `vendor/camera_avfoundation`,
  StoreKit / trial logic, or `phily/ios/*`.
- Never delete a feature. Anything that should go → "Proposals" below.
- Subjective visual calls (colour, size, spacing that isn't from the design
  canvas or a guideline) → "Needs eyes" below, not shipped.
- Only reuse `theme.dart` components (`PopTap`, `HintPill`, `GlassRoundButton`,
  `GlassSquareButton`, `glassChipDecoration`, `GlassSurface`). No one-off styling.

## Backlog — pull from the top
### Speed (measurable)
- [x] Gallery grid: request thumbnails at the cell's actual pixel size
      (`ThumbnailSize` ≈ cell px × devicePixelRatio) instead of a fixed 300 —
      fewer bytes decoded per cell; verify scroll smoothness unchanged. (pass #1)
- [ ] `_CompositionPainter.shouldRepaint`: audit which fields actually change
      per tick; make sure the gravity/level path never repaints the guide layer.
- [ ] Viewer 1440px sharpen: use `precacheImage` before the `setState` swap so
      the sharpen never lands as a hitch; `cacheWidth` on `Image.memory`.
- [ ] `_FpsOverlay` sanity: confirm no debug-only work runs when `kShowFPS`
      is false (allocation in build paths).
- [ ] Belt: `AnimatedBuilder` per pill — confirm only visible pills rebuild.
### Compatibility
- [~] Widget tests: camera chrome + gallery at iPhone SE (375×667), 15 Pro
      (393×852), Pro Max (430×932), and landscape — no overflow, all targets ≥44pt.
      (pass #2: welcome + guide sheet covered in `test/breakpoints_test.dart`;
      camera chrome and gallery grid still need channel mocks — open.)
- [ ] Text scaling: `MediaQuery.textScaler` ×1.3 — chrome labels must not
      wrap or clip; cap scale on the tracked small-caps if needed.
      (pass #2 covers welcome + guide sheet at 1.3×; camera chrome open.)
- [ ] Safe areas: notch vs Dynamic Island vs home-button — top scrim height and
      hint dock offsets derive from `MediaQuery.padding`, verify no magic numbers.
- [ ] Older-device path: confirm adaptive detection cadence engages (log the
      settled interval once in debug).
### Design-system consistency
- [ ] Paywall: `_PrimaryButton` / `_TierRow` → `PopTap`; tier rows ≥44pt;
      any remaining one-off glass → `GlassSurface`.
- [ ] Composition guide sheet: dismiss chip → shared button; section spacing
      on the 8pt grid. (pass #2 measured the GOT IT chip at ~33pt tall — under
      the 44pt target; the shared-button swap fixes both.)
- [ ] Branded loader + welcome: same wordmark treatment (`ShaderMask` recipe)
      — extract to `theme.dart` as `GildedWordmark`.
- [ ] Level-line settings sheet: switch styling matches the paywall's.
- [ ] Audit every `GestureDetector` on a control → `PopTap`.
### Design boards not yet built
- [ ] 1f after-the-shutter card ("RULE OF THIRDS · LANDED" over the photo,
      3 uses per mode, swipe down) — self-contained, reuses `ShotGuide`.
- [ ] 1e grouped all-16 sheet (Balance · Lines & Motion · Shape · Frame) with
      favourites — belt carries favourites + current group.
- [ ] 1e scene suggestion card ("Plate detected · try Circular") — needs a
      detection signal; scope first.
### Hygiene
- [ ] `flutter analyze --fatal-infos` clean (currently only warnings/errors gated).
- [ ] Dead code sweep after the redesign (unused private members, stale comments
      mentioning removed chrome).
- [ ] `CLAUDE.md` kept current as pieces land.
- [ ] `gallery_viewer.dart` is not `dart format` clean (a format pass churns
      ~210 lines) — do it alone, in its own commit, never mixed into a pass.

## Proposals (not done — needs a decision)
- 1b level glyph in the rail: retires the centre-frame level line in portrait.

## Needs eyes (done, but subjective — review on device)
- Gallery grid margins 14px / gutters 5px (from board 1g). Tiles are ~117pt on a
  390pt screen; 8px margins would give ~124pt.
- Pass #1: 3× phones now decode a 355–392px thumb per cell instead of 300px
  (crisp, but ~1.4–1.7× the pixels). Scroll a long library on a 15 Pro and an
  older 3× phone (11 / XS) and confirm the grid still scrolls smoothly.

## Passes
(appended by each loop iteration: what, why, verification, commit)

### Pass #1 — performance — 2026-09-09T02:23:19+0100
- **What:** gallery grid thumbnails are requested at the cell's real pixel size
  — `gridThumbPx(width, dpr)` = (width − 2×14 − 2×5) / 3 × dpr, clamped
  160–420 — instead of a fixed 300×300. The sliver's margin / gutter / column
  values and the sizing share one set of constants so they can't drift.
- **Why:** 300px was drawn at 1.18–1.31× on 3× phones (soft thumbs) and
  decoded ~44% more pixels than the cell needed on 2× phones (SE).
- **Metric:** decode px per cell, SE 375pt @2×: 90,000 → 50,625 (−44%).
  Request size 15 Pro 393pt @3×: 300 → 355 (upscale 1.18× → 1.0×); Pro Max
  430pt @3×: 300 → 392 (1.31× → 1.0×). Landscape / tablet capped at 420 so
  the 300-entry thumb cache stays bounded.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 57/57 (6 new,
  `test/gallery_thumb_size_test.dart`) · `flutter build ios --simulator` ✓
  (27s). Diff: +40/−5 in `gallery_viewer.dart` plus the new test. Not verified
  on device: scroll smoothness on 3× phones → "Needs eyes".
- **Commit:** `overnight: pass #1 — performance — 2026-09-09T02:23:19+0100`

### Pass #2 — compatibility — 2026-09-09T02:56:07+0100
- **What:** new `test/breakpoints_test.dart` pumps the first-launch welcome
  screen and the composition guide sheet (every mode) at iPhone SE, 15 Pro,
  Pro Max and 15 Pro landscape, at 1.0× and 1.3× text, with real safe-area
  insets. It found the welcome screen clipping its button and footnote; fixed
  by letting the column scroll only when it can't fit (`LayoutBuilder` →
  `SingleChildScrollView` → `ConstrainedBox(minHeight)` → `IntrinsicHeight`),
  and by adding the side safe areas to its insets for landscape.
- **Why:** first launch is the first screen anyone sees. With Larger Text on,
  or the phone held landscape, the "Open the camera" button and the trial
  footnote were cut off the bottom (release clips silently — no stripes).
  Landscape copy also sat under the sensor housing (side insets ignored).
- **Metric:** bottom overflow on the welcome screen, before → after:
  SE @1.3× 191px → 0 · 15 Pro @1.3× 30px → 0 · 15 Pro landscape @1.0× 23px → 0
  · landscape @1.3× 92px → 0. Portrait at 1.0× still fits with no scroll
  (asserted, so board 1f's "one screen" holds). Guide sheet: 16 modes × 4
  configs, no overflow, sheet ≤ 86% cap. Breakpoint configurations under
  test: 0 → 12.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 69/69 (12 new)
  · `flutter build ios --simulator` ✓. `welcome.dart` diff is mostly the
  re-indent from the new wrappers; no visual change in portrait at default text.
- **Not covered:** camera chrome and gallery grid (plugin channels); the
  paywall (StoreKit — guardrail).
- **Commit:** `overnight: pass #2 — compatibility — 2026-09-09T02:56:07+0100`
