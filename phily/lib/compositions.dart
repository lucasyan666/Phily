part of 'camera_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Composition registry
//
// One source of truth for each composition's *presentational* metadata — its
// name, the "best for" tip, the orientation hint, which turn/flip controls it
// exposes, and (where fixed) its alignment power points. The camera page reads
// this list instead of maintaining several parallel switch statements, so adding
// or tuning a mode is a one-line edit in one place.
//
// Geometry that has to be *computed* stays in code: the actual line/curve/scrim
// drawing lives in _CompositionPainter, and runtime targets (e.g. the Fibonacci
// spiral's eye, which depends on the measured band + turn count) are derived in
// _modePowerPoints. Only device-independent *ratios* belong here as data.
// ─────────────────────────────────────────────────────────────────────────────

/// Which way to hold the phone for a mode — surfaced as the little chip beside
/// the "best for" tip.
enum CompoOrientation {
  none,
  portrait,
  landscape,
  both;

  /// The chip text, or null when the hint doesn't apply (e.g. Aspect Ratio).
  String? get label => switch (this) {
    CompoOrientation.portrait => 'Portrait',
    CompoOrientation.landscape => 'Landscape',
    CompoOrientation.both => 'Both',
    CompoOrientation.none => null,
  };
}

/// A control a mode offers in the camera's right-hand slot.
enum CompoControl { turn, flip, aspectCycle }

/// The templatable definition of a single composition mode. Everything the page
/// needs to *present* the mode, with no drawing code — see the file header.
class CompositionSpec {
  final CompositionMode mode;

  /// Display name (belt label + mode readout).
  final String label;

  /// "Best for" blurb shown briefly on selection; null → no bubble for this mode.
  final String? tip;

  /// Recommended hold, shown as a chip beside the tip.
  final CompoOrientation orientation;

  /// Which turn/flip/cycle controls this mode exposes. Drives the right-hand slot.
  final Set<CompoControl> controls;

  /// Fixed alignment targets (band fractions), for modes whose power points are
  /// constant. Null when the mode has no alignment or computes it at runtime.
  final List<List<double>>? powerPoints;

  const CompositionSpec({
    required this.mode,
    required this.label,
    this.tip,
    this.orientation = CompoOrientation.none,
    this.controls = const {},
    this.powerPoints,
  });
}

// Fixed alignment power points (band fractions). Single source, referenced both
// by the specs below and by the page's alignment fallback.
const List<List<double>> kThirdsPoints = [
  [1 / 3, 1 / 3],
  [2 / 3, 1 / 3],
  [1 / 3, 2 / 3],
  [2 / 3, 2 / 3],
];
// Phi-Grid intersections at 1/φ² ≈ 0.382 and 1/φ ≈ 0.618.
const double _kPhiLo = 0.3819660113;
const double _kPhiHi = 0.6180339887;
const List<List<double>> kPhiPoints = [
  [_kPhiLo, _kPhiLo],
  [_kPhiHi, _kPhiLo],
  [_kPhiLo, _kPhiHi],
  [_kPhiHi, _kPhiHi],
];

