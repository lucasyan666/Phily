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
- [x] `_CompositionPainter.shouldRepaint`: audit which fields actually change
      per tick; make sure the gravity/level path never repaints the guide layer.
      (pass #9: gravity is a ValueNotifier and never rebuilds the page — that
      path was already clean. The rebuild path was not: `glowSegs` was a fresh
      list per build compared by identity → every setState repainted the
      guide. Now by contents, with a regression test.)
- [ ] Viewer 1440px sharpen: use `precacheImage` before the `setState` swap so
      the sharpen never lands as a hitch; `cacheWidth` on `Image.memory`.
      (pass #5 read the path: the decode is already off the UI thread and
      `gaplessPlayback` holds the old frame; the remaining cost is the raster
      texture upload, which precache doesn't remove. Needs a device trace
      before changing anything — not shipped blind.)
- [x] Gallery grid: seed cells from the page's thumb LRU on mount so scrolling
      back is free — no platform round-trip, no re-decode, no second fade-in.
      (pass #5)
- [x] `_FpsOverlay` sanity: confirm no debug-only work runs when `kShowFPS`
      is false (allocation in build paths). (pass #5: gated by
      `if (kPhilyDebug && kShowFPS)`, both compile-time consts — the overlay
      is tree-shaken out entirely. Nothing to do.)
- [ ] Belt: `AnimatedBuilder` per pill — confirm only visible pills rebuild.
### Compatibility
- [~] Widget tests: camera chrome + gallery at iPhone SE (375×667), 15 Pro
      (393×852), Pro Max (430×932), and landscape — no overflow, all targets ≥44pt.
      (pass #2: welcome + guide sheet covered in `test/breakpoints_test.dart`;
      camera chrome and gallery grid still need channel mocks — open.)
- [~] Text scaling: `MediaQuery.textScaler` ×1.3 — chrome labels must not
      wrap or clip; cap scale on the tracked small-caps if needed.
      (pass #2 covers welcome + guide sheet at 1.3×; pass #6 extends both to
      the AX2 ≈ 2.0× and AX5 ≈ 3.1× accessibility sizes, no caps needed —
      layouts wrap or grow instead. Camera chrome still open.)
- [~] Safe areas: notch vs Dynamic Island vs home-button — top scrim height and
      hint dock offsets derive from `MediaQuery.padding`, verify no magic numbers.
      (pass #6 audit: every top offset derives from `padding.top` or the
      measured `_topInset`; side insets are moot — `main.dart` locks portrait.
      The bottom chrome does NOT read `padding.bottom` → "Proposals".)
- [ ] Older-device path: confirm adaptive detection cadence engages (log the
      settled interval once in debug).
### Design-system consistency
- [x] Paywall: `_PrimaryButton` / `_TierRow` → `PopTap`; tier rows ≥44pt;
      any remaining one-off glass → `GlassSurface`. (pass #11: tier rows and
      legal links are PopTaps at 44pt; the CTA keeps its own detector — it
      owns a press scale + shimmer — but gained the button trait and Reduce
      Motion. No one-off `GlassSurface` candidates were left.)
- [~] Composition guide sheet: dismiss chip → shared button (pass #3: PopTap,
      gallery filter-chip geometry, 44pt target). Section spacing on the 8pt
      grid is still open — see "Needs eyes".
- [x] Branded loader + welcome: same wordmark treatment (`ShaderMask` recipe)
      — extract to `theme.dart` as `GildedWordmark`. (pass #7)
- [ ] Level-line settings sheet: switch styling matches the paywall's.
- [ ] Audit every `GestureDetector` on a control → `PopTap`. (pass #3: guide
      sheet done; remaining raw ones — welcome CTA, paywall `_PrimaryButton` /
      `_TierRow` / `_LegalLink`, and the camera/gallery call sites.)
### Design boards not yet built
- [ ] 1f after-the-shutter card ("RULE OF THIRDS · LANDED" over the photo,
      3 uses per mode, swipe down) — self-contained, reuses `ShotGuide`.
- [ ] 1e grouped all-16 sheet (Balance · Lines & Motion · Shape · Frame) with
      favourites — belt carries favourites + current group.
- [ ] 1e scene suggestion card ("Plate detected · try Circular") — needs a
      detection signal; scope first.
### Accessibility
- [~] VoiceOver: pass #10 gives every `PopTap` the button trait + enabled
      state, and names the six icon-only glass controls (gallery back / share /
      favourite / delete, camera grid toggle, guide "i"); favourite and grid
      toggle announce on/off. Pass #11 added the paywall: tier rows announce
      name + price + selection, legal links and the CTA are named buttons.
      Pass #12 added the camera's bottom chrome: the shutter (with its
      hold-to-record gesture named), the gallery thumb, and the belt pills
      (which now carry `selected`, so VoiceOver distinguishes the active mode
      from the other fifteen). Still unlabelled: the zoom + exposure controls
      (both continuous — they want value + increase/decrease actions, not a
      label, so they are their own pass).
- [~] Reduce Motion (`MediaQuery.disableAnimations`): pass #4 covers PopTap
      (every glass control / chip / guide dismiss), the gallery thumb fade-in,
      selection scale, filter chips and the viewer's zoom-open; pass #8 adds
      the branded loader (spin, breathing aura, entrance rise). Still ignoring
      it: the gallery viewer's delete / favourite animations and camera-page
      decorative fades (hint dock, belt). Pass #11 covered the paywall CTA
      sweep + press scale and the tier-row selection glide.
      Informational motion (level line, targets) is deliberately left alone.
### Hygiene
- [ ] `flutter analyze --fatal-infos` clean (currently only warnings/errors gated).
- [ ] Dead code sweep after the redesign (unused private members, stale comments
      mentioning removed chrome). Known: `_glowSegMap` in `camera_page.dart` is
      declared and read but never written (pass #9) — the painter's
      edge-aligned-line glow has no producer. Keep or remove is a feature call.
- [ ] `CLAUDE.md` kept current as pieces land.
- [ ] `gallery_viewer.dart` is not `dart format` clean (a format pass churns
      ~210 lines) — do it alone, in its own commit, never mixed into a pass.

## Proposals (not done — needs a decision)
- 1b level glyph in the rail: retires the centre-frame level line in portrait.
- Camera bottom chrome vs the home indicator (pass #6 audit). The bottom
  panel is `Positioned(bottom: 0)` with a fixed 16pt pad and never reads
  `MediaQuery.padding.bottom`. On Face ID phones the indicator bar sits ~13–21pt
  above the edge, so the 72pt shutter's lowest ~5pt lies under it and its
  bottom ~20pt is in the system swipe-up zone (touches there can be delayed
  or taken by iOS). HIG says keep controls clear of it. The fix — add
  `padding.bottom` (34pt) to the pad, or `max(16, padding.bottom)` — moves the
  whole shutter row up 18–34pt on every Face ID phone and shrinks the preview
  band; not a small visual diff, so it needs Lucas on a device. Home-button
  phones (SE) are unaffected either way.
- `setPreferredOrientations([portraitUp, portraitDown])` while capture is
  locked to portraitUp. Face ID phones never rotate to portraitDown, but a
  home-button SE will: the UI flips 180° and the preview shows the world
  upside down relative to it. iOS Camera avoids this by allowing portraitUp
  only. Dropping portraitDown is one line, but it could be intentional.

## Needs eyes (done, but subjective — review on device)
- Gallery grid margins 14px / gutters 5px (from board 1g). Tiles are ~117pt on a
  390pt screen; 8px margins would give ~124pt.
- Guide sheet spacing is 14 / 4 / 14 / 16 / 14 / 20 / 5 — not on the 8pt
  grid. Moving to 16 / 8 / 16 / 16 / 24 / 8 is a visual call, not a token fix;
  the sheet's dismiss chip is now 40pt (was ~33) so a re-tune should look at
  the whole column at once.
- Pass #7: the loader's wordmark gilding changed from a vertical paper→gold
  sweep (stops 0.3) to the welcome's diagonal one (stops 0.35, board 1f) so
  the two screens share one recipe. Subtle; check the loading screen once.
- Pass #6: at AX text sizes (Settings → Accessibility → Larger Text, top
  three sizes) the welcome CTA now grows to two lines and the guide sheet's
  eyebrow drops the PORTRAIT/LANDSCAPE tag to a second line. Worth one look
  with AX5 on to confirm it reads as designed rather than broken.
- Pass #5: scrolling back up the gallery grid should now show already-seen
  thumbs instantly with no fade (iOS Photos behaviour). Fresh cells still fade
  in over 280ms. Check the two don't look inconsistent side by side.
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

### Pass #3 — design-system — 2026-09-09T03:24:47+0100
- **What:** the composition guide sheet's "GOT IT" dismiss is now the shared
  `PopTap` control with the gallery filter chip's geometry (40pt tall, radius
  20, glass-chip decoration), wrapped in a 2pt vertical pad so the hit area is
  44pt. The manual `hapticTap()` went with the raw `GestureDetector` — PopTap
  ticks on its own, so the swap doesn't double the haptic.
- **Why:** CLAUDE.md's rule is that every small control is PopTap and the
  camera and gallery are built from the same objects. The sheet's only control
  was a one-off with no tap feedback and a ~33pt target, under the 44pt
  minimum.
- **Metric:** dismiss tap target ~33pt → 44pt (visible chip 40pt, same as the
  gallery's chips). Raw `GestureDetector` controls in `composition_guide.dart`:
  1 → 0. Test now asserts, for all 16 modes on SE and landscape at 1.0×/1.3×,
  that the dismiss is a PopTap, ≥44pt, and closes the sheet when tapped.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 69/69 ·
  `flutter build ios --simulator` ✓. Diff: +25/−21 in the sheet, test +30.
  Visual change: the chip is 7pt taller; nothing else moves.
- **Commit:** `overnight: pass #3 — design-system — 2026-09-09T03:24:47+0100`

### Pass #4 — design-board — 2026-09-09T03:53:51+0100
- **What:** iOS Reduce Motion now stills the app's decorative motion. Two
  helpers in `theme.dart` — `reduceMotionOf(context)` and
  `motionOf(context, duration)` — wired into `PopTap` (the tick and the
  callback stay; the 114% bubble doesn't run), `GlassRoundButton`, the gallery
  filter chips, the grid thumb fade-in and selection scale, and the viewer's
  open transition (crossfade only, the way iOS itself opens a photo).
- **Why:** the boards make motion a deliberate part of the design — Targets
  are "the only thing allowed to move over the subject" — and the loop's brief
  asks for prefers-reduced-motion to be respected. It was honoured nowhere.
  Routing it through PopTap covers every small control at once, camera and
  gallery alike, without touching call sites.
- **Metric:** decorative animations honouring Reduce Motion: 0 → 6 sites
  (PopTap, GlassRoundButton, `_FilterChip`, thumb fade, selection scale,
  viewer zoom-open); via PopTap that is every glass control in the app.
  Users without Reduce Motion see no change (asserted: the bubble still peaks
  past 105% mid-tap and settles to 1.0).
- **Verification:** `flutter analyze` 0 issues · `flutter test` 72/72 (3 new,
  `test/reduce_motion_test.dart`) · `flutter build ios --simulator` ✓.
  Diff: +21/−6 across `theme.dart` and `gallery_viewer.dart`.
- **Commit:** `overnight: pass #4 — design-board — 2026-09-09T03:53:51+0100`

### Pass #5 — performance — 2026-09-09T04:23:37+0100
- **What:** gallery grid cells are seeded from the page's 300-entry thumbnail
  LRU on mount (`_GridThumb.initialBytes`). On a hit the cell shows the bytes
  immediately, skips the `thumbnailDataWithSize` request, skips the fade-in,
  and bumps the entry's recency. Misses are unchanged.
- **Why:** cells don't keep alive, so every cell scrolled back into view was
  re-requesting its thumbnail — a platform round-trip, an iOS-side JPEG
  re-encode of a 355px thumb, a Dart decode — and fading in again, for bytes
  the page already held. The cache was only ever read by the viewer's
  placeholder.
- **Metric:** platform thumbnail requests on scroll-back: 1 per re-entered
  cell → 0 for any cell in the LRU (≈300 cells ≈ 14 screens at 3×7). Repeat
  fade-ins on scroll-back: 1 per cell → 0. Forward scrolling and first open
  are unchanged. Analytical — the widget is private and the page needs
  photo_manager channel mocks to pump, so no unit test this pass.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 72/72 ·
  `flutter build ios --simulator` ✓. Diff: +20/−4 in `gallery_viewer.dart`.
  On-device check → "Needs eyes".
- **Also:** read the viewer sharpen and FPS-overlay backlog items; neither
  warrants a change (notes inline in the backlog).
- **Commit:** `overnight: pass #5 — performance — 2026-09-09T04:23:37+0100`

### Pass #6 — compatibility — 2026-09-09T04:56:03+0100
- **What:** breakpoint tests extended to Apple's accessibility text sizes
  (2.0× ≈ AX2, 3.1× ≈ AX5) with two new assertions — a label's laid-out text
  must fit its own box, and the guide dismiss must be a chip, not a bar. They
  caught four defects, all fixed:
  1. **Guide sheet eyebrow** (`GUIDE … PORTRAIT`) overflowed horizontally by
     127px on an SE at 3.1×. The Row is now a `Wrap` with space-between: one
     line at normal sizes (identical), the hold tag drops to a second line at
     AX sizes.
  2. **Welcome CTA** was a fixed 54pt box; at 2.0×+ the label wrapped and
     spilled past the gold. Now `minHeight: 54` + padding, so it is exactly
     54pt at default sizes and grows with its label.
  3. **Guide dismiss chip** had a fixed 40pt height with the same spill at AX
     sizes → `minHeight: 40`.
  4. **Regression from pass #3 (mine):** that chip's `alignment: center` on a
     `Container` inside a bounded `Center` made it expand to the sheet's full
     width — it has been a 40pt full-width bar since pass #3, not a chip. The
     height-only assertion missed it. Now shrink-wrapped
     (`Center(widthFactor: 1, heightFactor: 1)`) and asserted narrower than
     the content width for every mode and config.
- **Why:** Larger Text is the most-used accessibility setting on iOS; the
  top three sizes are where fixed-height boxes and Spacer rows break. And a
  full-width dismiss bar was never the design.
- **Metric:** text-scale configs under test: 2 → 4 (12 → 24 breakpoint
  tests). Horizontal overflow, guide eyebrow SE @3.1×: 127px → 0. Label
  spill out of the welcome CTA at 2.0×/3.1×: 7 configs → 0. Dismiss chip
  width on SE @1.0×: 327pt (full content width) → ~124pt.
- **Also found, not shipped:** the camera's bottom chrome ignores
  `padding.bottom` (shutter under the home-indicator zone on Face ID phones)
  and `portraitDown` is allowed while capture is locked portraitUp. Both
  change what Lucas sees on device → "Proposals" with numbers.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 84/84 (12
  new) · `flutter build ios --simulator` ✓. `composition_guide.dart` diff is
  mostly the re-indent from the Wrap; `welcome.dart` +5/−2.
- **Commit:** `overnight: pass #6 — compatibility — 2026-09-09T04:56:03+0100`

### Pass #7 — design-system — 2026-09-09T05:24:32+0100
- **What:** `GildedWordmark` in `theme.dart` — "Phily" in the editorial serif
  under the board 1f paper→gold diagonal `ShaderMask`. The branded loader and
  the first-launch welcome both draw it now, with their own size / weight /
  tracking (52 · w400 · +0.5 and 44 · w300 · −0.5, unchanged).
- **Why:** CLAUDE.md's rule is that the app is built from shared objects in
  `theme.dart`. The two screens carried separate wordmark recipes with
  *different* gradients (vertical, stops 0.3 vs diagonal, stops 0.35), while
  the welcome's own comment says it should read as one moment with the
  loader. The canvas-derived gradient (1f) won; size/weight/tracking are
  per-context and stayed.
- **Metric:** wordmark recipes in the codebase: 2 → 1. `ShaderMask` uses
  outside `theme.dart`: 2 → 0 (asserted per screen: exactly one
  `GildedWordmark`, exactly one `ShaderMask`). Loader gradient now matches
  the welcome's — one subtle visual change, on the loading screen only.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 87/87 (3 new,
  `test/gilded_wordmark_test.dart`) · `flutter build ios --simulator` ✓.
  Diff: −34/+46 across three files, net −16 lines at the call sites.
- **Commit:** `overnight: pass #7 — design-system — 2026-09-09T05:24:32+0100`

### Pass #8 — design-board — 2026-09-09T05:51:41+0100
- **What:** the branded loader honours Reduce Motion. The φ-spiral's 5s
  rotation is started from `didChangeDependencies` (where MediaQuery is
  readable) only when motion is allowed; under Reduce Motion the mark holds
  at angle 0, the aura rests at mid-breath, and the 750ms fade-and-rise
  entrance is instant via `motionOf`. Default behaviour is unchanged.
- **Why:** the loader is the first thing on screen on every cold start, and
  it was the largest remaining decorative motion ignoring the setting after
  pass #4 — a continuously spinning mark is exactly what Reduce Motion users
  turn the setting on to avoid.
- **Metric:** decorative animation sites honouring Reduce Motion: 6 → 7 (the
  loader counts its spin, aura and entrance as one site). Asserted: the
  spiral's angle stays 0 across 3s of frames under Reduce Motion and advances
  without it; the entrance is fully opaque on the first settled frame.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 89/89 (2 new)
  · `flutter build ios --simulator` ✓. Diff: +18/−4 in `branded_loader.dart`.
- **Commit:** `overnight: pass #8 — design-board — 2026-09-09T05:51:41+0100`

### Pass #9 — performance — 2026-09-09T06:20:32+0100
- **What:** `_CompositionPainter.shouldRepaint` compares `glowSegs` by
  contents (`listEquals`) instead of identity. The camera page hands the
  painter `_glowSegMap.values.toList()` — a fresh list — on every build, so
  the identity check returned true on every `setState` and re-rasterised the
  full-screen guide overlay with nothing in it changed. A `@visibleForTesting`
  seam (`debugCompositionPainterRepaints`) plus `test/guide_repaint_test.dart`
  lock "unchanged state → no repaint" for all 16 modes, and "mode change →
  repaint".
- **Why:** the guide overlay is the most expensive layer on the camera screen
  and CLAUDE.md isolates it in its own `RepaintBoundary` specifically so
  ~50 Hz gravity never touches it. The audit found that path clean (gravity
  is a `ValueNotifier`), but the *rebuild* path leaked: a pinch-zoom, a belt
  scroll or any chrome toggle is a `setState` per frame, and each one was
  repainting the overlay. Per-tick easing (face brackets, glows) still
  repaints through the `repaint` listenable, unchanged.
- **Metric:** guide-overlay repaints per no-op page rebuild: 1 → 0 (asserted
  for every mode). The map is in fact never populated anywhere, so in
  practice every one of those repaints was wasted.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 91/91 (2 new)
  · `flutter build ios --simulator` ✓. Diff: +17/−1 in
  `camera_overlays.dart`, +1 import in `camera_page.dart`. No visual change.
- **Commit:** `overnight: pass #9 — performance — 2026-09-09T06:20:32+0100`

### Pass #10 — compatibility — 2026-09-09T06:49:31+0100
- **What:** VoiceOver support for the shared controls. `PopTap` now wraps its
  detector in `MergeSemantics` + `Semantics(button, enabled, label, toggled)`,
  so every small control in the app is announced as a button, text chips are
  named by their own text, and icon-only controls take a `semanticLabel`.
  `GlassRoundButton` / `GlassSquareButton` forward `semanticLabel` /
  `toggled`; the six icon-only call sites are named — Back, Share,
  Favourite (toggled), Delete, Composition guide (toggled), About this
  guide. `test/semantics_test.dart` locks the contract.
- **Why:** there was not one `Semantics`, `semanticLabel` or `Tooltip` in
  `lib/`. A VoiceOver user reaching the gallery's action row heard three
  unnamed, trait-less targets; the camera's grid toggle and guide button the
  same. Assistive tech is device compatibility, and this is the cheapest
  layer to fix because the app is built from one control.
- **Metric:** icon-only controls with a VoiceOver name: 0/6 → 6/6. Controls
  exposing the button trait: 0 → every `PopTap` (glass buttons, filter chips,
  guide dismiss, settings segments, guide pill). Toggles announcing state:
  0 → 2. Disabled controls announce disabled rather than button (asserted).
  No visual change.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 95/95 (4 new)
  · `flutter build ios --simulator` ✓. Diff: +52/−18 in `theme.dart`
  (mostly the re-indent under the two wrappers), +5 gallery, +3 camera.
- **Commit:** `overnight: pass #10 — compatibility — 2026-09-09T06:49:31+0100`

### Pass #11 — design-system — 2026-09-09T09:30:11+0100
- **What:** the paywall now uses the app's shared control. `_TierRow` and
  `_LegalLink` are `PopTap`s (selection tick, bubble, button trait) with
  explicit 44pt minimum targets; the tier-row selection glide and the CTA's
  press scale go through `motionOf`; the CTA's 2.8s shimmer loop starts only
  when motion is allowed. Tier rows announce "Yearly, £19.99 per year" with
  their selected state; the CTA announces as a button.
- **Why:** CLAUDE.md's rule is that every small control is `PopTap` and the
  camera and gallery are built from the same objects — the paywall was the
  last screen still on raw `GestureDetector`s. It was also the last place
  with a forever-looping decorative animation ignoring Reduce Motion, on the
  one screen a user reads carefully before spending money.
- **Metric:** raw `GestureDetector` controls in `paywall.dart`: 3 → 1 (the
  CTA, which owns a press scale and shimmer; it gained the button trait
  instead). Controls below the 44pt target: 2 → 0 (legal links were ~23pt,
  short tier rows ~41pt). Decorative animation sites honouring Reduce
  Motion: 7 → 9. Paywall controls with a VoiceOver name: 0 → 5.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 96/96 (1 new)
  · `flutter build ios --simulator` ✓. Diff: 185 lines raw, but 40
  substantive — the rest is re-indentation under the new wrappers
  (`git diff --ignore-all-space` = +40/−9). No visual change at default
  settings.
- **StoreKit untouched:** no change to purchase, restore, product lookup or
  entitlement logic — presentation only, per the guardrail.
- **Commit:** `overnight: pass #11 — design-system — 2026-09-09T09:30:11+0100`

### Pass #12 — design-board — 2026-09-09T09:58:06+0100
- **What:** the camera's bottom chrome announces itself to VoiceOver. Three
  `Semantics` wrappers: the shutter (`Take photo` / `Stop recording`, plus an
  `onLongPressHint` for hold-to-record), the gallery thumbnail
  (`Open the gallery`), and each belt pill (the mode's label, `selected` for
  the active one, and `Open the guide` as the long-press hint).
- **Why:** board 1b's rule is that the viewfinder carries Guide, Targets and
  Status as distinct layers — the belt is how you change the Guide layer, and
  a screen reader could not tell which of the sixteen modes was active, or
  that a long-press opened the guide at all. The shutter, the app's primary
  control, was an unnamed 70pt target. Board 1b is about making the current
  state legible; this makes it legible non-visually.
- **Metric:** unnamed camera controls: 3 → 0 (shutter, gallery thumb, 16 belt
  pills). Belt pills conveying selection: 0 → 16. Gestures with a spoken
  hint: 0 → 2 (hold-to-record, long-press-for-guide). The aspect-ratio and
  turn/flip buttons were already readable — they carry text or are
  `GlassRoundButton`s named in pass #10.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 96/96 ·
  `flutter build ios --simulator` ✓. Diff: 81 lines raw, 63 substantive minus
  re-indentation. No visual change — semantics only. Not unit-tested: the
  camera page is plugin- and timer-driven and can't be pumped (the shared
  `PopTap` contract is covered in `test/semantics_test.dart`); verify with
  VoiceOver on device.
- **Commit:** `overnight: pass #12 — design-board — 2026-09-09T09:58:06+0100`
