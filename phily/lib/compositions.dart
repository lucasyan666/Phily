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

  /// Guide copy — the principle behind the overlay ("what it is")…
  final String? what;

  /// …and how to actually shoot with it (concrete steps, including the mode's
  /// flip/turn controls where it has them). Both shown in the guide sheet.
  final String? how;

  const CompositionSpec({
    required this.mode,
    required this.label,
    this.tip,
    this.orientation = CompoOrientation.none,
    this.controls = const {},
    this.powerPoints,
    this.what,
    this.how,
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
    what:
        'A gravity-true level. The gold guide marks the ideal horizon height (just above the golden section), and the moving line is your phone\'s actual tilt — measured by the sensors, not guessed from the picture.',
    how:
        'Bring the moving line up to the gold guide, then tilt until the dial reads level — it locks with a glow and a pulse when you\'re straight. Works in any hold: the guide follows your phone\'s rotation.',
  ),
  CompositionSpec(
    mode: CompositionMode.ruleOfThirds,
    label: 'Rule of Thirds',
    tip:
        'Everyday shots — people, landscapes, street. Put your subject on a dot.',
    orientation: CompoOrientation.both,
    powerPoints: kThirdsPoints,
    what:
        'The frame divided into thirds. The four intersections are power points — the places where a subject feels naturally balanced instead of bull\'s-eyed in the centre.',
    how:
        'Put your subject — a face, an eye, the horizon — on any intersection. Phily tracks faces and pets live: the point glows as you close in and clicks at Perfect. For portraits, rest the eyes on the top line.',
  ),
  CompositionSpec(
    mode: CompositionMode.goldenSection,
    label: 'Phi Grid',
    tip: 'Portraits & fine-art landscapes — subject a touch more central.',
    orientation: CompoOrientation.portrait,
    powerPoints: kPhiPoints,
    what:
        'The Rule of Thirds\' refined sibling: the lines sit at the golden ratio (1 : 0.618), pulling the power points a touch toward the centre — calmer, more classical framing.',
    how:
        'Compose exactly as you would with thirds, but let the subject sit slightly more central. Reach for it when thirds feels too far off-centre — especially for portraits and fine-art landscapes.',
  ),
  CompositionSpec(
    mode: CompositionMode.goldenTriangles,
    label: 'Golden Triangles',
    tip: 'Scenes with strong diagonals — roads, stairs, reclining poses.',
    orientation: CompoOrientation.landscape,
    controls: {CompoControl.flip},
    what:
        'A corner-to-corner diagonal with two perpendiculars dropped onto it, carving the frame into harmonious triangles — built for scenes whose energy runs along a slope.',
    how:
        'Lay your scene\'s strongest line — a road, a staircase, a reclining figure — along the main diagonal, and place the subject where a perpendicular meets it. Flip mirrors the set to match your scene\'s direction.',
  ),
  CompositionSpec(
    mode: CompositionMode.fibonacciSpiral,
    label: 'Fibonacci Spiral',
    tip: 'Flowing scenes — rivers, paths, shells. Lead the eye to the centre.',
    orientation: CompoOrientation.landscape,
    controls: {CompoControl.flip, CompoControl.turn},
    what:
        'The golden spiral, unwound from the golden ratio. A scene arranged along its curve leads the viewer\'s eye on one natural sweep that lands on the spiral\'s eye.',
    how:
        'Put what matters most at the eye of the spiral, and let leading lines — a river, a path, a curl of hair — follow the curve toward it. Use flip and turn to aim the eye at your subject\'s side of the frame.',
  ),
  CompositionSpec(
    mode: CompositionMode.cross,
    label: 'Cross',
    tip: 'Symmetrical, centred subjects — reflections, formal architecture.',
    orientation: CompoOrientation.portrait,
    what:
        'A centred vertical with a movable, rotatable crossbar — formal symmetry with one strong counterpoint you position yourself.',
    how:
        'Centre your subject on the vertical arm, then drag the crossbar to your horizon or eye-line. Grab the glowing handle to rotate the whole cross — it clicks into place at every quarter turn.',
  ),
  CompositionSpec(
    mode: CompositionMode.focalMass,
    label: 'Focal Mass',
    tip: 'One dominant subject against negative space — minimalism.',
    // No turn button — the cluster now follows the phone into landscape.
    orientation: CompoOrientation.both,
    what:
        'A gathered cluster marking where your single subject should hold its visual weight — everything outside it stays deliberate, empty negative space.',
    how:
        'Fill the cluster with your subject and resist putting anything else in the frame. The emptiness is the point. The cluster follows your phone when you turn to landscape.',
  ),
  CompositionSpec(
    mode: CompositionMode.vArrangement,
    label: 'V Arrangement',
    tip: 'Group portraits, valleys, converging lines.',
    orientation: CompoOrientation.portrait,
    controls: {CompoControl.flip},
    what:
        'Two lines converging in a V — the shape of valleys, receding crowds and well-arranged group portraits, funnelling attention to a single point.',
    how:
        'Let your scene\'s converging lines follow the V\'s arms, with the key subject at its point. Flip turns the V into a peak (∧) for mountains, rooflines and standing groups.',
  ),
  CompositionSpec(
    mode: CompositionMode.diagonal,
    label: 'Diagonal',
    tip: 'Energy & motion — street, action, leading lines.',
    orientation: CompoOrientation.landscape,
    controls: {CompoControl.turn},
    what:
        'A fan of diagonals springing from one corner — the most energetic line a frame can carry. Diagonals read as motion; horizontals read as rest.',
    how:
        'Run the movement of your scene — a street, a shadow, a sprinter — along one of the diagonals, entering from the fan\'s corner. Turn cycles which corner the fan springs from.',
  ),
  CompositionSpec(
    mode: CompositionMode.radial,
    label: 'Radial',
    tip: 'Flowers, wheels, sunbursts, tunnels, spiral staircases.',
    orientation: CompoOrientation.both,
    what:
        'Spokes radiating from the centre — for subjects that bloom outward from a hub: flowers, wheels, tunnels, staircases seen from above.',
    how:
        'Centre your subject\'s hub where the spokes meet, then let its structure — petals, spokes, steps — follow the lines outward to the edges.',
  ),
  CompositionSpec(
    mode: CompositionMode.lArrangement,
    label: 'L Arrangement',
    tip: 'Product & still life — frame a subject in a corner.',
    orientation: CompoOrientation.both,
    controls: {CompoControl.flip, CompoControl.turn},
    what:
        'An L bracing one corner — the still-life arrangement: the subject sits in the corner\'s embrace while space flows out of the open side.',
    how:
        'Sit your subject inside the L\'s corner and keep the open side clean and uncluttered. Flip and turn walk the corner around the frame to wherever your subject already is.',
  ),
  CompositionSpec(
    mode: CompositionMode.compoundCurve,
    label: 'Compound Curve',
    tip: 'Winding rivers & roads, the S-curve of the figure.',
    orientation: CompoOrientation.landscape,
    what:
        'The S-curve — the line of winding rivers, mountain roads and the human figure. It is the gentlest way to lead an eye through a photograph, front to back.',
    how:
        'Let the winding element of your scene trace the S from foreground into the distance, and place points of interest on the curve\'s two bends.',
  ),
  CompositionSpec(
    mode: CompositionMode.pyramid,
    label: 'Pyramid',
    tip: 'Groups of people, mountains, stable still life.',
    orientation: CompoOrientation.landscape,
    what:
        'A triangle standing on the frame\'s base — the most stable shape in composition, and the classical arrangement for mountains, monuments and grouped portraits.',
    how:
        'Build your scene inside the triangle: the peak takes the head, summit or tallest element; the wide base grounds the group. Keep the corners outside it quiet.',
  ),
  CompositionSpec(
    mode: CompositionMode.circular,
    label: 'Circular',
    tip: 'Round plates of food, groups in a circle, round subjects.',
    orientation: CompoOrientation.both,
    what:
        'A centred circle — for round subjects and scenes that gather around a middle. Circles hold the eye inside the frame instead of leading it out.',
    how:
        'Fill the circle with your plate, wreath or huddle of faces, shooting square-on (top-down for food). Keep the corners quiet so the ring stays the story.',
  ),
  CompositionSpec(
    mode: CompositionMode.symmetry,
    label: 'Symmetry',
    tip: 'Reflections, faces, doorways — centre on the line.',
    orientation: CompoOrientation.portrait,
    what:
        'A single centre line for mirror-image scenes. Perfect symmetry is one of the few times centring a subject is stronger than off-setting it.',
    how:
        'Put the axis of your scene exactly on the line — the water\'s edge of a reflection, the midline of a face or doorway — and square your phone to the subject so both halves truly mirror.',
  ),
  CompositionSpec(
    mode: CompositionMode.aspectRatio,
    label: 'Aspect Ratio',
    tip: 'Frame for social or print — tap to cycle 1:1 · 4:5 · 16:9.',
    controls: {CompoControl.aspectCycle},
    what:
        'Crop guides for the frames your photo will finally live in — square, portrait 4:5, cinematic 16:9 and more. Composing inside the crop beats cropping later.',
    how:
        'Tap the ratio button to cycle formats and compose inside the bright window — the dimmed strips are what the crop will trim away.',
  ),
];

/// Fast lookup by mode. Every [CompositionMode] is present in [kCompositionSpecs],
/// so `kCompositionByMode[mode]!` is always safe.
final Map<CompositionMode, CompositionSpec> kCompositionByMode = {
  for (final s in kCompositionSpecs) s.mode: s,
};