/// Every composition, in no particular display order (the belt order lives in
/// [_CameraPageState._compositionModes]). Look up by mode via [kCompositionByMode].
const List<CompositionSpec> kCompositionSpecs = [
  CompositionSpec(mode: CompositionMode.none, label: 'None'),
  CompositionSpec(
    mode: CompositionMode.horizonGrid,
    label: 'Horizon Grid',
    tip:
        'Landscapes & seascapes — a true gravity level. Hold your phone completely straight to level the horizon.',
    orientation: CompoOrientation.landscape,
  ),
  CompositionSpec(
    mode: CompositionMode.ruleOfThirds,
    label: 'Rule of Thirds',
    tip:
        'Everyday shots — people, landscapes, street. Put your subject on a dot.',
    orientation: CompoOrientation.both,
    powerPoints: kThirdsPoints,
  ),
  CompositionSpec(
    mode: CompositionMode.goldenSection,
    label: 'Phi Grid',
    tip: 'Portraits & fine-art landscapes — subject a touch more central.',
    orientation: CompoOrientation.portrait,
    powerPoints: kPhiPoints,
  ),
  CompositionSpec(
    mode: CompositionMode.goldenTriangles,
    label: 'Golden Triangles',
    tip: 'Scenes with strong diagonals — roads, stairs, reclining poses.',
    orientation: CompoOrientation.landscape,
    controls: {CompoControl.flip},
  ),
  CompositionSpec(
    mode: CompositionMode.fibonacciSpiral,
    label: 'Fibonacci Spiral',
    tip: 'Flowing scenes — rivers, paths, shells. Lead the eye to the centre.',
    orientation: CompoOrientation.landscape,
    controls: {CompoControl.flip, CompoControl.turn},
  ),
  CompositionSpec(
    mode: CompositionMode.cross,
    label: 'Cross',
    tip: 'Symmetrical, centred subjects — reflections, formal architecture.',
    orientation: CompoOrientation.portrait,
  ),
  CompositionSpec(
    mode: CompositionMode.focalMass,
    label: 'Focal Mass',
    tip: 'One dominant subject against negative space — minimalism.',
    // No turn button — the cluster now follows the phone into landscape.
    orientation: CompoOrientation.both,
  ),
  CompositionSpec(
    mode: CompositionMode.vArrangement,
    label: 'V Arrangement',
    tip: 'Group portraits, valleys, converging lines.',
    orientation: CompoOrientation.portrait,
    controls: {CompoControl.flip},
  ),
  CompositionSpec(
    mode: CompositionMode.diagonal,
    label: 'Diagonal',
    tip: 'Energy & motion — street, action, leading lines.',
    orientation: CompoOrientation.landscape,
    controls: {CompoControl.turn},
  ),
  CompositionSpec(
    mode: CompositionMode.radial,
    label: 'Radial',
    tip: 'Flowers, wheels, sunbursts, tunnels, spiral staircases.',
    orientation: CompoOrientation.both,
  ),
  CompositionSpec(
    mode: CompositionMode.lArrangement,
    label: 'L Arrangement',
    tip: 'Product & still life — frame a subject in a corner.',
    orientation: CompoOrientation.both,
    controls: {CompoControl.flip, CompoControl.turn},
  ),
  CompositionSpec(
    mode: CompositionMode.compoundCurve,
    label: 'Compound Curve',
    tip: 'Winding rivers & roads, the S-curve of the figure.',
    orientation: CompoOrientation.landscape,
  ),
  CompositionSpec(
    mode: CompositionMode.pyramid,
    label: 'Pyramid',
    tip: 'Groups of people, mountains, stable still life.',
    orientation: CompoOrientation.landscape,
  ),
  CompositionSpec(
    mode: CompositionMode.circular,
    label: 'Circular',
    tip: 'Round plates of food, groups in a circle, round subjects.',
    orientation: CompoOrientation.both,
  ),
  CompositionSpec(
    mode: CompositionMode.symmetry,
    label: 'Symmetry',
    tip: 'Reflections, faces, doorways — centre on the line.',
    orientation: CompoOrientation.portrait,
  ),
  CompositionSpec(
    mode: CompositionMode.aspectRatio,
    label: 'Aspect Ratio',
    tip: 'Frame for social or print — tap to cycle 1:1 · 4:5 · 16:9.',
    controls: {CompoControl.aspectCycle},
  ),
];

/// Fast lookup by mode. Every [CompositionMode] is present in [kCompositionSpecs],
/// so `kCompositionByMode[mode]!` is always safe.
final Map<CompositionMode, CompositionSpec> kCompositionByMode = {
  for (final s in kCompositionSpecs) s.mode: s,
};
