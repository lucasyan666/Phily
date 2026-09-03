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
    tip: 'Landscapes & seascapes.',
    orientation: CompoOrientation.landscape,
    how:
        'Line the moving line up with the gold one, then straighten your phone until it glows and buzzes. That buzz means you\'re level — shoot.',
    what:
        'A real spirit level, read from your phone\'s motion sensors rather than the picture. The gold line marks the height a horizon sits best at.',
  ),
  CompositionSpec(
    mode: CompositionMode.ruleOfThirds,
    label: 'Rule of Thirds',
    tip: 'Everyday shots — people, street, travel.',
    orientation: CompoOrientation.both,
    powerPoints: kThirdsPoints,
    how:
        'Park your subject on any dot instead of the middle. Move closer and the dot lights up — when it clicks, you\'ve nailed it. Shooting a person? Rest their eyes on the top line.',
    what:
        'The frame split in thirds. Those four crossings are where a subject sits most comfortably — off-centre reads as composed, dead-centre reads as a snapshot.',
  ),
  CompositionSpec(
    mode: CompositionMode.goldenSection,
    label: 'Phi Grid',
    tip: 'Portraits & fine-art landscapes.',
    orientation: CompoOrientation.portrait,
    powerPoints: kPhiPoints,
    how:
        'Use it exactly like thirds — subject on a dot. These dots just sit a little closer in. Reach for it when thirds pushes your subject too far to the edge.',
    what:
        'Thirds\' more refined cousin: the lines fall on the golden ratio (1 : 0.618) instead of even thirds, for a calmer, more classical frame.',
  ),
  CompositionSpec(
    mode: CompositionMode.goldenTriangles,
    label: 'Golden Triangles',
    tip: 'Roads, stairs, reclining poses.',
    orientation: CompoOrientation.landscape,
    controls: {CompoControl.flip},
    how:
        'Lay the strongest line in your scene — a road, a staircase, someone lying down — along the long diagonal. Put your subject where the short lines meet it. If the slope runs the other way, hit flip.',
    what:
        'A diagonal with two perpendiculars dropped onto it, cutting the frame into balanced triangles. Built for scenes whose energy runs on a slope.',
  ),
  CompositionSpec(
    mode: CompositionMode.fibonacciSpiral,
    label: 'Fibonacci Spiral',
    tip: 'Rivers, paths, shells.',
    orientation: CompoOrientation.landscape,
    controls: {CompoControl.flip, CompoControl.turn},
    how:
        'Put the most important thing at the tight little eye of the spiral. Then let a river, a path or a curl of hair sweep along the curve into it. Flip and turn move the eye to whichever corner your subject is in.',
    what:
        'The golden spiral, drawn from the golden ratio. Follow its curve and a viewer\'s eye travels the whole photo in one sweep, landing where you want it.',
  ),
  CompositionSpec(
    mode: CompositionMode.cross,
    label: 'Cross',
    tip: 'Reflections & formal architecture.',
    orientation: CompoOrientation.portrait,
    how:
        'Centre your subject on the upright, then drag the crossbar down to your horizon or eye-line. Want it at an angle? Grab the glowing handle and twist — it clicks at every quarter turn.',
    what:
        'A centred upright with a crossbar you place yourself: formal symmetry, plus one deliberate counterpoint where you want it.',
  ),
  CompositionSpec(
    mode: CompositionMode.focalMass,
    label: 'Focal Mass',
    tip: 'Minimalism — one subject, lots of space.',
    // No turn button — the cluster now follows the phone into landscape.
    orientation: CompoOrientation.both,
    how:
        'Fill the cluster with your one subject, then leave everything else out. Resist the urge to add more — the empty space is doing the work. Turn to landscape and the cluster comes with you.',
    what:
        'A marker for where your single subject should carry its weight, with everything around it left deliberately empty.',
  ),
  CompositionSpec(
    mode: CompositionMode.vArrangement,
    label: 'V Arrangement',
    tip: 'Group portraits & valleys.',
    orientation: CompoOrientation.portrait,
    controls: {CompoControl.flip},
    how:
        'Line your scene\'s converging edges up with the two arms and put the important thing at the point where they meet. Shooting a mountain or a rooftop instead? Flip it into a peak.',
    what:
        'Two lines meeting in a V — the shape of valleys, crowds falling away, and a well-arranged group. It funnels attention to one spot.',
  ),
  CompositionSpec(
    mode: CompositionMode.diagonal,
    label: 'Diagonal',
    tip: 'Motion — street & action.',
    orientation: CompoOrientation.landscape,
    controls: {CompoControl.turn},
    how:
        'Run the movement — a street, a long shadow, someone running — along one of the diagonals, starting from the corner they fan out of. Tap turn to move that corner.',
    what:
        'Diagonals from one corner. They read as movement, where flat horizontals read as stillness — the liveliest line a photo can hold.',
  ),
  CompositionSpec(
    mode: CompositionMode.radial,
    label: 'Radial',
    tip: 'Flowers, wheels, tunnels.',
    orientation: CompoOrientation.both,
    how:
        'Find the middle of your subject — the centre of the flower, the hub of the wheel — and drop it where the spokes meet. Let the petals or steps run outward along the lines.',
    what:
        'Spokes from a centre point, for anything that blooms outward from a hub.',
  ),
  CompositionSpec(
    mode: CompositionMode.lArrangement,
    label: 'L Arrangement',
    tip: 'Product shots & still life.',
    orientation: CompoOrientation.both,
    controls: {CompoControl.flip, CompoControl.turn},
    how:
        'Tuck your subject into the corner of the L and keep the open side clear. Don\'t move the plate — use flip and turn to walk the corner around to wherever your subject already sits.',
    what:
        'An L bracing one corner: the subject nestles in it while space opens out the other way. The classic still-life setup.',
  ),
  CompositionSpec(
    mode: CompositionMode.compoundCurve,
    label: 'Compound Curve',
    tip: 'Winding rivers & roads.',
    orientation: CompoOrientation.landscape,
    how:
        'Let the winding thing in your scene follow the S, starting near your feet and disappearing into the distance. Anything worth noticing goes on one of the two bends.',
    what:
        'The S-curve of rivers, mountain roads and the human figure — the gentlest way to walk an eye from the front of a photo to the back.',
  ),
  CompositionSpec(
    mode: CompositionMode.pyramid,
    label: 'Pyramid',
    tip: 'Groups, mountains, still life.',
    orientation: CompoOrientation.landscape,
    how:
        'Build inside the triangle: tallest thing at the peak — a head, a summit — and everything else spread along the wide base. Keep the corners outside it empty.',
    what:
        'A triangle sitting on the frame\'s base. It\'s the most stable shape there is, which is why mountains and group portraits have used it for centuries.',
  ),
  CompositionSpec(
    mode: CompositionMode.circular,
    label: 'Circular',
    tip: 'Plates of food & round subjects.',
    orientation: CompoOrientation.both,
    how:
        'Fill the circle with your plate, wreath or huddle of faces. Shoot straight on — directly overhead for food — and keep the corners clear.',
    what:
        'A centred circle for round subjects. Circles hold the eye inside the frame rather than leading it off the edge.',
  ),
  CompositionSpec(
    mode: CompositionMode.symmetry,
    label: 'Symmetry',
    tip: 'Reflections, faces, doorways.',
    orientation: CompoOrientation.portrait,
    how:
        'Put the middle of your scene right on the line — the waterline of a reflection, the centre of a face or doorway — then square up to it so both halves really do match.',
    what:
        'One centre line for mirror-image scenes. This is the rare case where centring beats going off-centre.',
  ),
  CompositionSpec(
    mode: CompositionMode.aspectRatio,
    label: 'Aspect Ratio',
    tip: 'Framing for social or print.',
    controls: {CompoControl.aspectCycle},
    how:
        'Tap the ratio button until you get the shape you want, then compose inside the bright part. The dimmed strips are what gets cut.',
    what:
        'Crop guides for wherever the photo ends up — square, 4:5, 16:9. Framing it right now beats cropping it later.',
  ),
];

/// Fast lookup by mode. Every [CompositionMode] is present in [kCompositionSpecs],
/// so `kCompositionByMode[mode]!` is always safe.
final Map<CompositionMode, CompositionSpec> kCompositionByMode = {
  for (final s in kCompositionSpecs) s.mode: s,
};
