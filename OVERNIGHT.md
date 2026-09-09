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
- [x] Breathing "Perfect"/"Level" pill: hoist the pill out of its 60fps
      animation so only the rim/glow rebuild. (pass #21)
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
- [x] Gallery overlay chrome (fast-scroll thumb, pull dim) in its own
      `RepaintBoundary` — both repaint per frame as siblings of the grid in
      one `Stack`, so their frames were dirtying grid cells. (pass #17)
- [x] Belt: `AnimatedBuilder` per pill — confirm only visible pills rebuild.
      (pass #13: `PageView.builder` already limits *which* pills exist —
      `viewportFraction: 0.28` keeps ~5 alive. The waste was inside each one:
      the whole subtree, label included, rebuilt every scroll frame. The
      label is now hoisted into `AnimatedBuilder`'s `child`.)
### Compatibility
- [~] Widget tests: camera chrome + gallery at iPhone SE (375×667), 15 Pro
      (393×852), Pro Max (430×932), and landscape — no overflow, all targets ≥44pt.
      (pass #2: welcome + guide sheet covered in `test/breakpoints_test.dart`;
      pass #14 adds the gallery's empty state and pass #16 the guide caption,
      both via `@visibleForTesting` seams.
      Pass #22 adds the viewer chrome (guide pill, date chip) and the grid's
      pinned day header, and found a real overflow in the header.
      Still open: the populated grid itself and the camera chrome. Both need
      channel mocks — pass #22 scoped that: PhotoManager alone would mean
      stubbing ~12 methods and matching their internal response shapes,
      brittle against every plugin upgrade. Worth doing deliberately, not
      squeezed into a polish pass.)
- [~] Text scaling: `MediaQuery.textScaler` ×1.3 — chrome labels must not
      wrap or clip; cap scale on the tracked small-caps if needed.
      (pass #2 covers welcome + guide sheet at 1.3×; pass #6 extends both to
      the AX2 ≈ 2.0× and AX5 ≈ 3.1× accessibility sizes, no caps needed —
      layouts wrap or grow instead; pass #14 adds the gallery empty state and
      found a real 238px overflow there; pass #22 covers the viewer chrome and
      day header, finding a 24px overflow. Camera chrome still open.)
- [~] Safe areas: notch vs Dynamic Island vs home-button — top scrim height and
      hint dock offsets derive from `MediaQuery.padding`, verify no magic numbers.
      (pass #6 audit: every top offset derives from `padding.top` or the
      measured `_topInset`; side insets are moot — `main.dart` locks portrait.
      The bottom chrome does NOT read `padding.bottom` → "Proposals".)
- [x] Older-device path: confirm adaptive detection cadence engages. (pass
      #18: extracted to `DetectionCadence` — pure Dart — and tested directly
      instead of logging. A log only helps someone watching a console; the
      tests hold on every run.)
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
- [x] Level-line settings sheet: switch styling matches the paywall's.
      (pass #15: `GildedSwitch` in `theme.dart` — gilt track on, smoked glass
      off, on a `PopTap`. It was `SwitchListTile.adaptive`, the last
      platform-default control in the app.)
- [x] Audit every `GestureDetector` on a control → `PopTap`. Done across
      passes #3 (guide sheet), #11 (paywall tier rows + legal links) and #19
      (welcome CTA). The audit's conclusion: the 21 raw `GestureDetector`s
      left are **correctly** raw — pan/zoom/swipe handlers (viewer pager,
      InteractiveViewer, tap-to-hide-chrome), and three controls that own
      richer feedback than the bubble: the paywall CTA (press scale +
      shimmer), the shutter (bop + record glow) and the grid cell (0.86
      "lifted" selection scale, which a 114% bubble would fight). Those three
      carry the button trait via `Semantics` instead. Nothing left to convert.
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
      Pass #16 merged the gallery's guide caption into one spoken sentence.
      Pass #15 named the level-line switch. Pass #12 added the camera's
      bottom chrome: the shutter (with its
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
- Pass #21: the breathing "Perfect"/"Level" rim + glow now paint as a
  foreground decoration over the pill instead of inside it. Same values, new
  paint order — confirm the gold still reads the same on device.
- Pass #20: the hint pill is now up to 340pt wide instead of a flat 260pt, so
  the dock reads wider and shorter on every phone. Board 1b's "one rail, one
  slot, one message" — check the proportion against the canvas.
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

### Pass #13 — performance — 2026-09-09T10:26:34+0100
- **What:** the belt pill's label is hoisted into `AnimatedBuilder`'s `child`,
  so it is shaped once and passed through on every subsequent frame.
  `_buildCompositionButton` was split: `_compositionButtonLabel` builds the
  constant `Text`, and the gilding (gradient, rim, glow) takes it as a
  parameter. The label's colour still rides centred-ness, now via a
  `DefaultTextStyle.merge` above the already-built Text rather than a new
  `TextStyle` on a rebuilt one.
- **Why:** the backlog asked whether only visible pills rebuild. They do —
  `PageView.builder` with `viewportFraction: 0.28` keeps about five alive.
  The real waste was one level down: each live pill's `AnimatedBuilder`
  rebuilt its *entire* subtree every frame while scrolling, re-running text
  layout for an uppercase, letter-spaced label that never changes. Text
  shaping is among the more expensive things to repeat per frame, and the
  belt animates continuously through a swipe.
- **Metric:** label widget builds during a scroll: once per visible pill per
  frame → once per pill, total. At ~5 live pills and 60fps that is ~300
  redundant text layouts per second of scrolling → 0. Asserted in
  `test/belt_rebuild_test.dart`: across 10 driven frames the builder runs
  more than 5 times while the hoisted child builds exactly once.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 97/97 (1 new)
  · `flutter build ios --simulator` ✓. Diff: +22/−9 in `camera_page.dart`.
  No visual change — same widget tree, same gilding maths.
- **Note:** the test is structural (the pattern), not a mount of the camera
  page, which is plugin- and timer-driven and cannot be pumped. The FPS win
  itself wants a device trace to quantify.
- **Commit:** `overnight: pass #13 — performance — 2026-09-09T10:26:34+0100`

### Pass #14 — compatibility — 2026-09-09T10:54:19+0100
- **What:** breakpoint coverage for the gallery's empty state (both variants:
  all-photos and BY PHILY), via a `@visibleForTesting` seam since the widget
  is private. The tests found a real overflow and this pass fixes it: the
  column now scrolls only when it can't fit, and above 1.5× text the
  decorative 128pt mark shrinks (icon scaling with it) so the copy gets the
  space. Both lines are centre-aligned for when they wrap.
- **Why:** the empty state is the first screen a new user sees, before they
  have taken a photo, and it was the last pure-widget screen with no
  breakpoint coverage. Its shape — a fixed-size mark above two unbounded
  lines of copy in a `Center` — is exactly what clips on a short phone at
  large text, and `Center` clips silently in release.
- **Metric:** bottom overflow, before → after: SE @3.1× (BY PHILY) 238px → 0
  · SE @3.1× (all photos) 90px → 0 · 15 Pro landscape @3.1× (BY PHILY) 106px
  → 0. Breakpoint configurations under test: 24 → 56 (4 devices × 4 text
  scales × 2 variants added). Ordinary sizes are untouched, asserted: at
  ≤1.3× nothing scrolls and the mark is still 52pt.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 129/129 (32
  new) · `flutter build ios --simulator` ✓. Diff: +30/−9 in
  `gallery_viewer.dart` (seam + layout), test +45.
- **Commit:** `overnight: pass #14 — compatibility — 2026-09-09T10:54:19+0100`

### Pass #15 — design-system — 2026-09-09T11:22:35+0100
- **What:** `GildedSwitch` in `theme.dart` — a 46×27 gilded track (the paywall
  CTA's lit-gold metal when on, an inactive chip's smoked glass when off) with
  a polished thumb, sitting on `PopTap`. The level-line settings sheet uses it
  instead of `SwitchListTile.adaptive`, and its copy is laid out by hand so it
  keeps the sheet's type scale and can wrap at large text sizes.
- **Why:** the sheet was the last place in the app showing a platform default:
  an iOS-green switch track in a screen whose every other pixel is gold on
  smoked glass. CLAUDE.md's rule is that the app is built from `theme.dart`
  objects, and a switch is a control like any other — routing it through
  `PopTap` means it inherits the tick, the bubble, the button trait and
  Reduce Motion for free, none of which the adaptive switch had.
- **Metric:** platform-default controls in `lib/`: 1 → 0. Switch styling
  matching the app palette: no → yes (asserted: the on-track gradient
  contains `kGold`, the off-track doesn't). Controls announcing name + state
  in the settings sheet: 0 → 1. The manual `hapticTap()` the old
  `onChanged` called is now `PopTap`'s — fires once, not twice (verified).
- **Verification:** `flutter analyze` 0 issues · `flutter test` 131/131 (2
  new) · `flutter build ios --simulator` ✓. Diff: +102/−4 `theme.dart` (the
  new widget), +48/−30 `camera_page.dart` (the swap).
- **Needs eyes:** the switch is new visual work — a gilt track where an
  iOS-green one used to be. Worth one look on device.
- **Commit:** `overnight: pass #15 — design-system — 2026-09-09T11:22:35+0100`

### Pass #16 — design-board — 2026-09-09T11:50:21+0100
- **What:** board 1g's guide caption — "Subject on the top-left crossing.
  Locked at 0.4° off level." — is wrapped in `MergeSemantics`, so a screen
  reader gets the recall line, the gold lock clause and the timestamp as one
  statement rather than three nodes to swipe through. Plus 24 breakpoint
  tests for it (3 guide variants × SE and landscape × 4 text scales) through
  a new `@visibleForTesting` seam.
- **Why:** 1g's whole point is the caption — the app telling you *why* a shot
  worked. Delivered as three fragments, a swipe lands mid-thought ("Locked at
  0.4° off level." with no idea what locked, or the timestamp alone). The
  sentence was written to be read as a sentence.
- **Metric:** semantics nodes for the caption: 3 → 1, asserted to contain the
  crossing, the roll figure and the timestamp together. Breakpoint
  configurations under test: 56 → 80. The layout itself was already sound —
  0 overflows found across all 24 configurations, so the tests are a
  regression guard, not a fix.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 156/156 (25
  new) · `flutter build ios --simulator` ✓. Diff: +12/−2 in
  `gallery_viewer.dart` (seam + wrapper), test +90. No visual change.
- **Honest note:** I went looking for a visual defect in 1g and didn't find
  one; the caption renders correctly everywhere I could test it. The real
  gap was non-visual, so that is what this pass fixed. The three unbuilt
  boards (1e ×2, 1f's after-the-shutter card) remain too large for one green
  pass — each needs its own session.
- **Commit:** `overnight: pass #16 — design-board — 2026-09-09T11:50:21+0100`

### Pass #17 — performance — 2026-09-09T12:18:35+0100
- **What:** the gallery grid's two per-frame overlays — the fast-scroll thumb
  (and its date bubble) and the pull-to-dismiss dim — each get a
  `RepaintBoundary`. Both are siblings of the scrolling grid inside one
  `Stack`, so every frame they painted marked the shared layer dirty and the
  grid's thumbnails repainted with them.
- **Why:** CLAUDE.md already applies exactly this reasoning on the camera
  side ("the level indicator and composition overlay are separate
  `CustomPaint`s inside their own `RepaintBoundary`s, so ~50 Hz gravity
  updates repaint only the small indicator"). The gallery had the same shape
  without the same treatment: the thumb tracks the scroll offset at display
  rate, and the dim follows the finger through the pull *and* its spring-back
  — full-screen, over a grid of decoded images.
- **Metric:** sibling repaints while an overlay animates: 12 frames → 0
  (asserted in `test/repaint_isolation_test.dart`, which counts real
  `CustomPainter.paint` calls). The `_pull` notifier's own comment already
  claimed "the GridView is never rebuilt mid-pull" — true of *rebuild*, but
  it was still being *repainted*; that gap is now closed.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 158/158 (2
  new) · `flutter build ios --simulator` ✓. Diff: +33/−21 in
  `gallery_viewer.dart`, mostly re-indentation under the two wrappers. No
  visual change.
- **Test design:** the isolation test ships with its own control — a second
  case asserting the *unboundaried* arrangement does repaint the sibling. If
  a future Flutter change made the first test vacuous, the control fails and
  says so, rather than the suite quietly proving nothing.
- **Note:** the one remaining Speed item (viewer 1440px sharpen) stays open
  by choice — pass #5 established it needs a device trace, and this loop
  cannot produce one.
- **Process note:** the log/baseline write for this pass aborted on a stale
  anchor (it searched for an unticked backlog line that pass #13 had already
  ticked), so the code committed without them; amended in place. The gates
  above all ran on the committed tree.
- **Commit:** `overnight: pass #17 — performance — 2026-09-09T12:18:35+0100`

### Pass #18 — compatibility — 2026-09-09T12:48:18+0100
- **What:** the adaptive detection cadence moved out of `camera_page.dart`
  into `lib/detection_cadence.dart` as `DetectionCadence` — pure Dart, no
  Flutter, tuning constants named (`kFloorMs`, `kCeilMs`, `kSmoothing`,
  `kMaxStepMs`, `kDutyCycle`) rather than inline magic numbers. Behaviour is
  unchanged: same floor, ceiling, smoothing and step. 10 tests cover it.
- **Why:** the backlog asked to "confirm the cadence engages (log the settled
  interval once in debug)". A debug log only confirms anything if a person is
  watching a console on the right phone at the right moment, and `kPhilyDebug`
  must be false for release anyway. The cadence is the reason an iPhone SE or
  11 stays usable, and it is pure arithmetic — so the honest way to confirm it
  is to assert it. Follows the `LevelLineConfig` precedent CLAUDE.md sets:
  tuning in one pure object, testable without hardware.
- **Metric:** test coverage of the older-device path: 0 → 10 assertions.
  Verified: starts at the floor (a capable device behaves exactly as before);
  holds the floor at 12ms/pass; settles above it at 55ms; tracks ~2× measured
  cost across 40/55/70/90ms; caps at the 200ms ceiling at 500ms/pass; a single
  400ms outlier moves it ≤4ms; it recovers to the floor when the device speeds
  up; never steps more than 4ms between passes; ignores zero/negative
  readings. `camera_page.dart` is 15 lines shorter.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 168/168 (10
  new) · `flutter build ios --simulator` ✓. No behaviour change — the
  arithmetic is identical, only relocated and named.
- **Guardrail:** CLAUDE.md says "Don't replace it with a fixed interval."
  These tests are what makes that instruction enforceable rather than
  advisory — a fixed interval now fails five of them.
- **Commit:** `overnight: pass #18 — compatibility — 2026-09-09T12:48:18+0100`

### Pass #19 — design-system — 2026-09-09T13:16:46+0100
- **What:** the welcome screen's "Open the camera" CTA is now a `PopTap`
  (its manual `hapticTap()` is gone — `PopTap`'s tick replaces it), and the
  gallery grid cell gained `Semantics`: named by date, `selected` in select
  mode, with "Select photos" as its long-press hint. Closes the
  `GestureDetector` audit that has been open since pass #3.
- **Why:** the CTA is the first button anyone taps in the app and it was
  still a one-off — no bubble, no button trait, no Reduce Motion. The audit
  also needed *finishing*, not just progressing: I checked all 21 remaining
  raw detectors rather than converting the easy ones and leaving a vague
  note. They are correctly raw.
- **Metric:** controls that should be `PopTap` but aren't: 1 → 0. Unnamed
  tappable elements in the gallery grid: every cell → 0 (a screen reader got
  an unlabelled image with no hint that long-press starts selection).
  Manual `hapticTap()` calls duplicating `PopTap`'s tick: 1 → 0. Asserted:
  the welcome CTA is a `PopTap` at every breakpoint.
- **Deliberately not converted:** the grid cell. A 114% bubble fights the
  0.86 "lifted" scale selection already gives it — the design system says
  *one* control vocabulary, not one animation regardless of context.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 168/168 ·
  `flutter build ios --simulator` ✓. Diff: +32/−18 across two files. Visual
  change: the welcome CTA now bubbles on tap like every other control.
- **Commit:** `overnight: pass #19 — design-system — 2026-09-09T13:16:46+0100`

### Pass #20 — design-board — 2026-09-09T13:45:22+0100
- **What:** `HintPill`'s width cap is responsive. It was a hard-coded 260pt on
  every device; it now takes the screen width less a 24pt inset each side,
  clamped to 200–340pt, with the old fixed value still available via the
  (now optional) `maxWidth` parameter. 8 breakpoint tests cover it.
- **Why:** board 1b's status layer is "one rail, one slot, one message, docked
  above the gilded lip". A 260pt cap on a 430pt Pro Max wasn't a dock, and
  because the pill could only grow *downward*, a long guide line at
  accessibility text sizes became a tower over the viewfinder — the one thing
  the board says must stay clear. The pill is the app's only chrome made of
  words, so this is the message layer's whole footprint.
- **Metric:** measured with the longest real guide line ("Tilt left until the
  horizon meets the guide"), pill height before → after: **375pt screen** —
  1.0×: 84 → 68pt · 2.0×: 284 → 185pt · 3.1×: 620 → **420pt**. **430pt
  screen** — same 84/284/620 → 68/185/420, and the pill now actually widens
  to 340pt there instead of staying at 260. Height at AX5 down 32%; the
  viewfinder gets ~200pt back. Asserted: the pill uses more than 260pt and
  still clears the screen edge by 40pt.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 176/176 (8
  new) · `flutter build ios --simulator` ✓. Diff: +20/−4 `theme.dart`, test
  +48. No call site passed `maxWidth`, so every pill — camera hint dock,
  gallery guide pill, date chip — gets this.
- **On the unbuilt boards:** I looked at 1f's after-the-shutter card again
  this pass. It needs per-mode use counts persisted, a card widget, a
  swipe-down dismiss and camera-page wiring, none of it testable without
  channel mocks — a session, not a green pass. Not started rather than
  half-landed.
- **Commit:** `overnight: pass #20 — design-board — 2026-09-09T13:45:22+0100`

### Pass #21 — performance — 2026-09-09T14:13:47+0100
- **What:** `HintPill.breathing` — a factory that builds the pill once and
  rebuilds only a `_PulseOverlay` (the gold rim + glow) each frame. The
  camera's "Perfect" / "Level" badge uses it instead of driving a whole
  `HintPill` from `_faceAnim`.
- **Why:** that badge breathes at 60fps **over the live preview**, which
  CLAUDE.md names as the app's first-class performance concern. Only three
  alpha values ride the pulse — glyph tint, rim, glow — but the old builder
  reconstructed the entire pill every frame: `ConstrainedBox`, `Container`,
  the full `BoxDecoration` gradient, the `Row`, and a `Text` whose shaping
  (uppercase, tracked, wrapping against the new responsive width cap) is the
  expensive part. All of it identical frame to frame.
- **Metric:** widget subtree rebuilds per breathe frame: whole pill → rim +
  glow only. Text shaping runs during the breathe: 60/second → **0**.
  Asserted in `test/hint_pill_breathe_test.dart`: across 20 pumped frames the
  `HintPill` element is never rebuilt (same instance, never marked dirty)
  while the pulse is read 20 times. Second test guards the other direction —
  the rim alpha must still brighten, so the breathe can't be "optimised" into
  a static pill.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 178/178 (2
  new) · `flutter build ios --simulator` ✓. Diff: +66 `theme.dart`, +9/−5
  `camera_page.dart`.
- **Visual:** the rim and glow are now drawn as a foreground decoration over
  the pill rather than as part of it. Geometry and colours are the same
  values, but it is a different paint order — worth a glance on device that
  the "Perfect" state still reads identically. → "Needs eyes".
- **Commit:** `overnight: pass #21 — performance — 2026-09-09T14:13:47+0100`

### Pass #22 — compatibility — 2026-09-09T14:42:30+0100
- **What:** breakpoint coverage for the gallery's chrome — the viewer's guide
  pill and date chip, and the grid's pinned day header — through two new
  `@visibleForTesting` seams. The tests found a real defect in the header and
  this pass fixes it: the label is now `Flexible` inside a `minHeight: 30`
  bar (was a hard `height: 30` with an `Expanded` rule), so it wraps and grows
  instead of overflowing.
- **Why:** the backlog has asked for gallery chrome coverage since pass #2
  and every pass deferred it as "needs channel mocks". That is true of the
  *populated grid*, but not of the chrome: like the empty state (#14) and the
  guide caption (#16), these are pure widgets reachable through a seam. The
  day header is also the most-repeated element in the gallery — one per day,
  pinned while you scroll past it.
- **Metric:** day header at 3.1× text with the longest real label
  ("14 JUN 2024" — `dateLabel` emits the year for other years): horizontal
  overflow **24px → 0**, and the label no longer clips vertically in the bar.
  Breakpoint configurations under test: 80 → 104. Ordinary sizes unchanged,
  asserted: at ≤1.3× the bar is still exactly 30pt, which the grid's pinned
  headers are laid out against.
- **Verification:** `flutter analyze` 0 issues · `flutter test` 202/202 (24
  new) · `flutter build ios --simulator` ✓. Diff: +26/−12
  `gallery_viewer.dart` (two seams + the header fix), test +110.
- **Guide pill:** tested in its real slot (screen width − 96pt, the back
  button and its balancing spacer) with the longest mode name, at every text
  size. It holds — no fix needed, so those 16 configurations are a regression
  guard.
- **Commit:** `overnight: pass #22 — compatibility — 2026-09-09T14:42:30+0100`
