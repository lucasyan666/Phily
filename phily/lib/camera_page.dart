import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:phily/debug.dart';
import 'package:flutter/physics.dart' show FrictionSimulation;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:gal/gal.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:phily/screens/branded_loader.dart';
import 'package:phily/screens/gallery_viewer.dart';
import 'package:phily/screens/paywall.dart';
import 'package:phily/services/phily_pro.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:phily/theme.dart';

part 'camera_overlays.dart';
part 'composition_guide.dart';
part 'compositions.dart';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with TickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isInitialized = false;
  bool _isRecording = false;
  // One-shot launch warm-up: paints the guide overlay's heavy draw variants
  // (grid + power-point / face / level-dial glow blurs) almost-invisibly for the
  // first ~1.2s, so Impeller compiles those pipelines at launch instead of on the
  // first guide-mode swipe (which otherwise hitches once).
  bool _warming = true;
  late final _FaceBox _warmFace = _FaceBox(0.5, 0.4, 0.25, 0.32, 0)
    ..opacity = 1.0
    ..appear = 1.0
    ..matched = true
    ..alignGlow = 1.0;
  final ValueNotifier<({double roll, double vert, bool level})?> _warmAttitude =
      ValueNotifier((roll: 0.06, vert: 0.12, level: true));
  final Stopwatch _recordingStopwatch = Stopwatch();
  Timer? _recordingTimer;
  Uint8List? _latestThumbnail;
  String? _error;
  // Photo-library permission, requested only once per session (cached). iOS
  // never re-prompts once decided, so the gallery/thumbnail paths reuse this.
  bool? _photoPermission;

  // Camera settings
  FlashMode _flashMode = FlashMode.off;
  ResolutionPreset _resolution = ResolutionPreset.veryHigh; // 24MP
  String _imageFormat = 'HEIF'; // HEIF or RAW
  CompositionMode _compositionMode = CompositionMode.none;
  // Quick toggle to dim the composition overlay for a clean frame (mode stays).
  bool _gridVisible = true;
  // Fibonacci-spiral orientation: number of 90° clockwise turns (0..3). Lets the
  // user point the spiral's eye at any corner. Resets when the mode is re-entered.
  int _spiralTurns = 0;
  // Fibonacci spiral: mirror horizontally (eye to the opposite side). Flip button.
  bool _spiralFlipped = false;
  // The spiral is always drawn a quarter-turn off the stored value, so it sits
  // in the rotated (landscape) orientation by default; the rotate button cycles
  // from there. Used for both the painter and the alignment eye so they match.
  int get _spiralTurnsEffective => (_spiralTurns + 1) & 3;
  // Animates the spiral's 90° orientation flip: a quick opacity + scale dip whose
  // trough hides the snap. The orientation swaps when the dip bottoms out.
  // Shared guide-flip transition for the spiral + triangle flip buttons: a quick
  // fade-out / swap-at-the-trough / fade-in. Only one of those modes is ever
  // active, so a single controller serves both.
  AnimationController? _gridFlipController;
  bool _gridFlipSwapped = false;
  VoidCallback? _gridFlipSwap; // the state change to apply at the fade's trough
  // Golden Triangles: flip the set across the vertical axis (TL→BR ↔ TR→BL) —
  // the old "Harmonious Triangles" mode is just this mirror. Toggled by a button.
  bool _trianglesFlipped = false;
  // V-Arrangement: flip the V upside-down (V ↔ ∧). Toggled by its flip button.
  bool _vFlipped = false;
  // Diagonal orientation: 90° clockwise turns (0..3), cycled by its turn button.
  int _diagonalTurns = 0;
  // L-Arrangement: 90° turns (0..3) + horizontal mirror, via turn + flip buttons.
  int _lTurns = 0;
  bool _lFlipped = false;
  // Focal Mass orientation: 90° clockwise turns (0..3), cycled by its turn
  // button. Shares the grid-flip fade so the cluster vanishes + rebuilds.
  int _focalTurns = 0;
  // Cross composition: crossbar height as a fraction of the frame, dragged via
  // the cross slider within the fixed vertical-arm track.
  double _crossY = kCrossDefaultY; // rendered (eased toward target)
  double _crossYTarget = kCrossDefaultY; // slider-driven target
  bool _slidingCross = false; // crossbar slider currently dragged
  int _slideNotch = 0; // last notch crossed (for slide haptic ticks)
  // Cross rotation (radians) about the vertical arm's centre — driven by the
  // glowing rotate handle at the arm tip.
  double _crossAngle = 0; // rendered angle (eased toward target)
  double _crossAngleTarget = 0; // finger-driven target
  double _crossGlow = 0; // selection glow 0..1 (eased)
  bool _rotatingCross = false; // handle currently grabbed
  int _lastDetent = 0; // last 90° step crossed (for haptic ticks)
  bool _crossWasStuck = false; // in a detent band last tick (edge detection)
  // Rendered cross state, pushed by the 60fps easing ticker. A ValueNotifier so
  // each tick repaints only the guide painter + the two small cross controls —
  // a setState here used to rebuild the ENTIRE camera Stack every frame while
  // the cross was dragged or still settling.
  final ValueNotifier<({double y, double angle, double glow})> _crossN =
      ValueNotifier((y: kCrossDefaultY, angle: 0.0, glow: 0.0));
  // How far below the vertical-arm tip the rotate handle sits (px). Keeps the
  // grip clear of the arm and a little lower on screen.
  static const double _kCrossHandleDrop = 22;
  // Ticker that eases the spin + glow each frame while the handle is in use.
  late final AnimationController _crossSpinCtl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..addListener(_tickCrossSpin);
  // Repaint clock for the Focal Mass bubble animation. Repeats only while Focal
  // Mass is active, so it costs nothing in other modes. `late final` (not
  // initState) so it also comes up on a hot reload, not only a full restart.
  late final AnimationController _focalAnim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  // Aspect Ratio mode: selected crop ratio. Cycled by a button in that mode.
  static const List<({String label, double ratio})> _aspectRatios = [
    (label: '1:1', ratio: 1.0),
    (label: '4:5', ratio: 4 / 5),
    (label: '16:9', ratio: 16 / 9),
  ];
  int _aspectIndex = 2; // default 16:9
  // "Best for" tip bubble shown briefly when the composition mode changes.
  bool _showTip = false;
  Timer? _tipTimer;
  // Drives the tip's entrance/exit. Replayed from 0 on every show so the advice
  // always animates in cleanly — even switching straight from one mode to the
  // next (an AnimatedSwitcher would cross-fade in place and read as "no anim").
  late final AnimationController _tipAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
    reverseDuration: const Duration(milliseconds: 260),
  );
  // Composition belt order — most commonly used first, niche patterns last.
  static const List<CompositionMode> _compositionModes = [
    CompositionMode.none,
    CompositionMode.ruleOfThirds,
    CompositionMode.goldenSection, // Phi Grid
    CompositionMode.symmetry,
    CompositionMode.goldenTriangles,
    CompositionMode.fibonacciSpiral,
    CompositionMode.diagonal,
    CompositionMode.horizonGrid,
    CompositionMode.aspectRatio,
    CompositionMode.cross,
    CompositionMode.focalMass,
    CompositionMode.vArrangement,
    CompositionMode.lArrangement,
    CompositionMode.radial,
    CompositionMode.compoundCurve,
    CompositionMode.pyramid,
    CompositionMode.circular,
  ];
  late PageController _compositionPageController;
  int _currentCompositionIndex = 0;
  // Rule-of-Thirds hint level: 0 none, 1 "Almost" (subject's box on a point),
  // 2 "Perfect" (point near the box centre). A ValueNotifier so only the hint
  // rebuilds — never the whole Stack — even if it flip-flops near a threshold.
  final ValueNotifier<int> _alignLevel = ValueNotifier(0);

  // Composition grids are confined to the camera-visible area *between* the
  // top/bottom UI panels so the guide lines never bleed under the chrome. The
  // panel heights are measured from their laid-out render boxes after each
  // frame; they only change on orientation/safe-area shifts, so this settles
  // once and stays put.
  final GlobalKey _topPanelKey = GlobalKey();
  final GlobalKey _bottomPanelKey = GlobalKey();
  double _topInset = 0, _bottomInset = 0;
  // Same insets as a fraction of full screen height. Used to remap the Rule-of-
  // Thirds power points (which now live in the band) into the full-screen-
  // normalised space the detected face boxes are expressed in.
  double _topInsetFrac = 0, _bottomInsetFrac = 0;
  // Camera-visible band size (px). Needed to compute the Fibonacci-spiral eye,
  // whose position depends on the band's aspect ratio.
  double _bandW = 0, _bandH = 0;

  // Tap-to-focus + exposure + AE/AF lock
  Offset? _focusPoint;
  AnimationController? _focusRingController;
  late Animation<double> _focusRingScale;
  bool _focusShown = false; // drives the focus/exposure UI fade
  Timer? _focusHideTimer; // auto-hides the focus UI when idle
  bool _aeAfLocked = false;
  double _exposureOffset = 0; // current EV offset
  // Mirrors _exposureOffset for the EV slider readout — same reasoning as
  // [_zoomN]: the drag updates only the slider, not the whole page.
  final ValueNotifier<double> _evN = ValueNotifier(0);
  double _minExposure = 0, _maxExposure = 0; // device EV range

  // Zoom
  double _currentZoom = 1.0;
  // Mirrors _currentZoom for display. The zoom meter/labels listen to this, so
  // a pinch or meter drag repaints only those few widgets — the old setState
  // per pointer move rebuilt the whole camera Stack at gesture rate.
  final ValueNotifier<double> _zoomN = ValueNotifier(1.0);
  double _baseZoom = 1.0;
  int _lastZoomTick = 5; // 1.0× / 0.2 — last 0.2× step that fired a haptic
  double _lastFeltZoom = 1.0; // previous zoom seen by the feel dispatcher
  bool _zoomAtStop = false; // debounce: one thud per visit to a range end
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  // Lens mode for the zoom bar: false → normal (1.0×–25×), true → ultra-wide
  // (0.5×–1.0×). A small switch on the meter flips between them.
  bool _ultraZoomMode = false;
  bool get _hasUltraWide => _ultraWideCamera != null || _minZoom < 0.99;
  double get _zoomLo => _ultraZoomMode ? 0.5 : 1.0;
  // Ultra-wide tops out JUST under 1.0×: at exactly 1.0 the camera switches
  // back to the main lens (a jarring controller swap mid-scrub). The readout
  // caps at 0.9× (see _zoomLabel) so it never shows a misleading "1.0×".
  double get _zoomHi => _ultraZoomMode ? 0.99999 : _zoomMax;

  // ── Zoom belt "feel" ─────────────────────────────────────────────────────
  // Readout pop on labelled stops, tick-wheel swell while a finger is down,
  // coasting fling on release, and the dial-density morph between lens modes.
  // All notifier/painter-driven — none of these rebuild the page per frame.
  late final AnimationController _readoutPop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final AnimationController _beltEngage = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final AnimationController _zoomFling = AnimationController.unbounded(
    vsync: this,
  )..addListener(_onZoomFling);
  late final AnimationController _dialMorph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1.0,
  );
  double _pxFrom = 36.0, _pxTo = 36.0;

  /// The belt's live px-per-zoom-unit — tweened between lens modes (36 on the
  /// 1–25× belt, 320 on the 0.5 dial) so the tick wheel visibly stretches /
  /// compresses instead of snapping density.
  double get _beltPxNow =>
      ui.lerpDouble(_pxFrom, _pxTo, kEaseOut.transform(_dialMorph.value))!;

  // Swipe-to-switch-composition tracking (single-finger horizontal swipe on the
  // preview). Kept separate from pinch-zoom via the max-pointer-count check.
  double _swipeStartX = 0, _swipeStartY = 0, _swipeLastX = 0, _swipeLastY = 0;
  int _swipeMaxPointers = 0;
  // Cached "All" album + count so the gallery opens instantly on swipe/tap — no
  // async query between the gesture and the slide-up. Pre-warmed by
  // _loadLatestThumbnail (and refreshed each time we return from the gallery).
  AssetPathEntity? _galleryAlbum;
  int _galleryCount = 0;
  // Zoom meter drag state
  static const double _zoomMax = 25.0;
  double _meterDragStart = 0.0;
  double _zoomAtDragStart = 1.0;
  // When on ultra-wide: physicalZoom = logicalZoom × _ultraWideScaleFactor.
  // The ultra-wide sensor's native FOV = 0.5× logical, so factor = minPhysical / 0.5.
  double _ultraWideScaleFactor = 2.0;
  CameraDescription? _ultraWideCamera;
  bool _isUsingUltraWide = false;
  bool _isSwitchingLens = false;
  bool _usesVirtualCamera = false;
  // Cached ultra-wide zoom range from the pre-warm probe.
  // Avoids a second getMinZoomLevel() call at switch time.
  double? _uwCachedMinZoom;
  double? _uwCachedMaxZoom;
  // Zoom levels where iOS transitions between physical lenses.
  // Received from native getZoomInfo once on init. Used to accent
  // the tick marks on the zoom meter (like the native Camera app).
  List<double> _switchoverFactors = const [];

  // Capture "float then fly" animation.
  AnimationController? _bounceController;
  File? _animatingMedia;
  bool _showBounceAnimation = false;
  bool _showShutterFlash = false;

  // Animation for button recording effects
  AnimationController? _buttonBopController;
  Animation<double>? _buttonBopAnimation;
  AnimationController? _glowController;
  Animation<double>? _glowAnimation;

  // Composition alignment detection — per-segment glow
  // Key: normalised 'x1,y1,x2,y2'. Value: _GlowSeg with mutable intensity.
  final Map<String, _GlowSeg> _glowSegMap = {};
  bool _isProcessingFrame = false;
  DateTime _lastFrameTime = DateTime.fromMillisecondsSinceEpoch(0);
  // Throttle the (expensive) multi-rotation face-detection re-probe so a scene
  // with no face (landscape/street) doesn't pay 4 synchronous rotations/frame.
  // When a face was tracked recently the probe runs every frame instead, so we
  // re-acquire instantly (stable tracking); the throttle only bites once the
  // scene has genuinely had no face for a while.
  int _lastProbeMs = 0;
  int _lastFaceMs = 0;
  // Throttle the per-frame animal (cat/dog) Vision call; the box's grace window
  // keeps it steady between detections, so this is invisible but saves a native
  // request on roughly half the frames.
  int _lastAnimalMs = 0;
  List<Map<String, dynamic>> _lastAnimalDets = const [];

  // Experimental (None mode): show detected eye landmarks, to validate eye
  // tracking before wiring it into the subject modes. Preview-normalised points.
  final List<Offset> _eyePoints = [];
  final ValueNotifier<int> _eyeRepaint = ValueNotifier(0);

  // ML Kit face detector — runs on the CameraImage directly (no method-channel
  // image round trip), so detection latency is low enough for live tracking.
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableContours: false,
      enableLandmarks: true, // eyes (for the eye-placement key point)
      enableClassification: false,
      minFaceSize: 0.1,
    ),
  );

  // Downsample factor applied to camera frames before face detection. 3 = run
  // detection at a third resolution — far cheaper for ML Kit and the rotation
  // pass, with face proportions preserved. Raise for more FPS, lower (→2) if
  // small/distant faces start getting missed.
  static const int _detScale = 3;
  // Target long-side (px) of the downsampled detection buffer. For frames larger
  // than veryHigh (e.g. 48MP/max), the downsample factor is scaled to hit roughly
  // this size, so detection cost stays ~constant regardless of capture resolution.
  static const double _kDetTargetLong = 640;

  // Also detect cats/dogs (Apple Vision). Adds one native call per frame.
  static const bool _animalsEnabled = true;

  // Physical device orientation (the UI is portrait-locked, so we read the
  // accelerometer directly). Quarter-turns clockwise from portrait: 0/1/2/3.
  // Drives the ML Kit rotation + box back-mapping so detection works sideways.
  int _deviceTurns = 0;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  // ── Gyro dead-reckoning for detection tracking ─────────────────────────────
  // A camera pan moves every subject in the preview instantly, but detections
  // arrive several frames late — so boxes trailed the subject whenever the
  // phone moved. The gyroscope tells us exactly how the scene shifted:
  // integrate rotation rate → preview-normalised pan, then (1) the 60fps
  // ticker shifts boxes AND their targets by the pan each tick (real-time
  // follow), and (2) fresh detections are shifted by the pan accrued while
  // they were being processed (no backwards snap). Total pan since launch:
  double _panTotX = 0, _panTotY = 0;
  int _gyroLastUs = 0;
  // Ticker consumption mark + at-capture snapshot for in-flight detections.
  double _panTickX = 0, _panTickY = 0;
  double _panCapX = 0, _panCapY = 0;
  // Sign convention verified for the portrait-locked back-camera preview; if
  // a pan ever makes boxes overshoot double instead of following, flip these.
  static const double _kPanSignX = 1; // scene dx per +rate about device y
  static const double _kPanSignY = -1; // scene dy per +rate about device x

  void _startGyroListener() {
    _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen((e) {
          final int nowUs = DateTime.now().microsecondsSinceEpoch;
          final double dt = _gyroLastUs == 0 ? 0 : (nowUs - _gyroLastUs) / 1e6;
          _gyroLastUs = nowUs;
          if (dt <= 0 || dt > 0.2 || !mounted) return; // skip stalls/garbage
          // Effective half-FOVs of the on-screen preview at the current zoom
          // (zooming narrows the FOV → the same rotation pans more of it).
          final double tanV =
              math.tan(_vFovHalfRad > 0 ? _vFovHalfRad : 0.55) /
              _currentZoom.clamp(0.5, 25.0);
          final Size s = MediaQuery.sizeOf(context);
          final double tanH = tanV * (s.height > 0 ? s.width / s.height : 0.5);
          _panTotX += _kPanSignX * e.y * dt / (2 * tanH);
          _panTotY += _kPanSignY * e.x * dt / (2 * tanV);
        });
  }

  static const MethodChannel _cameraChannel = MethodChannel('phily/camera');
  static const MethodChannel _hapticsChannel = MethodChannel('phily/haptics');

  Future<void> _haptic(String type, {double intensity = 1.0}) async {
    try {
      await _hapticsChannel.invokeMethod(type, {'intensity': intensity});
    } catch (_) {}
  }

  /// Derives physical device orientation from the accelerometer (the UI is
  /// portrait-locked, so MediaQuery can't tell us). Updates [_deviceTurns]:
  /// 0 = portrait, 1 = landscape (rotated CW), 2 = upside-down, 3 = landscape (CCW).
  void _startOrientationListener() {
    _accelSub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((
      e,
    ) {
      // Low-pass the gravity vector → smooth, jitter-free roll/pitch for the
      // gravity-based horizon line. (Raw e.* is still used for orientation.)
      if (!_gravInit) {
        _gravX = e.x;
        _gravY = e.y;
        _gravZ = e.z;
        _gravInit = true;
      } else {
        const double a = 0.2;
        _gravX += (e.x - _gravX) * a;
        _gravY += (e.y - _gravY) * a;
        _gravZ += (e.z - _gravZ) * a;
      }

      // Use only in-plane gravity (x,y); ignore z (tilt toward/away from scene).
      final ax = e.x.abs(), ay = e.y.abs();
      // Need a clear dominant in-plane axis (hysteresis) to avoid flip-flopping
      // near 45°. Require the dominant axis to beat the other by a margin.
      const margin = 2.0;
      int? turns;
      if (ax > ay + margin) {
        turns = e.x > 0 ? 3 : 1; // landscape (two directions)
      } else if (ay > ax + margin) {
        turns = e.y > 0 ? 0 : 2; // portrait up / upside-down
      }
      if (turns != null && turns != _deviceTurns) {
        setState(() => _deviceTurns = turns!); // rebuild so UI controls rotate
        // Re-seed the gravity horizon at the new hold so its eased angle
        // snaps to the rotated frame instead of wobbling across the 90° jump.
        _hzInit = false;
      }

      // Drive the gravity horizon while Horizon Grid is active.
      if (_compositionMode == CompositionMode.horizonGrid) {
        _updateHorizonFromMotion();
      }
      // Drive the "hold it level" attitude dial (Horizon + the people modes).
      _updateLevelAttitude();
    });
  }

  /// Wraps a UI control so it rotates (smoothly) to stay upright for how the
  /// phone is physically held. The camera preview itself stays fixed.
  Widget _rotated(Widget child) => AnimatedRotation(
    turns: -_deviceTurns / 4,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
    child: child,
  );

  /// Like [_rotated], but also turns the control by [modelTurns] × 90° so a
  /// turn/flip button's arrow follows the orientation of the guide it controls.
  Widget _rotatedTurns(Widget child, int modelTurns) => AnimatedRotation(
    turns: -_deviceTurns / 4 + modelTurns / 4,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
    child: child,
  );

  void _onProChanged() {
    if (mounted) setState(() {});
    // Locking/unlocking changes whether the current mode detects → re-sync.
    _syncImageStream();
  }

  /// True when the active mode is gated — trial over + not subscribed (None is
  /// always free).
  bool get _modeLocked =>
      _compositionMode != CompositionMode.none && !PhilyPro.instance.isPro;

  /// Mode actually painted — a locked mode renders as None (no guide) until the
  /// user unlocks Phily Pro.
  CompositionMode get _paintedMode =>
      _modeLocked ? CompositionMode.none : _compositionMode;

  /// Debug-only sheet to flip the trial/subscription state for testing the lock.
  void _showProDebugMenu() {
    final pro = PhilyPro.instance;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161616),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                'DEBUG · isPro=${pro.isPro} · subscribed=${pro.subscribed} · '
                'trialLeft=${pro.trialDaysLeft}d',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.lock_rounded, color: Colors.white),
              title: const Text(
                'Expire trial — lock all',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                pro.debugSetSubscribed(false);
                pro.debugSetTrial(expired: true);
                Navigator.pop(sheetCtx);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.workspace_premium_rounded,
                color: kGold,
              ),
              title: const Text(
                'Grant Pro — open all',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                pro.debugSetSubscribed(true);
                Navigator.pop(sheetCtx);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _startOrientationListener();
    _startGyroListener();
    // Phily Pro: load the trial clock + wire the store; rebuild on entitlement
    // changes (trial expiry, purchase, restore) so locked modes gate live.
    PhilyPro.instance.init();
    PhilyPro.instance.addListener(_onProChanged);
    // Delay thumbnail loading to ensure permissions are ready
    Future.delayed(const Duration(milliseconds: 500), () {
      _loadLatestThumbnail();
    });
    // Initialize composition page controller
    _compositionPageController = PageController(
      initialPage: 0,
      viewportFraction: 0.28,
    );

    // Focus ring: a quick scale-in pop. Visibility/fade is driven by state +
    // a hide timer (see [_showFocusUI]) so the exposure slider can stay up while
    // you adjust it.
    _focusRingController = AnimationController(
      duration: const Duration(milliseconds: 260),
      vsync: this,
    );
    _focusRingScale = Tween(begin: 1.3, end: 1.0)
        .chain(CurveTween(curve: Curves.easeOutBack))
        .animate(_focusRingController!);

    // Capture animation: the shot flies straight into the gallery thumbnail.
    _bounceController = AnimationController(
      duration: const Duration(milliseconds: 620),
      vsync: this,
    );

    _bounceController!.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _showBounceAnimation = false;
          _animatingMedia = null;
        });
        _bounceController!.reset();
      }
    });

    // Initialize button bop animation (quick expand and contract)
    _buttonBopController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _buttonBopAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.15,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.15,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 60,
      ),
    ]).animate(_buttonBopController!);

    // Initialize glow animation (pulsing effect during recording)
    _glowController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _glowAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _glowController!, curve: Curves.easeInOut),
    );

    _glowController!.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _glowController!.reverse();
      } else if (status == AnimationStatus.dismissed) {
        if (_isRecording) {
          _glowController!.forward();
        }
      }
    });

    // Drives the 60fps easing/fade of face-detection boxes. The duration is
    // arbitrary (it just repeats as a frame clock); _tickFaceBoxes uses real dt.
    _faceAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_tickFaceBoxes);

    // Warm the guide-overlay render pipelines during launch, then drop the
    // (almost-invisible) warm-up overlay.
    Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _warming = false);
    });

    // Guide-flip transition (spiral + triangles). The change is applied at the
    // fade's trough (~halfway), where the guide is invisible, hiding the swap.
    _gridFlipController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 240),
        )..addListener(() {
          if (!_gridFlipSwapped && _gridFlipController!.value >= 0.5) {
            _gridFlipSwapped = true;
            if (mounted) setState(() => _gridFlipSwap?.call());
          }
        });
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() {
          _error = 'No cameras available';
        });
        return;
      }

      // Log all cameras.
      // Note: on iOS, cam.name is device.uniqueID (not a human-readable string),
      // so name-based detection like contains('ultra') never works.
      for (int i = 0; i < _cameras!.length; i++) {
        debugLog(
          'Camera[$i]: "${_cameras![i].name}" dir=${_cameras![i].lensDirection}',
        );
      }

      // Identify the virtual multi-lens device (builtInTripleCamera /
      // builtInDualWideCamera) using AVCaptureDevice.DiscoverySession via the
      // native channel. The returned uniqueID matches CameraDescription.name
      // because camera_avfoundation builds descriptions with device.uniqueID
      // as the name — and >= 0.9.8 includes virtual devices in its discovery
      // session, so the ID will appear in availableCameras().
      //
      // A single CameraController on a virtual device covers 0.5×–max via one
      // AVCaptureSession. iOS routes to the correct physical lens internally
      // using videoZoomFactor + virtualDeviceSwitchOverVideoZoomFactors.
      // No session teardown — seamless, zero frame drop.
      String? virtualId;
      try {
        virtualId = await _cameraChannel.invokeMethod<String>(
          'getVirtualCameraId',
        );
      } catch (e) {
        debugLog('getVirtualCameraId: $e');
      }
      final virtualCam = virtualId != null
          ? _cameras!.where((c) => c.name == virtualId).firstOrNull
          : null;
      debugLog('getVirtualCameraId=$virtualId  matched=${virtualCam?.name}');

      if (virtualCam != null) {
        debugLog('Virtual multi-camera found: ${virtualCam.name}');
        _usesVirtualCamera = true;
        _ultraWideCamera = null;
        _controller = CameraController(
          virtualCam,
          _resolution,
          enableAudio: true,
        );
      } else {
        debugLog(
          'No virtual camera — using pre-warmed two-controller approach.',
        );
        _usesVirtualCamera = false;
        _ultraWideCamera = await _resolveUltraWideCamera();
        _controller = CameraController(
          _cameras![0],
          _resolution,
          enableAudio: true,
        );
        _isUsingUltraWide = false;
      }

      await _controller!.initialize();
      await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await _controller!.setFlashMode(_flashMode);
      try {
        // Devices report a wide range (≈ ±8 EV on iOS); clamp to a tighter span
        // so the slider gives fine control over the useful range.
        const double evLimit = 2.0;
        _minExposure = (await _controller!.getMinExposureOffset()).clamp(
          -evLimit,
          0.0,
        );
        _maxExposure = (await _controller!.getMaxExposureOffset()).clamp(
          0.0,
          evLimit,
        );
      } catch (_) {}
      _minZoom = await _controller!.getMinZoomLevel();
      _maxZoom = (await _controller!.getMaxZoomLevel())
          .clamp(0, _zoomMax)
          .toDouble();
      _currentZoom = _usesVirtualCamera
          ? 1.0.clamp(_minZoom, _maxZoom)
          : _minZoom;

      if (_usesVirtualCamera) {
        try {
          final info = await _CameraZoomChannel.instance.getZoomInfo();
          if (info != null) {
            _minZoom = (info['min'] as num?)?.toDouble() ?? _minZoom;
            _maxZoom = (info['max'] as num?)?.toDouble() ?? _maxZoom;
            _switchoverFactors = ((info['switchoverFactors'] as List?) ?? [])
                .map((e) => (e as num).toDouble())
                .toList();
            debugLog('Switchover factors: $_switchoverFactors');
          }
        } catch (e) {
          debugLog('getZoomInfo failed: $e');
        }
        _currentZoom = _currentZoom.clamp(_minZoom, _maxZoom);
        await _CameraZoomChannel.instance.setZoom(_currentZoom);
      }
      _zoomN.value = _currentZoom; // seed the display notifier
      debugLog(
        'Zoom range: $_minZoom – $_maxZoom | ultra-wide: ${_ultraWideCamera?.name}',
      );

      // Lens field of view → half the vertical FOV (radians) for projecting the
      // gravity horizon's on-screen height. In portrait the sensor's long
      // (horizontal) axis maps to the preview's vertical extent.
      try {
        // The full-screen (cover + 1.17× stretched) preview actually presents a
        // wide vertical FOV — on-device calibration showed the native value
        // (~107°) is right, so trust it; fall back to ~108° if the query fails.
        double fovDeg = 108.0;
        final native = await _cameraChannel.invokeMethod<double>(
          'getFieldOfView',
        );
        if (native != null && native >= 40 && native <= 140) fovDeg = native;
        _vFovHalfRad = (fovDeg / 2) * math.pi / 180.0;
      } catch (_) {}

      _recordRefAspect();
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
      // Begin streaming frames for composition detection — but only after the
      // first UI frames have painted. Starting the CPU-heavy per-frame detection
      // (pixel-rotation loop + ML Kit + Vision) while the launch frames (camera
      // preview + glass chrome) are still warming up their GPU pipelines is the
      // main source of first-launch jank, so let the UI settle first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) _syncImageStream(); // stream only if the mode needs it
        });
      });
    } catch (e) {
      setState(() {
        _error = 'Camera initialization failed: $e';
      });
      debugLog('Camera error: $e');
    }
  }

  /// Resolves the ultra-wide [CameraDescription] by querying the native
  /// AVCaptureDeviceDiscoverySession through the [_cameraChannel].
  ///
  /// On iOS the channel returns the [AVCaptureDevice.uniqueID] of the
  /// `.builtInUltraWideCamera` device, which matches [CameraDescription.name].
  /// If the channel call fails (non-iOS, simulator, or older device), falls
  /// back to the first non-primary back camera in the list.
  Future<CameraDescription?> _resolveUltraWideCamera() async {
    if (_cameras == null) return null;

    try {
      final String? uid = await _cameraChannel.invokeMethod<String>(
        'getUltraWideCameraId',
      );
      if (uid != null) {
        final match = _cameras!.where((c) => c.name == uid).firstOrNull;
        if (match != null) {
          debugLog(
            '_resolveUltraWide: matched "${match.name}" via native channel',
          );
          return match;
        }
        debugLog('_resolveUltraWide: uid "$uid" not found in camera list');
      } else {
        debugLog(
          '_resolveUltraWide: channel returned null (no ultra-wide on device)',
        );
      }
    } catch (e) {
      debugLog('_resolveUltraWide: channel error — $e');
    }

    // Fallback: first additional back camera.
    final fallback = _cameras!
        .where(
          (c) =>
              c.lensDirection == CameraLensDirection.back && c != _cameras![0],
        )
        .firstOrNull;
    if (fallback != null) {
      debugLog('_resolveUltraWide: fallback to "${fallback.name}"');
    }
    return fallback;
  }

  /// Briefly initialises and immediately disposes the ultra-wide controller
  /// while no other [AVCaptureSession] is active. Pre-warming means the OS
  /// Requests photo-library access at most once per session (result cached).
  Future<bool> _ensurePhotoPermission() async {
    if (_photoPermission != null) return _photoPermission!;
    final ps = await PhotoManager.requestPermissionExtend();
    _photoPermission = ps.isAuth || ps.hasAccess;
    return _photoPermission!;
  }

  Future<void> _loadLatestThumbnail() async {
    try {
      debugLog('Starting thumbnail load...');

      if (!await _ensurePhotoPermission()) {
        debugLog('Photo library permission denied or not granted');
        return;
      }

      // Get all assets sorted by creation date (most recent first)
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.common, // Gets both images and videos
        hasAll: true,
        onlyAll: true,
      );

      debugLog('Found ${albums.length} albums');

      if (albums.isEmpty) {
        debugLog('No albums found');
        return;
      }

      // Get the most recent asset from the "All" album
      final recentAlbum = albums.first;
      final assetCount = await recentAlbum.assetCountAsync;
      // Cache so the gallery can open instantly (no query between swipe + slide).
      _galleryAlbum = recentAlbum;
      _galleryCount = assetCount;
      debugLog('Album "${recentAlbum.name}" has $assetCount assets');

      if (assetCount == 0) {
        debugLog('No assets in album');
        return;
      }

      final List<AssetEntity> recentAssets = await recentAlbum
          .getAssetListRange(start: 0, end: 1);

      if (recentAssets.isEmpty) {
        debugLog('Failed to get recent assets');
        return;
      }

      debugLog('Loading thumbnail for asset: ${recentAssets.first.id}');

      // Get thumbnail data
      final Uint8List? thumbnail = await recentAssets.first
          .thumbnailDataWithSize(const ThumbnailSize(200, 200), quality: 90);

      debugLog(
        'Thumbnail loaded: ${thumbnail != null ? "${thumbnail.length} bytes" : "null"}',
      );

      if (mounted && thumbnail != null) {
        setState(() {
          _latestThumbnail = thumbnail;
        });
        debugLog('Thumbnail set in state');
      }
    } catch (e) {
      debugLog('Error loading latest thumbnail: $e');
    }
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _tipTimer?.cancel();
    _focusHideTimer?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    PhilyPro.instance.removeListener(_onProChanged);
    _faceAnim?.dispose();
    _gridFlipController?.dispose();
    _focalAnim.dispose();
    _crossSpinCtl.dispose();
    _tipAnim.dispose();
    _readoutPop.dispose();
    _beltEngage.dispose();
    _zoomFling.dispose();
    _dialMorph.dispose();
    _eyeRepaint.dispose();
    _alignLevel.dispose();
    _crossN.dispose();
    _zoomN.dispose();
    _evN.dispose();
    _horizon.dispose();
    _hzLevel.dispose();
    _levelAttitude.dispose();
    _warmAttitude.dispose();
    _faceDetector.close();
    _stopImageStream();
    _controller?.dispose();
    _bounceController?.dispose();
    _buttonBopController?.dispose();
    _glowController?.dispose();
    _focusRingController?.dispose();
    _compositionPageController.dispose();
    super.dispose();
  }

  /// Re-focuses (and re-meters exposure) at [pos]. [locked] sets AE/AF lock and
  /// keeps the indicator up; otherwise it auto-hides after a few idle seconds.
  Future<void> _focusAt(
    Offset pos,
    BoxConstraints constraints, {
    bool locked = false,
  }) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final double x = (pos.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final double y = (pos.dy / constraints.maxHeight).clamp(0.0, 1.0);
    try {
      // Unlock first so the new point actually re-focuses / re-meters.
      await _controller!.setFocusMode(FocusMode.auto);
      await _controller!.setExposureMode(ExposureMode.auto);
      await _controller!.setFocusPoint(Offset(x, y));
      await _controller!.setExposurePoint(Offset(x, y));
      await _controller!.setExposureOffset(0);
      if (locked) {
        await _controller!.setFocusMode(FocusMode.locked);
        await _controller!.setExposureMode(ExposureMode.locked);
      }
    } catch (_) {}
    if (locked) _haptic('medium');
    _evN.value = 0;
    setState(() {
      _focusPoint = pos;
      _focusShown = true;
      _aeAfLocked = locked;
      _exposureOffset = 0;
    });
    _focusRingController!.forward(from: 0);
    _scheduleFocusHide();
  }

  Future<void> _onTapToFocus(
    TapUpDetails details,
    BoxConstraints constraints,
  ) => _focusAt(details.localPosition, constraints);

  /// Auto-hides the focus/exposure UI after a few idle seconds — unless AE/AF is
  /// locked, in which case it stays until the user taps again.
  void _scheduleFocusHide() {
    _focusHideTimer?.cancel();
    if (_aeAfLocked) return;
    _focusHideTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      setState(() => _focusShown = false);
      Future.delayed(const Duration(milliseconds: 260), () {
        if (mounted && !_focusShown) setState(() => _focusPoint = null);
      });
    });
  }

  /// Drag handler for the exposure slider: [dy] is the upward drag (positive =
  /// brighter), [span] the slider's pixel height.
  Future<void> _adjustExposure(double dy, double span) async {
    if (_controller == null || _maxExposure <= _minExposure) return;
    final range = _maxExposure - _minExposure;
    // Full slider travel covers the EV range; drag up brightens.
    final next = (_exposureOffset + (dy / span) * range).clamp(
      _minExposure,
      _maxExposure,
    );
    if ((next - _exposureOffset).abs() < 0.001) return;
    // Notifier (not setState): the drag repaints only the EV slider readout.
    _exposureOffset = next;
    _evN.value = next;
    try {
      await _controller!.setExposureOffset(next);
    } catch (_) {}
    _scheduleFocusHide();
  }

  /// On-screen exposure drag — deliberately gentle: ~2.5 screen-heights of
  /// travel covers the whole EV range, so one big swipe nudges only about a
  /// third of the bar. [dyUp] is the upward drag in px (positive = brighter).
  void _adjustExposureScreen(double dyUp) {
    final double h = MediaQuery.of(context).size.height;
    _adjustExposure(dyUp, h * 2.5);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _zoomFling.stop(); // a fresh touch takes over from any coasting fling
    _zoomAtStop = false; // re-arm the range-end thud
    _baseZoom = _currentZoom;
    _swipeStartX = _swipeLastX = details.focalPoint.dx;
    _swipeStartY = _swipeLastY = details.focalPoint.dy;
    _swipeMaxPointers = details.pointerCount;
  }

  // ── Cross rotate handle ──────────────────────────────────────────────────
  // The handle is grabbed (glow + haptic), then a tangential drag spins the
  // cross about its pivot. A ticker eases the rendered angle toward the finger
  // target and fades the glow, so the spin feels smooth and weighted.

  void _ensureCrossSpinTicking() {
    if (!_crossSpinCtl.isAnimating) _crossSpinCtl.repeat();
  }

  /// Reset every mode's turn/flip orientation to its default, so each grid
  /// starts fresh whenever its page is (re-)entered.
  void _resetModeOrientations() {
    _spiralTurns = 0;
    _spiralFlipped = false;
    _trianglesFlipped = false;
    _focalTurns = 0;
    _diagonalTurns = 0;
    _lTurns = 0;
    _lFlipped = false;
  }

  /// Restore the cross to its default look (centred bar, no rotation, no glow).
  void _resetCross() {
    _crossY = _crossYTarget = kCrossDefaultY;
    _crossAngle = 0;
    _crossAngleTarget = 0;
    _crossGlow = 0;
    _rotatingCross = false;
    _slidingCross = false;
    if (_crossSpinCtl.isAnimating) _crossSpinCtl.stop();
    _crossN.value = (y: _crossY, angle: 0.0, glow: 0.0);
  }

  // ── Cross slider (move the crossbar) ─────────────────────────────────────
  void _onCrossSlideStart() {
    _slidingCross = true;
    _slideNotch = (_crossYTarget * 24).round();
    HapticFeedback.selectionClick();
    _ensureCrossSpinTicking();
  }

  void _onCrossSlide(double dyFrac) {
    _crossYTarget = (_crossYTarget + dyFrac).clamp(
      kCrossTopFrac,
      kCrossBottomFrac,
    );
    // A light notch tick as the bar travels — tactile without being constant.
    final int notch = (_crossYTarget * 24).round();
    if (notch != _slideNotch) {
      _slideNotch = notch;
      HapticFeedback.selectionClick();
    }
    _ensureCrossSpinTicking();
  }

  void _onCrossSlideEnd() {
    _slidingCross = false;
    _ensureCrossSpinTicking(); // keep ticking until the bar + glow settle
  }

  void _onCrossGrab() {
    _rotatingCross = true;
    const double quarter = math.pi / 2;
    _lastDetent = (_crossAngle / quarter).round();
    // Whether we're starting INSIDE a detent band — so the lock-in haptic
    // doesn't fire for the detent we're already sitting on.
    _crossWasStuck = (_crossAngle - _lastDetent * quarter).abs() < 0.14;
    HapticFeedback.selectionClick();
    _ensureCrossSpinTicking();
  }

  void _onCrossSpin(DragUpdateDetails d) {
    // Handle sits at radius L from the pivot; a tangential drag of `delta`
    // changes the angle by (tangential component / radius). The radius is based
    // on the camera-visible BAND (same space the painter draws the cross in), so
    // it matches the handle on every device regardless of panel/safe-area size.
    final double bandH =
        MediaQuery.of(context).size.height - _topInset - _bottomInset;
    final double l =
        bandH * (kCrossBottomFrac - kCrossTopFrac) / 2 + _kCrossHandleDrop;
    if (l <= 0) return;
    final double dTheta =
        -(math.cos(_crossAngle) * d.delta.dx +
            math.sin(_crossAngle) * d.delta.dy) /
        l;
    _crossAngleTarget += dTheta;
    _ensureCrossSpinTicking();
  }

  void _onCrossRelease() {
    _rotatingCross = false;
    _ensureCrossSpinTicking(); // keep ticking until angle + glow settle
  }

  /// Per-frame easing for the cross spin + selection glow. Stops itself once
  /// the angle has caught up to the finger and the glow has settled.
  void _tickCrossSpin() {
    // Sticky 90° detents: while the finger target sits within a small band of a
    // quarter-turn, the cross HOLDS to that detent (with a click), releasing only
    // once you drag past the band. Between detents it turns freely.
    const double quarter = math.pi / 2;
    const double stick = 0.14; // ~8° catch band each side of a quarter-turn
    final int detent = (_crossAngleTarget / quarter).round();
    final double detentAngle = detent * quarter;
    final bool stuck = (_crossAngleTarget - detentAngle).abs() < stick;
    final double effective = stuck ? detentAngle : _crossAngleTarget;

    _crossAngle += (effective - _crossAngle) * 0.30;
    _crossY += (_crossYTarget - _crossY) * 0.35; // smooth crossbar travel
    // Glow whenever the cross is being actively spun OR slid.
    final double gTarget = (_rotatingCross || _slidingCross) ? 1.0 : 0.0;
    _crossGlow += (gTarget - _crossGlow) * 0.16;

    // A firm click EVERY time it locks into a 90° detent — including coming
    // back to the same one after wandering off it (edge-triggered on entering
    // the stick band, not on the detent index changing).
    if (_rotatingCross && stuck && (!_crossWasStuck || detent != _lastDetent)) {
      _lastDetent = detent;
      HapticFeedback.lightImpact();
    }
    if (_rotatingCross) _crossWasStuck = stuck;

    final bool aSettled = (effective - _crossAngle).abs() < 0.0015;
    final bool ySettled = (_crossYTarget - _crossY).abs() < 0.0008;
    final bool gSettled = (gTarget - _crossGlow).abs() < 0.004;
    if (aSettled) _crossAngle = effective;
    if (ySettled) _crossY = _crossYTarget;
    if (gSettled) _crossGlow = gTarget;
    // Notifier (not setState): repaints only the guide + the cross controls.
    _crossN.value = (y: _crossY, angle: _crossAngle, glow: _crossGlow);
    if (!_rotatingCross && !_slidingCross && aSettled && ySettled && gSettled) {
      _crossSpinCtl.stop();
    }
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails details) async {
    _swipeMaxPointers = math.max(_swipeMaxPointers, details.pointerCount);
    final double prevX = _swipeLastX;
    final double prevY = _swipeLastY;
    _swipeLastX = details.focalPoint.dx;
    _swipeLastY = details.focalPoint.dy;
    if (_controller == null || !_controller!.value.isInitialized) return;

    // Two fingers → pinch zoom, constrained to the active lens range (with a
    // firm thud when the pinch hits either end of it).
    if (details.pointerCount > 1) {
      final double newZoom = _clampWithStopThud(
        _baseZoom * details.scale,
        _zoomLo,
        _zoomHi,
      );
      if ((newZoom - _currentZoom).abs() < 0.01) return;
      await _setCameraZoom(newZoom);
      return;
    }

    // One finger, while the focus/exposure UI is up (i.e. just after a tap to
    // focus) → slide vertically anywhere on screen to set exposure. Gated to
    // mostly-vertical moves so horizontal composition swipes still work.
    if (_focusShown && _focusPoint != null && _maxExposure > _minExposure) {
      final double dy = _swipeLastY - prevY;
      final double dx = _swipeLastX - prevX;
      if (dy.abs() > dx.abs()) {
        _adjustExposureScreen(-dy); // drag up = brighter
      }
    }
  }

  void _onScaleEnd(ScaleEndDetails _) {
    // Only a single-finger gesture counts as a swipe (never a pinch).
    if (_swipeMaxPointers > 1) return;
    final double dx = _swipeLastX - _swipeStartX;
    final double dy = _swipeLastY - _swipeStartY;
    // Clear vertical swipe up → open the gallery, sliding up (the mirror of the
    // grid's swipe-down-to-close). Not while recording or adjusting exposure
    // (the focus UI owns vertical drags then).
    if (dy < -70 &&
        dy.abs() > dx.abs() * 1.5 &&
        !_isRecording &&
        !_focusShown) {
      HapticFeedback.selectionClick();
      _openGalleryViewer();
      return;
    }
    // A short, clearly-horizontal flick is enough to step modes.
    if (dx.abs() > 24 && dx.abs() > dy.abs() * 1.2) {
      _changeCompositionBy(dx < 0 ? 1 : -1); // swipe left → next, right → prev
    }
  }

  /// Run the Focal Mass repaint clock only while that mode is active.
  void _syncFocalAnim() {
    if (_compositionMode == CompositionMode.focalMass) {
      if (!_focalAnim.isAnimating) _focalAnim.repeat();
    } else if (_focalAnim.isAnimating) {
      _focalAnim.stop();
    }
  }

  /// Switches the composition mode by [delta] steps, animating the belt so its
  /// onPageChanged keeps the index, mode and UI in sync.
  void _changeCompositionBy(int delta) {
    final int next = (_currentCompositionIndex + delta).clamp(
      0,
      _compositionModes.length - 1,
    );
    if (next == _currentCompositionIndex) return;
    _compositionPageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  /// Jumps the belt straight to [index] (tapping a mode rather than swiping).
  /// animateToPage fires onPageChanged, so haptic/mode/tip stay in sync.
  void _goToCompositionIndex(int index) {
    if (index == _currentCompositionIndex) return;
    _compositionPageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  /// Compact "best for" blurb for the current mode, or null when there's
  /// nothing worth saying (None).
  /// "Best for" blurb for the current mode (registry-sourced); null → no bubble.
  String? get _compositionTip => kCompositionByMode[_compositionMode]!.tip;

  /// Which way to hold the phone for this mode — a quick portrait / landscape /
  /// both hint shown beside the tip. Null where it doesn't apply.
  String? get _compositionOrientation =>
      kCompositionByMode[_compositionMode]!.orientation.label;

  /// Show the "best for" bubble for ~3s. Re-arms the timer on each call so a
  /// quick scrub through modes keeps the latest bubble visible.
  void _showCompositionTip() {
    if (_compositionTip == null) {
      _dismissTip();
      return;
    }
    _tipTimer?.cancel();
    setState(() => _showTip = true);
    // Replay from 0 so the advice always animates in fresh, even mode-to-mode.
    _tipAnim.forward(from: 0);
    _tipTimer = Timer(const Duration(seconds: 3), _dismissTip);
  }

  /// Hide the bubble immediately (swipe-up, or moving to a tip-less mode).
  void _dismissTip() {
    _tipTimer?.cancel();
    if (!mounted) return;
    if (_showTip) setState(() => _showTip = false);
    _tipAnim.reverse(); // slide the bubble back out
  }

  void _triggerBounceAnimation(File capturedFile) {
    setState(() {
      _animatingMedia = capturedFile;
      _showBounceAnimation = true;
    });
    _bounceController!.forward();
  }

  /// Starts the image stream for composition alignment analysis.
  /// Safe to call when already streaming or when no controller is active.
  Future<void> _startImageStream() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isStreamingImages) return;
    try {
      await _controller!.startImageStream(_onCameraFrame);
    } catch (e) {
      debugLog('startImageStream: $e');
    }
  }

  /// Stops the image stream. Safe to call when not streaming.
  void _stopImageStream() {
    try {
      if (_controller != null && _controller!.value.isStreamingImages) {
        _controller!.stopImageStream();
      }
    } catch (e) {
      debugLog('stopImageStream: $e');
    }
  }

  /// Modes that actually analyze camera frames (subject detection). Horizon uses
  /// the gravity sensor, and every other mode is geometry-only — none of them
  /// need the ML image stream.
  bool get _needsDetection =>
      !_modeLocked &&
      (_compositionMode == CompositionMode.none ||
          _compositionMode == CompositionMode.ruleOfThirds ||
          _compositionMode == CompositionMode.goldenSection ||
          _compositionMode == CompositionMode.fibonacciSpiral);

  /// Run the ML image stream ONLY when the current mode needs it. In the other
  /// ~13 modes the live preview keeps running but no 24MP frames are delivered
  /// to Dart and no ML runs — a big cut in per-frame CPU/GPU work, and heat.
  Future<void> _syncImageStream() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _isRecording) return;
    final bool streaming = c.value.isStreamingImages;
    if (_needsDetection && !streaming) {
      await _startImageStream();
    } else if (!_needsDetection && streaming) {
      _stopImageStream();
      // Clear any boxes/eye rings the previous detection mode left behind.
      if (_faceBoxes.isNotEmpty) _updateFaceTargets(const []);
      if (_eyePoints.isNotEmpty) {
        _eyePoints.clear();
        _eyeRepaint.value++;
      }
    }
  }

  Future<void> _capturePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    // Shutter weight — the press lands with real heft.
    HapticFeedback.heavyImpact();

    // Show shutter flash immediately for instant feedback
    setState(() {
      _showShutterFlash = true;
    });

    // Hide flash after brief moment
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          _showShutterFlash = false;
        });
      }
    });

    try {
      // takePicture() conflicts with an active stream on some devices.
      _stopImageStream();
      final image = await _controller!.takePicture();
      final file = File(image.path);
      _triggerBounceAnimation(file);
      _saveMediaInBackground(file.path);
      // Restart the stream after capture only if the mode needs it.
      await _syncImageStream();
    } catch (e) {
      debugLog('Error taking photo: $e');
      await _syncImageStream();
    }
  }

  Future<void> _saveMediaInBackground(String filePath) async {
    try {
      // Save to gallery — gal uses separate methods for images vs videos.
      final lower = filePath.toLowerCase();
      final isVideo = lower.endsWith('.mp4') || lower.endsWith('.mov');
      if (isVideo) {
        await Gal.putVideo(filePath, album: 'Phily');
      } else {
        await Gal.putImage(filePath, album: 'Phily');
      }

      // Save landed — a settled confirmation as the media reaches the library
      // (the bounce animation is the visual half of this moment).
      HapticFeedback.mediumImpact();

      // Refresh thumbnail after save completes
      _loadLatestThumbnail();
    } catch (e) {
      debugLog('Error saving media: $e');
    }
  }

  Future<void> _startVideoRecording() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isRecording) {
      return;
    }

    // The "REC" clunk — a quick double tick, like a mechanical record switch.
    HapticFeedback.lightImpact();
    Future.delayed(
      const Duration(milliseconds: 70),
      HapticFeedback.lightImpact,
    );

    // Trigger animations immediately for instant feedback
    _recordingStopwatch
      ..reset()
      ..start();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() {
      _isRecording = true;
    });
    _dismissTip(); // clear the advice bubble out of the shot while filming

    // Trigger bop animation
    _buttonBopController!.forward(from: 0);

    // Start glow pulsing animation
    _glowController!.forward();

    try {
      // Video recording cannot run alongside an image stream.
      _stopImageStream();
      await _controller!.startVideoRecording();
    } catch (e) {
      debugLog('Error starting video: $e');
      _recordingTimer?.cancel();
      _recordingStopwatch.stop();
      setState(() {
        _isRecording = false;
      });
      _glowController!.stop();
      _glowController!.reset();
      await _startImageStream();
    }
  }

  Future<void> _stopVideoRecording() async {
    if (_controller == null || !_isRecording) return;

    // Matching double tick on the way out of recording.
    HapticFeedback.lightImpact();
    Future.delayed(
      const Duration(milliseconds: 70),
      HapticFeedback.lightImpact,
    );

    _recordingTimer?.cancel();
    _recordingStopwatch.stop();

    // Update UI state immediately for instant feedback
    setState(() {
      _isRecording = false;
    });

    // Stop glow animation smoothly
    _glowController!.stop();
    _glowController!.animateTo(
      0.0,
      duration: const Duration(milliseconds: 400),
    );

    try {
      final video = await _controller!.stopVideoRecording();
      final file = File(video.path);
      _triggerBounceAnimation(file);
      _saveMediaInBackground(file.path);
      // Resume alignment analysis after recording stops.
      await _startImageStream();
    } catch (e) {
      debugLog('Error stopping video: $e');
      _glowController!.reset();
      await _startImageStream();
    }
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    // Always run detection so overlays can show even when composition mode
    // is `none` (useful for experimentation). Heavy composition-only logic
    // remains gated on the selected mode.
    final now = DateTime.now();
    // ~20 fps. Lower = more responsive tracking, but more CPU. With the cached
    // single-orientation detection + gyro dead-reckoning between results this
    // stays cheap enough for smooth tracking (raise back to 60 if FPS dips).
    if (now.difference(_lastFrameTime).inMilliseconds < 50) return;
    if (_isProcessingFrame) return;
    _isProcessingFrame = true;
    _lastFrameTime = now;
    try {
      // Horizon Grid doesn't touch camera frames (its line comes from the gravity
      // sensor); the other detection modes share the face/animal path. Locked
      // modes (post-trial, non-Pro) detect nothing — they render as None.
      final bool detect =
          !_modeLocked &&
          (_compositionMode == CompositionMode.none ||
              _compositionMode == CompositionMode.ruleOfThirds ||
              _compositionMode == CompositionMode.goldenSection ||
              _compositionMode == CompositionMode.fibonacciSpiral);
      if (detect) {
        await _analyzeDetections(image);
      } else {
        // Fade out any face/animal boxes + clear eye rings left from the previous
        // mode so they don't freeze and carry over on screen.
        if (_faceBoxes.isNotEmpty) _updateFaceTargets(const []);
        if (_eyePoints.isNotEmpty) {
          _eyePoints.clear();
          _eyeRepaint.value++;
        }
      }
    } catch (e) {
      debugLog('_onCameraFrame: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  // Caches the physical quarter-turn rotation that finds faces per device-turns.
  final Map<int, int> _qtCache = {};

  /// Real-time face detection via ML Kit. ML Kit on iOS ignores InputImage
  /// rotation metadata, so to detect faces when the phone is held sideways we
  /// must PHYSICALLY rotate the pixel buffer to upright, detect, then map the
  /// boxes back into the original (portrait) buffer space the fixed preview shows.
  Future<void> _analyzeDetections(CameraImage image) async {
    // Snapshot the gyro pan at capture — results are compensated by whatever
    // pan accrues while this frame is being analysed (see the end of this
    // method), so fresh targets never snap the boxes backwards mid-pan.
    _panCapX = _panTotX;
    _panCapY = _panTotY;
    if (image.format.group != ImageFormatGroup.bgra8888) return;
    final plane = image.planes.first;
    final int w = image.width, h = image.height;
    final turns = _deviceTurns;

    // Adaptive downsample: 48MP (max) streams much larger frames than 24MP, so
    // detect at a *constant* buffer size instead of a fixed factor — the rotation
    // loop, ML Kit and Vision all scale with this buffer, so this keeps 48MP as
    // cheap as 24MP. veryHigh keeps the calibrated 3; bigger frames downsample
    // more. Coords are normalised, so the factor doesn't affect box alignment.
    final int detScale = _resolution == ResolutionPreset.veryHigh
        ? _detScale
        : (math.max(w, h) / _kDetTargetLong).round().clamp(_detScale, 12);

    // Build the downsampled+rotated buffer ONCE at the best-known rotation and
    // reuse it for both ML Kit (faces) and Vision (subjects) — one synchronous
    // pixel loop on the UI isolate per frame.
    int qt = _qtCache[turns] ?? 0;
    // reuse: the steady-state path writes into the shared _rotBuf — zero
    // per-frame allocation. Probe rotations below allocate fresh buffers so a
    // losing candidate can never overwrite the winner's bytes.
    var (winBytes, winOw, winOh) = _rotatedBytes(
      plane.bytes,
      w,
      h,
      plane.bytesPerRow,
      qt,
      scale: detScale,
      reuse: true,
    );
    List<Face> faces = await _faceDetector.processImage(
      _inputFromBytes(winBytes, winOw, winOh),
    );
    if (!mounted) return;

    // If nothing was found, the rotation may be wrong — re-probe the other three
    // orientations to (re)discover it. Throttled to ~1/sec so a genuinely
    // face-less scene (landscape/street) doesn't pay 4 rotations every frame.
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    // Probe every frame while we're actively tracking (instant re-acquire), but
    // throttle to ~1/sec once the scene has had no face for a while.
    final bool recentlyTracked = nowMs - _lastFaceMs < 1500;
    if (faces.isEmpty && (recentlyTracked || nowMs - _lastProbeMs > 800)) {
      _lastProbeMs = nowMs;
      for (final cand in const [1, 3, 2]) {
        if (cand == qt) continue; // already tried above
        final (b, ow, oh) = _rotatedBytes(
          plane.bytes,
          w,
          h,
          plane.bytesPerRow,
          cand,
          scale: detScale,
        );
        final found = await _faceDetector.processImage(
          _inputFromBytes(b, ow, oh),
        );
        if (!mounted) return;
        if (found.length > faces.length) {
          faces = found;
          qt = cand;
          winBytes = b;
          winOw = ow;
          winOh = oh;
        }
      }
      if (faces.isNotEmpty) _qtCache[turns] = qt; // cache only a real winner
    }
    if (faces.isNotEmpty) _lastFaceMs = nowMs;

    final double ow = winOw.toDouble(), oh = winOh.toDouble();

    // Map ML Kit boxes (normalised in the upright image) back to portrait buffer
    // space via the inverse rotation, then apply the preview's horizontal stretch.
    final dets = <Map<String, dynamic>>[];
    // Show eye markers in None (the test) and the subject modes that align on
    // the eyes (Rule of Thirds / Phi Grid / Spiral — those have power points).
    final bool wantEyes =
        _compositionMode == CompositionMode.none || _modePowerPoints != null;
    final eyePts = <Offset>[];
    // Map an eye landmark (upright-image pixels) into portrait preview space.
    Offset? mapEye(math.Point<int>? p) {
      if (p == null) return null;
      final e = _invRotNorm(p.x / ow, p.y / oh, qt);
      return Offset((e.$1 - 0.5) * _previewStretchX + 0.5, e.$2);
    }

    for (final f in faces) {
      final r = f.boundingBox;
      final c1 = _invRotNorm(r.left / ow, r.top / oh, qt);
      final c2 = _invRotNorm(r.right / ow, r.bottom / oh, qt);
      final nx = math.min(c1.$1, c2.$1);
      final ny = math.min(c1.$2, c2.$2);
      final nw = (c1.$1 - c2.$1).abs();
      final nh = (c1.$2 - c2.$2).abs();
      final cx = (nx + nw / 2 - 0.5) * _previewStretchX + 0.5;
      final stretchedW = nw * _previewStretchX;

      // Eye midpoint → alignment key point: the portrait rule places the *eyes*
      // (not the face box) on the target. Stored as an offset from the box centre;
      // 0 when both eyes aren't visible (profile) so it falls back to the centre.
      final lE = mapEye(f.landmarks[FaceLandmarkType.leftEye]?.position);
      final rE = mapEye(f.landmarks[FaceLandmarkType.rightEye]?.position);
      double kox = 0, koy = 0, eyeSpanY = 0;
      final bool hasEyes = lE != null && rE != null;
      if (lE != null && rE != null) {
        kox = (lE.dx + rE.dx) / 2 - cx;
        koy = (lE.dy + rE.dy) / 2 - (ny + nh / 2);
        eyeSpanY = (lE.dy - rE.dy).abs();
        if (wantEyes) eyePts.addAll([lE, rE]);
      }

      dets.add({
        'x': cx - stretchedW / 2,
        'y': ny,
        'w': stretchedW,
        'h': nh,
        'label': 'face',
        'confidence': 1.0,
        'kox': kox,
        'koy': koy,
        'eyeSpanY': eyeSpanY,
        'eyes': hasEyes,
      });
    }
    if (wantEyes) {
      _eyePoints
        ..clear()
        ..addAll(eyePts);
      _eyeRepaint.value++;
    } else if (_eyePoints.isNotEmpty) {
      _eyePoints.clear();
      _eyeRepaint.value++;
    }

    // ── Animals (cats/dogs) via Apple Vision — throttled (~7 Hz). The box's
    // grace window keeps it steady on the in-between frames, so re-adding the
    // last result avoids any flicker while saving a native call most frames.
    if (_animalsEnabled) {
      if (nowMs - _lastAnimalMs > 140) {
        _lastAnimalMs = nowMs;
        try {
          final raw = await _cameraChannel.invokeMethod<List>('detectAnimals', {
            'bgra': winBytes,
            'width': winOw,
            'height': winOh,
          });
          if (!mounted) return;
          final tmp = <Map<String, dynamic>>[];
          _addVisionDets(raw, tmp, qt, 'animal');
          _lastAnimalDets = tmp;
        } catch (_) {}
      }
      dets.addAll(_lastAnimalDets);
    }

    // The frame we analysed is ~60–120ms old; shift its detections by the
    // camera pan since capture so the targets land where the subject IS,
    // not where it was.
    final double cdx = _panTotX - _panCapX;
    final double cdy = _panTotY - _panCapY;
    if (cdx != 0 || cdy != 0) {
      for (final d in dets) {
        d['x'] = (d['x'] as double) + cdx;
        d['y'] = (d['y'] as double) + cdy;
      }
    }

    _updateFaceTargets(dets); // ticker animates the displayed boxes
  }

  /// Compute the horizon line target from the device's gravity vector (Horizon
  /// Grid mode). The angle is the phone's roll (the true horizon counter-rotates
  /// to stay level); the on-screen height comes from the camera's pitch +
  /// vertical FOV. Image-independent → works in any light, costs nothing. The
  /// 60fps ticker eases the displayed line toward these targets.
  /// Updates the attitude (roll + pitch) driving the "hold the camera level"
  /// dial. Active in Horizon + the people modes (Rule of Thirds / Phi Grid);
  /// null elsewhere. Small deadzones read as dead-level; pushes on real change.
  void _updateLevelAttitude() {
    final m = _compositionMode; // dial shows in every mode now
    // Roll RELATIVE to the current hold in EVERY mode — so the dial reads
    // level for however the phone is held (portrait, ±90° landscape, upside
    // down). The painter draws its face in the user's frame to match.
    double roll = _relativeRoll;
    if (roll.abs() < 0.018) {
      roll = 0.0; // ~1° → reads dead-level (a touch lenient)
    }

    double vert; // normalised vertical deflection for the dial
    bool isLevel;
    if (m == CompositionMode.horizonGrid) {
      // Track the true-horizon's offset from the best-spot guide (the grid's own
      // value), so "dial centred" means "horizon on the best spot" — not plumb.
      final double dy = _horizon.value?.dy ?? 0.0; // signed screen fraction
      vert = (dy / 0.18).clamp(-1.0, 1.0); // ~±18% reaches the dial edge
      // Lock to the grid's *own* "Level" verdict (computed just above in this
      // same tick) so the dial and the best-spot bubble can never disagree.
      isLevel = _hzLevel.value == 2;
    } else {
      // People modes: deflection = pitch off plumb (+ = aimed up at the sky).
      final double pitch = math.atan2(
        _gravZ,
        math.sqrt(_gravX * _gravX + _gravY * _gravY),
      );
      vert = (pitch / 0.5).clamp(-1.0, 1.0); // ~±28° reaches the dial edge
      isLevel = roll == 0.0 && pitch.abs() < 0.075; // ~4.3° on pitch
    }

    final bool hadReading = _levelAttitude.value != null;
    // Soft confirmation the moment a tilted people-mode shot becomes square —
    // Horizon already owns its own stricter "Level" haptic.
    if (isLevel &&
        !_levelWasLevel &&
        hadReading &&
        m != CompositionMode.horizonGrid) {
      _haptic('alignmentPing', intensity: 0.7);
    }
    _levelWasLevel = isLevel;
    final prev = _levelAttitude.value;
    if (prev == null ||
        (prev.roll - roll).abs() > 0.004 ||
        (prev.vert - vert).abs() > 0.01 ||
        prev.level != isLevel) {
      _levelAttitude.value = (roll: roll, vert: vert, level: isLevel);
    }
  }

  /// Gravity roll measured RELATIVE to the current hold (≈0 when the phone is
  /// level for however it's being held), normalised to [-π, π]. Shared by the
  /// Horizon Grid's true-horizon line and its "hold it level" dial so the two
  /// always agree, in any orientation.
  double get _relativeRoll {
    final double r = math.atan2(_gravX, _gravY) + _deviceTurns * (math.pi / 2);
    return math.atan2(math.sin(r), math.cos(r));
  }

  void _updateHorizonFromMotion() {
    final double gx = _gravX, gy = _gravY, gz = _gravZ;

    // Pitch: camera elevation above the true horizon (+ = aimed up at sky).
    final double pitch = math.atan2(gz, math.sqrt(gx * gx + gy * gy));

    // Angle RELATIVE to the current hold, so "level" means level for however the
    // phone is held (portrait, landscape, upside-down). The painter re-adds the
    // hold's base angle to draw the line at its true on-screen angle. Small
    // deadzone so a near-level hold reads dead-flat.
    double ang = _relativeRoll;
    if (ang.abs() < 0.02) ang = 0.0;

    // Vertical position from camera pitch. ay = 0.5 at the optical centre and
    // grows DOWN-screen as the horizon drops (camera tilts up). Projected through
    // the half-FOV, zoom-scaled (zoom in → same tilt travels further). The
    // full-screen + stretched preview makes the lens FOV unreliable, so
    // [_hzPosGain] tunes the travel-per-degree and a default FOV is used if the
    // native query returned nothing.
    final double half = _vFovHalfRad > 0 ? _vFovHalfRad : (33 * math.pi / 180);
    final double vHalfEff = math.atan(math.tan(half) / _currentZoom);
    final double ay =
        (0.5 - _hzPosGain * 0.5 * math.tan(pitch) / math.tan(vHalfEff)).clamp(
          -0.3,
          1.3,
        );

    _hzTAngle = ang;
    _hzTAx = 0.5; // centre anchor; the line spans the full width
    _hzTAy = ay;
    // On only while the line is on (or just off) screen.
    _hzActive = ay > -0.15 && ay < 1.15;
    _ensureHorizonTicking();
  }

  /// Map a native Vision result list (normalised [0,1] top-left boxes in the
  /// upright image) back into portrait preview space and append to [dets].
  void _addVisionDets(
    List? raw,
    List<Map<String, dynamic>> dets,
    int qt,
    String fallbackLabel,
  ) {
    if (raw == null) return;
    for (final a in raw) {
      if (a is! Map) continue;
      final ax = (a['x'] as num).toDouble();
      final ay = (a['y'] as num).toDouble();
      final aw = (a['w'] as num).toDouble();
      final ah = (a['h'] as num).toDouble();
      final c1 = _invRotNorm(ax, ay, qt);
      final c2 = _invRotNorm(ax + aw, ay + ah, qt);
      final nx = math.min(c1.$1, c2.$1);
      final ny = math.min(c1.$2, c2.$2);
      final nw = (c1.$1 - c2.$1).abs();
      final nh = (c1.$2 - c2.$2).abs();
      final cx = (nx + nw / 2 - 0.5) * _previewStretchX + 0.5;
      final stretchedW = nw * _previewStretchX;
      dets.add({
        'x': cx - stretchedW / 2,
        'y': ny,
        'w': stretchedW,
        'h': nh,
        'label': (a['label'] ?? fallbackLabel).toString(),
        'confidence': (a['confidence'] as num?)?.toDouble() ?? 1.0,
      });
    }
  }

  // Reused output buffer for the per-frame detection rotation. All four
  // rotations of the same downsample share one pixel count (sw·sh), so a single
  // buffer serves every orientation; it's only re-allocated on a size change.
  // Probe rotations must NOT reuse it (they'd alias the winner) — see caller.
  Uint32List? _rotBuf;

  /// Downsample (by [scale]) + physically rotate ([qt] quarter-turns CW) a BGRA
  /// buffer so subjects are upright. Returns tightly-packed bytes plus the output
  /// dimensions. Copies a whole BGRA pixel as one 32-bit word (≈4× fewer indexed
  /// ops than per-byte, and no per-byte bounds checks) — this loop runs on the UI
  /// isolate every frame, so its speed directly affects preview smoothness.
  ///
  /// Each quarter-turn mapping is affine, so the source index is walked with a
  /// precomputed start + column/row step instead of per-pixel switch/multiplies:
  /// the inner loop is a bare strided copy. [reuse] writes into the shared
  /// [_rotBuf] (the steady-state per-frame path — no per-frame allocation).
  (Uint8List, int, int) _rotatedBytes(
    Uint8List src,
    int w,
    int h,
    int srcBpr,
    int qt, {
    int scale = _detScale,
    bool reuse = false,
  }) {
    final int s = scale;
    final int sw = w ~/ s, sh = h ~/ s;
    final int outW = (qt == 1 || qt == 3) ? sh : sw;
    final int outH = (qt == 1 || qt == 3) ? sw : sh;
    final int len = outW * outH;
    final Uint32List out32;
    if (reuse && _rotBuf != null && _rotBuf!.length == len) {
      out32 = _rotBuf!;
    } else {
      out32 = Uint32List(len);
      if (reuse) _rotBuf = out32;
    }

    // Fast path: view source + destination as 32-bit pixels. Requires the source
    // to be word-aligned (camera BGRA rows always are). Falls back to bytes if not.
    if (src.offsetInBytes % 4 == 0 && srcBpr % 4 == 0) {
      final src32 = src.buffer.asUint32List(
        src.offsetInBytes,
        src.lengthInBytes ~/ 4,
      );
      final int srcStride = srcBpr ~/ 4;
      final int start, colStep, rowStep; // in 32-bit pixels
      switch (qt) {
        case 1: // sx = dy·s, sy = h−1−dx·s
          start = (h - 1) * srcStride;
          colStep = -s * srcStride;
          rowStep = s;
          break;
        case 3: // sx = w−1−dy·s, sy = dx·s
          start = w - 1;
          colStep = s * srcStride;
          rowStep = -s;
          break;
        case 2: // sx = w−1−dx·s, sy = h−1−dy·s
          start = (h - 1) * srcStride + (w - 1);
          colStep = -s;
          rowStep = -s * srcStride;
          break;
        default: // sx = dx·s, sy = dy·s
          start = 0;
          colStep = s;
          rowStep = s * srcStride;
      }
      int base = start, di = 0;
      for (var dy = 0; dy < outH; dy++) {
        int si = base;
        for (var dx = 0; dx < outW; dx++) {
          out32[di++] = src32[si];
          si += colStep;
        }
        base += rowStep;
      }
      return (
        out32.buffer.asUint8List(out32.offsetInBytes, len * 4),
        outW,
        outH,
      );
    }

    // Byte fallback (unaligned source) — same affine walk, in byte offsets.
    final bytes = out32.buffer.asUint8List(out32.offsetInBytes, len * 4);
    final int start, colStep, rowStep; // in bytes
    switch (qt) {
      case 1:
        start = (h - 1) * srcBpr;
        colStep = -s * srcBpr;
        rowStep = s * 4;
        break;
      case 3:
        start = (w - 1) * 4;
        colStep = s * srcBpr;
        rowStep = -s * 4;
        break;
      case 2:
        start = (h - 1) * srcBpr + (w - 1) * 4;
        colStep = -s * 4;
        rowStep = -s * srcBpr;
        break;
      default:
        start = 0;
        colStep = s * 4;
        rowStep = s * srcBpr;
    }
    int base = start, di = 0;
    for (var dy = 0; dy < outH; dy++) {
      int si = base;
      for (var dx = 0; dx < outW; dx++) {
        bytes[di] = src[si];
        bytes[di + 1] = src[si + 1];
        bytes[di + 2] = src[si + 2];
        bytes[di + 3] = src[si + 3];
        di += 4;
        si += colStep;
      }
      base += rowStep;
    }
    return (bytes, outW, outH);
  }

  /// Wrap an already-rotated, tightly-packed BGRA buffer as an ML Kit InputImage.
  InputImage _inputFromBytes(Uint8List bytes, int outW, int outH) {
    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(outW.toDouble(), outH.toDouble()),
        rotation: InputImageRotation.rotation0deg,
        format: InputImageFormat.bgra8888,
        bytesPerRow: outW * 4,
      ),
    );
  }

  /// Inverse-rotate a normalised point (upright image space → portrait buffer
  /// space) for a physical rotation of [qt] quarter-turns clockwise.
  (double, double) _invRotNorm(double ux, double uy, int qt) {
    switch (qt) {
      case 1:
        return (uy, 1 - ux);
      case 2:
        return (1 - ux, 1 - uy);
      case 3:
        return (1 - uy, ux);
      default:
        return (ux, uy); // 0
    }
  }

  /// Lerp [a]→[b] by [t] along the shortest angular path.
  double _lerpAngle(double a, double b, double t) {
    double diff = b - a;
    while (diff > math.pi) {
      diff -= 2 * math.pi;
    }
    while (diff < -math.pi) {
      diff += 2 * math.pi;
    }
    return a + diff * t;
  }

  // Horizontal stretch applied to the preview (the Matrix4 in _buildPreview),
  // adapted to the live preview's aspect ratio so 24MP (veryHigh, ~16:9) and
  // 48MP (max, ~4:3) — whose preview streams have *different* aspects — fill the
  // screen the same way instead of one being squished. Calibrated to
  // _kBaseStretch at the veryHigh aspect; detection coords read this same getter
  // so boxes stay aligned across the full width.
  static const double _kBaseStretch = 1.17;
  double? _refAspectRatio; // veryHigh preview aspect (where the base is tuned)
  double get _previewStretchX {
    final c = _controller;
    final ref = _refAspectRatio;
    if (c == null || !c.value.isInitialized || ref == null) {
      return _kBaseStretch;
    }
    final double ar = c.value.aspectRatio;
    return ar > 0 ? _kBaseStretch * (ref / ar) : _kBaseStretch;
  }

  /// Records the veryHigh (24MP) preview aspect — the reference the base stretch
  /// is calibrated for. Called after each (re)initialisation at that resolution.
  void _recordRefAspect() {
    final c = _controller;
    if (c != null &&
        c.value.isInitialized &&
        _resolution == ResolutionPreset.veryHigh) {
      _refAspectRatio = c.value.aspectRatio;
    }
  }

  // ── Animated face indicators ────────────────────────────────────────────────
  // Detection updates the *targets*; a 60fps ticker eases the displayed boxes
  // toward those targets and fades them in/out, so the overlay is smooth and
  // stable regardless of the slower, slightly jittery detection rate.
  final List<_FaceBox> _faceBoxes = [];
  AnimationController? _faceAnim;
  int _lastTickMs = 0;
  // Detected horizon for the None-mode test (preview space, full-screen
  // normalised): roll angle + an anchor point on the line + a fade opacity.
  // Null when fully faded out. A ValueNotifier so only the overlay repaints.
  // The 60fps face ticker eases the *displayed* values toward the confident
  // *target* (gated below) — smooth motion + fade independent of detection rate.
  final ValueNotifier<
    ({
      double angle,
      double ax,
      double ay,
      double op,
      double aligned,
      double dy,
    })?
  >
  _horizon = ValueNotifier(null);
  // Horizon message-bubble level: 0 = guide only, 1 = detected (not level),
  // 2 = level on the guide. Drives the shared top hint bubble + the haptic.
  final ValueNotifier<int> _hzLevel = ValueNotifier(0);
  int _hzPrevLevel = 0;
  // Zero-cross detent state: armed once the horizon has tilted meaningfully,
  // fires one crisp tick as it sweeps through level, then waits for the next
  // real tilt (so jitter around 0° can't machine-gun it).
  bool _hzZeroArmed = false;
  double _hzZeroPrev = 0;

  // ── Hold-it-straight level cue ──────────────────────────────────────────────
  // Attitude for the jet-style "keep the camera level" dial, or null when the
  // active mode doesn't show it. `roll` is radians; `vert` is a normalised
  // vertical deflection [-1..1] (people modes: pitch off plumb; Horizon: the
  // true-horizon offset from the best-spot guide, so the dial agrees with the
  // grid); `level` is the mode-aware "you're square" verdict. Runs in Horizon +
  // the people modes; pushed only on meaningful change to avoid repaints.
  final ValueNotifier<({double roll, double vert, bool level})?>
  _levelAttitude = ValueNotifier(null);
  bool _levelWasLevel = false;
  // Target (from device motion) that the 60fps ticker eases the displayed line
  // toward.
  double? _hzTAngle, _hzTAx, _hzTAy;
  bool _hzActive = false; // a horizon is currently on (near) screen
  // Displayed (eased) state + whether it's been seeded since the last appearance.
  double _hzDAngle = 0, _hzDAx = 0.5, _hzDAy = 0.5, _hzDOp = 0;
  bool _hzInit = false;

  // ── Gravity horizon (CoreMotion-style, from the accelerometer) ──────────────
  // Low-pass-filtered gravity direction in device coords, and the camera's
  // half-vertical-FOV (radians) for projecting the horizon's on-screen height.
  // The angle comes straight from gravity (rock-solid in any light); the
  // position from device pitch + FOV. No per-frame image work at all.
  double _gravX = 0, _gravY = 9.8, _gravZ = 0;
  bool _gravInit = false;
  double _vFovHalfRad = 0; // 0 until queried from the native lens FOV
  // Travel-per-degree calibration for the horizon's on-screen height. Higher =
  // the line moves further as you tilt up/down. Tune this if it feels off.
  static const double _hzPosGain = 1.0;

  // Rule-of-Thirds power points (normalised) — intersections of the 1/3 lines.
  // Fixed alignment power points now live in the composition registry
  // (kThirdsPoints / kPhiPoints) so each mode's ratios are declared in one place.
  // Kept here as the Rule-of-Thirds default used by the alignment fallback.
  static const List<List<double>> _powerPoints = kThirdsPoints;
  // Forgiveness margin when testing whether a power point falls inside a box
  // (fraction of the box half-size). 0.15 = box bounds + 15%. → "Almost".
  static const double _alignMargin = 0.15;
  // How near the box centre the point must be (radially, as a fraction of the
  // box half-size) to count as "Perfect". 0.4 = within 40% of centre.
  static const double _perfectFrac = 0.40;
  final List<double> _powerGlow = [0, 0, 0, 0];

  /// Alignment target points (intersections) for the active mode, as fractions
  /// of the band, or null when the mode has no alignment. Only Rule of Thirds and
  /// Phi Grid have alignment for now — other models are being (re)built one by
  /// one.
  List<List<double>>? get _modePowerPoints {
    // Fibonacci's target is computed at runtime — it depends on the measured band
    // and the turn count — so it can't be a fixed spec value; every other mode's
    // targets are the constant ratios declared in its CompositionSpec.
    if (_compositionMode == CompositionMode.fibonacciSpiral) {
      // Single target: the spiral's eye (convergence point), as a band fraction
      // so it matches the dot the painter draws.
      if (_bandW <= 0 || _bandH <= 0) return null; // band not measured yet
      final eye = _goldenSpiralEyePx(
        Size(_bandW, _bandH),
        _spiralTurnsEffective,
        _CompositionPainter._goldenSpiralFill,
      );
      return [
        [eye.dx / _bandW, eye.dy / _bandH],
      ];
    }
    return kCompositionByMode[_compositionMode]!.powerPoints;
  }

  /// The active power points expressed in the same full-screen-normalised space
  /// as the detected face boxes. x is unchanged (full width); y is remapped into
  /// the camera-visible band so alignment is tested against the dots the user
  /// sees, not their old full-screen position.
  List<List<double>> _bandPowerPoints() {
    final pts = _modePowerPoints ?? _powerPoints;
    final double bandF = 1 - _topInsetFrac - _bottomInsetFrac;
    if (bandF <= 0.01) return pts; // insets not measured yet
    return [
      for (final p in pts) [p[0], _topInsetFrac + p[1] * bandF],
    ];
  }

  /// Plays the guide fade used by the spiral + triangle flip buttons: fades the
  /// guide out, applies [swap] at the invisible trough, then fades the new in.
  void _startGridFlip(VoidCallback swap) {
    final c = _gridFlipController;
    if (c == null || c.isAnimating) return;
    _gridFlipSwap = swap;
    _gridFlipSwapped = false;
    c.forward(from: 0);
  }

  /// Feed a fresh set of detections in as targets. Matches each detection to the
  /// nearest existing box (so identity is stable) and flags unmatched boxes to
  /// fade out. Does not touch displayed positions — the ticker animates those.
  void _updateFaceTargets(List<Map<String, dynamic>> fresh) {
    const double matchRadius = 0.22;
    final int now = DateTime.now().millisecondsSinceEpoch;
    // Only the boxes that exist *now* are match candidates; newly-added boxes
    // (created below) must not be matched against in the same pass. Capture the
    // count up-front so growing _faceBoxes can't push an index past `used`.
    final existing = _faceBoxes.length;
    final used = List<bool>.filled(existing, false);
    for (final b in _faceBoxes) {
      b.matched = false;
    }

    for (final d in fresh) {
      final w = d['w'] as double, h = d['h'] as double;
      final cx = (d['x'] as double) + w / 2;
      final cy = (d['y'] as double) + h / 2;
      final kox = (d['kox'] as double?) ?? 0;
      final koy = (d['koy'] as double?) ?? 0;
      final eyeSpanY = (d['eyeSpanY'] as double?) ?? 0;
      final hasEyes = (d['eyes'] as bool?) ?? false;

      int best = -1;
      double bestDist = matchRadius;
      for (var i = 0; i < existing; i++) {
        if (used[i]) continue;
        final b = _faceBoxes[i];
        final dist = math.sqrt(
          (cx - b.cx) * (cx - b.cx) + (cy - b.cy) * (cy - b.cy),
        );
        if (dist < bestDist) {
          bestDist = dist;
          best = i;
        }
      }

      if (best >= 0) {
        used[best] = true;
        final b = _faceBoxes[best];
        b.tcx = cx;
        b.tcy = cy;
        b.tw = w;
        b.th = h;
        b.keyOffX = kox;
        b.keyOffY = koy;
        b.eyeSpanY = eyeSpanY;
        b.hasEyes = hasEyes;
        b.matched = true;
        b.lastSeenMs = now;
      } else {
        final nb =
            _FaceBox(cx, cy, w, h, now) // new — fades/scales in
              ..keyOffX = kox
              ..keyOffY = koy
              ..eyeSpanY = eyeSpanY
              ..hasEyes = hasEyes;
        _faceBoxes.add(nb);
      }
    }

    // ── Alignment (Rule of Thirds / Phi Grid intersections, Spiral eye) ─────
    // Only in an alignment mode: flag each box with the target point it sits on
    // (if any), and fire a haptic the moment a box becomes newly aligned.
    final align = _modePowerPoints != null;
    // Target points remapped into the band the painter draws them in, so the
    // alignment test matches the dots on screen. May be 4 (grids) or 1 (spiral).
    final pp = _bandPowerPoints();
    // Top grid line's y (upper power-point row) for the eye-level check — only
    // Rule of Thirds / Phi Grid have a meaningful "eyes on the top line".
    final bool eyeLineMode =
        _compositionMode == CompositionMode.ruleOfThirds ||
        _compositionMode == CompositionMode.goldenSection;
    final double topLineY = (eyeLineMode && pp.isNotEmpty)
        ? pp.map((p) => p[1]).reduce(math.min)
        : -1;
    bool newlyPerfect = false;
    bool newlyEyeLevel = false;
    for (final b in _faceBoxes) {
      int near = -1;
      bool perfect = false;
      if (align && b.matched) {
        final double halfW = b.tw / 2, halfH = b.th / 2;
        final double mx = halfW * (1 + _alignMargin);
        final double my = halfH * (1 + _alignMargin);
        // Align on the eye key point (box centre + offset) — the portrait rule
        // places the eyes, not the face box, on the target.
        final double keyX = b.tcx + b.keyOffX;
        final double keyY = b.tcy + b.keyOffY;
        double bestD = double.infinity;
        for (var i = 0; i < pp.length; i++) {
          final dx = pp[i][0] - keyX;
          final dy = pp[i][1] - keyY;
          // Inside the box (+margin) → counts as "almost".
          if (dx.abs() <= mx && dy.abs() <= my) {
            final d = dx * dx + dy * dy;
            if (d < bestD) {
              bestD = d;
              near = i;
            }
          }
        }
        // "Perfect" = the chosen point sits near the eye key point (within
        // _perfectFrac of the box half-size, radially).
        if (near >= 0) {
          final nx = (pp[near][0] - keyX) / (halfW <= 0 ? 1 : halfW);
          final ny = (pp[near][1] - keyY) / (halfH <= 0 ? 1 : halfH);
          perfect = (nx * nx + ny * ny) <= _perfectFrac * _perfectFrac;
        }
      }
      // Eyes on the top grid line ("eye level"): both eyes within a thin band of
      // the line (level head + correct height) — the portrait rule, less strict
      // than a full on-the-point "Perfect".
      bool eyeLevel = false;
      if (eyeLineMode && b.matched && b.hasEyes) {
        const double tol = 0.018; // ~1.8% of screen height
        final double eyeY = b.tcy + b.keyOffY;
        eyeLevel = (eyeY - topLineY).abs() < tol && b.eyeSpanY < tol * 1.6;
      }
      // Haptic on the transition into a fresh perfect / eye-level.
      if (perfect && !b.perfect) newlyPerfect = true;
      if (eyeLevel && !b.eyeLevel) newlyEyeLevel = true;
      b.intersection = near;
      b.perfect = perfect;
      b.eyeLevel = eyeLevel;
    }
    if (newlyPerfect || newlyEyeLevel) {
      _haptic('alignmentPing', intensity: 1.0);
    }

    // Drive the hint via a notifier — 0 none, 1 almost (in box), 2 perfect
    // (near centre). Only the hint rebuilds, so flip-flops can't hurt FPS.
    int level = 0;
    if (align) {
      bool anyPerfect = false, anyEyeLevel = false, anyAlmost = false;
      for (final b in _faceBoxes) {
        if (!b.matched) continue;
        if (b.perfect) anyPerfect = true;
        if (b.eyeLevel) anyEyeLevel = true;
        if (b.intersection >= 0) anyAlmost = true;
      }
      // Perfect (on a point) > Eye level (on the top line) > Almost.
      level = anyPerfect
          ? 2
          : anyEyeLevel
          ? 3
          : (anyAlmost ? 1 : 0);
    }
    // Losing "perfect" gets a barely-there tick — drift is felt, not punished
    // (the reward for LANDING it stays the big alignmentPing above).
    if (level < 2 && _alignLevel.value >= 2) HapticFeedback.selectionClick();
    _alignLevel.value = level;

    if (_faceBoxes.isNotEmpty && !(_faceAnim?.isAnimating ?? false)) {
      _lastTickMs = DateTime.now().millisecondsSinceEpoch;
      _faceAnim?.repeat();
    }
  }

  /// Per-frame easing of displayed boxes toward targets + opacity fades.
  void _tickFaceBoxes() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final dt = ((now - _lastTickMs).clamp(1, 100)) / 1000.0;
    _lastTickMs = now;

    // Time-constant easing (frame-rate independent). Smaller tau = snappier.
    final posK = 1 - math.exp(-dt / 0.06); // position glide
    final opK = 1 - math.exp(-dt / 0.08); // opacity/appear fade

    // ── Gyro dead-reckoning ─────────────────────────────────────────────────
    // Shift every box AND its target by the camera pan integrated since the
    // last tick: the brackets ride the hand in real time, and detection only
    // has to correct the (small) residual — subject motion, not camera motion.
    final double gdx = _panTotX - _panTickX;
    final double gdy = _panTotY - _panTickY;
    _panTickX = _panTotX;
    _panTickY = _panTotY;
    if (gdx != 0 || gdy != 0) {
      for (final b in _faceBoxes) {
        b.cx += gdx;
        b.tcx += gdx;
        b.cy += gdy;
        b.tcy += gdy;
      }
    }

    // Grace window: a box that briefly stops matching (ML Kit drops the odd
    // frame) holds its position + opacity rather than flickering out. It only
    // fades once it's been unseen for longer than this.
    const int graceMs = 300;
    _faceBoxes.removeWhere((b) => !b.matched && b.opacity < 0.02);
    final pTarget = [0.0, 0.0, 0.0, 0.0];
    for (final b in _faceBoxes) {
      // Adaptive position easing: a soft time-constant when the box is near
      // its target (kills detector jitter while composing), snapping tighter
      // as the error grows (fast subjects, fresh locks) so it never trails.
      final double err =
          (b.tcx - b.cx).abs() +
          (b.tcy - b.cy).abs() +
          ((b.tw - b.w).abs() + (b.th - b.h).abs()) * 0.5;
      final double tau = ui.lerpDouble(
        0.085,
        0.028,
        (err / 0.10).clamp(0.0, 1.0),
      )!;
      final double pk = 1 - math.exp(-dt / tau);
      b.cx += (b.tcx - b.cx) * pk;
      b.cy += (b.tcy - b.cy) * pk;
      b.w += (b.tw - b.w) * pk;
      b.h += (b.th - b.h) * pk;
      final bool alive = b.matched || (now - b.lastSeenMs) <= graceMs;
      final targetOpacity = alive ? 1.0 : 0.0;
      b.opacity += (targetOpacity - b.opacity) * opK;
      b.appear += (1.0 - b.appear) * opK;
      // Alignment glow: full for "perfect", softer for "almost" (in box only).
      final alignTarget = b.perfect ? 1.0 : (b.intersection >= 0 ? 0.45 : 0.0);
      b.alignGlow += (alignTarget - b.alignGlow) * opK;
      if (b.intersection >= 0 && b.opacity > 0.3) {
        pTarget[b.intersection] = math.max(
          pTarget[b.intersection],
          b.opacity * (b.perfect ? 1.0 : 0.5),
        );
      }
    }
    // Ease each power point's glow toward whether a box is on it.
    for (var i = 0; i < 4; i++) {
      _powerGlow[i] += (pTarget[i] - _powerGlow[i]) * opK;
    }

    // ── Horizon easing (None-mode test) ───────────────────────────────────────
    // Ease the displayed line toward the confident target and fade it in/out, so
    // motion is smooth regardless of the (slower, occasionally jumpy) detector.
    if (_compositionMode != CompositionMode.horizonGrid) _hzActive = false;
    if (_hzTAngle != null) {
      if (!_hzInit) {
        // Seed at the target on (re)appear → fades IN in place, no slide-in.
        _hzDAngle = _hzTAngle!;
        _hzDAx = _hzTAx!;
        _hzDAy = _hzTAy!;
        _hzInit = true;
      } else {
        _hzDAngle = _lerpAngle(_hzDAngle, _hzTAngle!, posK);
        _hzDAx += (_hzTAx! - _hzDAx) * posK;
        _hzDAy += (_hzTAy! - _hzDAy) * posK;
      }
    }
    _hzDOp += ((_hzActive ? 1.0 : 0.0) - _hzDOp) * opK;

    // Alignment of the displayed line vs the golden guide: near it (proximity)
    // AND level (small angle). Same value feeds the guide-glow, the message
    // bubble level, and the haptic — one source of truth.
    final double guideYn =
        _topInsetFrac +
        (1 - _topInsetFrac - _bottomInsetFrac) *
            _CompositionPainter._horizonGuideRatio;
    // `aligned` (0..1) drives only the guide-glow, so it ramps smoothly as the
    // line approaches (within ~6% it starts glowing). The actual "Level" verdict
    // is a much stricter explicit check below.
    final double dyGuide = (_hzDAy - guideYn).abs();
    final double prox = (1 - dyGuide / 0.06).clamp(0.0, 1.0);
    final double levelness = (1 - _hzDAngle.abs() / 0.09).clamp(0.0, 1.0);
    final double aligned = prox * levelness * _hzDOp.clamp(0.0, 1.0);

    if (_hzInit && (_hzActive || _hzDOp > 0.01)) {
      _horizon.value = (
        angle: _hzDAngle,
        ax: _hzDAx,
        ay: _hzDAy,
        op: _hzDOp.clamp(0.0, 1.0),
        aligned: aligned,
        // Signed offset of the true horizon from the best-spot guide (normalised):
        // < 0 → true horizon is above the guide (nudge the phone up); > 0 → below.
        dy: _hzDAy - guideYn,
      );
    } else {
      if (_horizon.value != null) _horizon.value = null;
      if (!_hzActive) _hzInit = false; // next appearance seeds fresh
    }

    // Message-bubble level + haptic on the rising edge into "Level". STRICT now:
    // the line must sit within ~2 mm of the guide (≈1.5% of the screen) and be
    // level. Tiny hysteresis (hold to ~3.5 mm) only stops 1-frame flicker right
    // at the edge — it won't feel lenient.
    if (_compositionMode == CompositionMode.horizonGrid) {
      final bool isLevel = _hzDAngle.abs() < 0.06; // ~3.4°
      final bool enter = dyGuide < 0.015 && isLevel; // ~2 mm
      final bool hold = dyGuide < 0.024 && isLevel; // ~3.5 mm
      final int lvl = _hzDOp <= 0.4
          ? 0
          : ((_hzPrevLevel == 2 ? hold : enter) ? 2 : 1);
      if (lvl != _hzLevel.value) _hzLevel.value = lvl;
      if (lvl == 2 && _hzPrevLevel != 2) {
        _haptic('alignmentPing', intensity: 1.0);
      } else if (lvl != 2 && _hzPrevLevel == 2) {
        // Losing "Level" gets a barely-there tick — drift felt, not punished.
        HapticFeedback.selectionClick();
      }
      _hzPrevLevel = lvl;

      // Zero-cross detent: arm once the line has tilted past ~3°, fire one
      // crisp tick the instant it sweeps through 0° — you can level the phone
      // by feel alone — then re-arm on the next real tilt.
      if (_hzDOp > 0.4) {
        if (_hzDAngle.abs() > 0.05) _hzZeroArmed = true;
        if (_hzZeroArmed &&
            _hzZeroPrev != 0 &&
            _hzDAngle != 0 &&
            (_hzDAngle < 0) != (_hzZeroPrev < 0)) {
          _hzZeroArmed = false;
          HapticFeedback.selectionClick();
        }
        _hzZeroPrev = _hzDAngle;
      }
    } else if (_hzLevel.value != 0) {
      _hzLevel.value = 0;
      _hzPrevLevel = 0;
    }

    // Keep ticking while anything is visible or any glow is still fading.
    final glowActive = _powerGlow.any((g) => g > 0.02);
    final hzVisible = _hzActive || _hzDOp > 0.02;
    if (_faceBoxes.isEmpty && !glowActive && !hzVisible) _faceAnim?.stop();
  }

  /// Start the shared 60fps ticker if it isn't already running (the horizon
  /// overlay needs it even when there are no face boxes to animate).
  void _ensureHorizonTicking() {
    if (!(_faceAnim?.isAnimating ?? false)) {
      _lastTickMs = DateTime.now().millisecondsSinceEpoch;
      _faceAnim?.repeat();
    }
  }

  /// Opens the in-app gallery (a glassy grid → tap into the full-screen pager).
  /// Detection is paused while it's on top, then resumed on return.
  Future<void> _openGalleryViewer() async {
    try {
      // Fast path: the album is pre-warmed (by _loadLatestThumbnail), so push
      // immediately — no async query between the swipe/tap and the slide-up.
      var album = _galleryAlbum;
      var count = _galleryCount;
      if (album == null) {
        // Cold path (first open before the prewarm landed): resolve once.
        if (!await _ensurePhotoPermission()) return;
        final albums = await PhotoManager.getAssetPathList(
          type: RequestType.common, // photos + videos
          hasAll: true,
          onlyAll: true,
        );
        if (albums.isEmpty || !mounted) return;
        album = albums.first;
        count = await album.assetCountAsync;
        _galleryAlbum = album;
        _galleryCount = count;
      }
      if (count == 0 || !mounted) return;
      final theAlbum = album; // non-null after the block above
      final theCount = count;

      _stopImageStream(); // no need to detect while the gallery covers the screen
      await Navigator.of(context).push(
        PageRouteBuilder(
          // Slide up like a sheet. Opaque so the live camera isn't rendered
          // behind the whole gallery (that was tanking the frame rate).
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 260),
          pageBuilder: (_, _, _) =>
              GalleryGridPage(album: theAlbum, count: theCount),
          transitionsBuilder: (_, anim, _, child) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                ),
            child: child,
          ),
        ),
      );
      if (!mounted) return;
      await _startImageStream();
      _loadLatestThumbnail(); // refresh in case anything changed
    } catch (e) {
      debugLog('Error opening gallery: $e');
    }
  }

  Future<void> _toggleFlash() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    FlashMode newMode;
    switch (_flashMode) {
      case FlashMode.off:
        newMode = FlashMode.auto;
        break;
      case FlashMode.auto:
        newMode = FlashMode.always;
        break;
      case FlashMode.always:
        newMode = FlashMode.off;
        break;
      default:
        newMode = FlashMode.off;
    }

    try {
      await _controller!.setFlashMode(newMode);
      setState(() {
        _flashMode = newMode;
      });
    } catch (e) {
      debugLog('Error setting flash mode: $e');
    }
  }

  void _toggleResolution() async {
    ResolutionPreset newResolution;
    if (_resolution == ResolutionPreset.veryHigh) {
      newResolution = ResolutionPreset.max; // 48MP
    } else {
      newResolution = ResolutionPreset.veryHigh; // 24MP
    }

    // Show loading while reinitializing
    setState(() {
      _isInitialized = false;
    });

    // Reinitialize camera with new resolution
    await _controller?.dispose();
    _controller = CameraController(
      _cameras![0],
      newResolution,
      enableAudio: true,
    );
    await _controller!.initialize();
    await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
    await _controller!.setFlashMode(_flashMode);

    _resolution = newResolution;
    _recordRefAspect();
    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
      // The fresh controller isn't streaming — re-arm the detection frame stream,
      // otherwise face/eye detection silently dies after a resolution switch.
      await _startImageStream();
    }
  }

  void _toggleImageFormat() {
    setState(() {
      _imageFormat = _imageFormat == 'HEIF' ? 'RAW' : 'HEIF';
    });
  }

  /// Reads the laid-out panel heights into [_topInset]/[_bottomInset] so the
  /// composition grid can be clipped to the camera-visible area. Guarded by an
  /// epsilon so it rebuilds at most once after the panels settle.
  void _measurePanels() {
    if (!mounted) return;
    final topBox =
        _topPanelKey.currentContext?.findRenderObject() as RenderBox?;
    final botBox =
        _bottomPanelKey.currentContext?.findRenderObject() as RenderBox?;
    final double top = topBox?.size.height ?? 0;
    final double bot = botBox?.size.height ?? 0;
    if ((top - _topInset).abs() > 0.5 || (bot - _bottomInset).abs() > 0.5) {
      final Size screen = MediaQuery.of(context).size;
      final double screenH = screen.height;
      setState(() {
        _topInset = top;
        _bottomInset = bot;
        _topInsetFrac = screenH > 0 ? top / screenH : 0;
        _bottomInsetFrac = screenH > 0 ? bot / screenH : 0;
        _bandW = screen.width;
        _bandH = screenH - top - bot;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measurePanels());
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Live camera preview with tap-to-focus and pinch-to-zoom
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                onTapUp: (d) => _onTapToFocus(d, constraints),
                onLongPressStart: (d) =>
                    _focusAt(d.localPosition, constraints, locked: true),
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: _buildPreview(),
              ),
            ),
          ),

          // Focus ring — corner brackets + (when locked) an AE/AF badge.
          if (_focusPoint != null)
            Positioned(
              left: _focusPoint!.dx - 36,
              top: _focusPoint!.dy - 36,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _focusShown ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 240),
                  child: AnimatedBuilder(
                    animation: _focusRingController!,
                    builder: (context, _) => Transform.scale(
                      scale: _focusRingScale.value,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 72,
                            height: 72,
                            child: CustomPaint(
                              painter: _FocusBracketPainter(gold: kGold),
                            ),
                          ),
                          if (_aeAfLocked) ...[
                            const SizedBox(height: 5),
                            const Text(
                              'AE/AF LOCK',
                              style: TextStyle(
                                color: kGold,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w400,
                                letterSpacing: 2.0,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Exposure slider — appears to the right of the focus ring.
          if (_focusPoint != null && _maxExposure > _minExposure)
            Positioned(
              left: (_focusPoint!.dx + 36 + 12).clamp(
                8.0,
                MediaQuery.of(context).size.width - 44,
              ),
              top: (_focusPoint!.dy - 52).clamp(
                _topInset + 8,
                MediaQuery.of(context).size.height - 220,
              ),
              // Readout only — adjustment happens by sliding on the screen, so
              // any drag here passes through to the preview's gesture handler.
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _focusShown ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 240),
                  child: _buildExposureSlider(104),
                ),
              ),
            ),

          // Composition guide overlay — grid + power points + detection boxes.
          // RepaintBoundary isolates its 60fps ticker repaints from the camera
          // preview and panels, so only this layer re-rasterises each frame.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _gridVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOut,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _CompositionPainter(
                          _paintedMode, // locked modes render as None
                          glowSegs: _glowSegMap.values.toList(),
                          faceBoxes: _faceBoxes,
                          powerGlow: _powerGlow,
                          topInset: _topInset,
                          bottomInset: _bottomInset,
                          spiralTurns: _spiralTurnsEffective,
                          spiralFlipped: _spiralFlipped,
                          gridFlip: _gridFlipController,
                          trianglesFlipped: _trianglesFlipped,
                          vFlipped: _vFlipped,
                          focalTurns: _focalTurns,
                          diagonalTurns: _diagonalTurns,
                          lTurns: _lTurns,
                          lFlipped: _lFlipped,
                          cross: _crossN,
                          aspect: _aspectRatios[_aspectIndex].ratio,
                          horizon: _horizon,
                          deviceTurns: _deviceTurns,
                          eyePoints: _eyePoints,
                          repaint: Listenable.merge([
                            _faceAnim,
                            _horizon,
                            _eyeRepaint,
                            _gridFlipController,
                            _focalAnim,
                            _crossN,
                          ]),
                        ),
                      ),
                    ),
                    // Attitude dial in its OWN boundary → the ~50 Hz gravity
                    // updates repaint only this small dial, never the grid above.
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _LevelDialPainter(
                          _levelAttitude,
                          _bottomInset,
                          topInset: _topInset,
                          deviceTurns: _deviceTurns,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Phily Pro lock — shown when the active mode is gated (free trial
          // over, not subscribed). Tap to open the paywall. Doesn't block the
          // belt/shutter (the card is the only hit target), so swiping back to
          // None still works.
          if (_modeLocked && _isInitialized && !_isRecording)
            Positioned.fill(
              child: Align(
                alignment: const Alignment(0, -0.15),
                child: GestureDetector(
                  onTap: () => showPhilyProPaywall(context),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(kRadiusLg),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 20,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(kRadiusLg),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.12),
                              Colors.black.withValues(alpha: 0.55),
                            ],
                          ),
                          border: Border.all(
                            color: kGold.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Gold lock badge.
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: kGold.withValues(alpha: 0.14),
                                border: Border.all(
                                  color: kGold.withValues(alpha: 0.5),
                                ),
                              ),
                              child: const Icon(
                                Icons.lock_rounded,
                                color: kGold,
                                size: 20,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'PHILY PRO',
                              style: brandLabel(
                                size: 10,
                                color: kGold.withValues(alpha: 0.75),
                                letterSpacing: 3,
                              ),
                            ),
                            const SizedBox(height: 6),
                            // Mode name in the editorial serif.
                            Text(
                              _compositionMode.label,
                              style: brandDisplay(
                                size: 22,
                                weight: FontWeight.w500,
                                color: kPaper,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Your free trial has ended',
                              style: brandLabel(
                                size: 11.5,
                                weight: FontWeight.w400,
                                color: kPaper.withValues(alpha: 0.5),
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Unlock — gilded gradient with a soft glow.
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 11,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(kRadiusMd),
                                // Champagne-lit metal — same three-stop as the
                                // paywall CTA and belt pill, so every gold
                                // button reads as the same polished metal.
                                gradient: const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [kGoldLit, kGold, kGoldDeep],
                                  stops: [0.0, 0.45, 1.0],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: kGold.withValues(alpha: 0.35),
                                    blurRadius: 18,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: const Text(
                                'Unlock with Phily Pro',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Cross composition: a tiny, very responsive vertical slider to nudge
          // the crossbar up/down within the fixed vertical arm. Right side, centred.
          if (_paintedMode == CompositionMode.cross &&
              _isInitialized &&
              !_isRecording &&
              _gridVisible)
            Positioned(
              right: 14,
              top: 0,
              bottom: 0,
              child: Center(child: _buildCrossSlider()),
            ),

          // Cross composition: glowing rotate handle at the arm tip — grab + spin.
          if (_paintedMode == CompositionMode.cross &&
              _isInitialized &&
              !_isRecording &&
              _gridVisible)
            _buildCrossRotateHandle(),

          // Top settings panel
          Positioned(
            key: const ValueKey('topPanel'),
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopSettingsPanel(),
          ),

          // Trial countdown — a small gilded chip under the top panel while
          // the free trial runs (tap → paywall). Without it, the lock card
          // would arrive unannounced on day eight. Hidden while recording.
          if (PhilyPro.instance.showTrialBadge && !_isRecording)
            Positioned(
              top:
                  (_topInset > 0
                      ? _topInset
                      : MediaQuery.of(context).padding.top + 56) +
                  12,
              left: 12,
              child: _buildTrialChip(),
            ),

          // Grid on/off toggle — dims the overlay for a clean frame.
          if (_isInitialized && !_isRecording)
            Positioned(
              bottom: (_bottomInset > 0 ? _bottomInset : 160) + 14,
              right: 16,
              child: _buildGridToggle(),
            ),

          // Zoom level indicator — thin right-edge tag. Sits dead-centre, but
          // lifts above the cross slider (also right-centred) when that's shown,
          // so the two never overlap on any screen size. Zoom-notifier-driven
          // (visibility included) so pinches never rebuild the page.
          Positioned(
            top: 0,
            bottom: 0,
            right: 12,
            child: ValueListenableBuilder<double>(
              valueListenable: _zoomN,
              builder: (context, zoom, _) => zoom <= _minZoom + 0.05
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: _paintedMode == CompositionMode.cross
                          ? const Alignment(0, -0.5)
                          : Alignment.center,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 4,
                          ),
                          decoration: glassChipDecoration(radius: 7),
                          child: Text(
                            _zoomLabel(zoom),
                            style: const TextStyle(
                              color: kGold,
                              fontSize: 11,
                              fontWeight: FontWeight.w300,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),

          // Bottom controls overlay
          Positioned(
            key: const ValueKey('bottomControls'),
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Gold-leaf edge where the chrome meets the preview.
                const GildedHairline(opacity: 0.55),
                _frostedChrome(
                  Container(
                    key: _bottomPanelKey,
                    padding: const EdgeInsets.only(
                      left: 20,
                      right: 20,
                      bottom: 16,
                      top: 4,
                    ),
                    decoration: _chromeDecoration(top: false),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Composition guide scrollable belt
                        SizedBox(
                          height: 45,
                          child: PageView.builder(
                            controller: _compositionPageController,
                            onPageChanged: (index) {
                              HapticFeedback.selectionClick();
                              setState(() {
                                _currentCompositionIndex = index;
                                _compositionMode = _compositionModes[index];
                                // Every mode starts fresh on (re-)entry: turn/flip
                                // orientations reset to their defaults.
                                _resetModeOrientations();
                                if (_compositionMode == CompositionMode.cross) {
                                  _resetCross();
                                }
                              });
                              if (!_modeLocked) {
                                _showCompositionTip(); // "best for" bubble (~3s)
                              } else {
                                _dismissTip();
                              }
                              _syncFocalAnim(); // run the bubble clock only in Focal Mass
                              _syncImageStream(); // stream/ML only in detection modes
                            },
                            itemCount: _compositionModes.length,
                            itemBuilder: (context, index) {
                              // Rebuild each label as the belt scrolls, driving its
                              // pill + scale off the LIVE fractional page position so
                              // the transition is continuous, not a settle-point swap.
                              return AnimatedBuilder(
                                animation: _compositionPageController,
                                builder: (context, _) {
                                  final double page =
                                      (_compositionPageController.hasClients &&
                                          _compositionPageController
                                              .position
                                              .haveDimensions)
                                      ? _compositionPageController.page!
                                      : _currentCompositionIndex.toDouble();
                                  // 1 at centre → 0 a full page away.
                                  final double t = (1.0 - (index - page).abs())
                                      .clamp(0.0, 1.0);
                                  return GestureDetector(
                                    // Tap a mode to jump (in addition to swiping);
                                    // opaque so the whole slot is tappable.
                                    // Long-press → the mode's guide sheet.
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => _goToCompositionIndex(index),
                                    onLongPress: () {
                                      _dismissTip();
                                      showCompositionGuide(
                                        context,
                                        _compositionModes[index],
                                      );
                                    },
                                    child: Center(
                                      child: Transform.scale(
                                        scale:
                                            0.9 +
                                            0.1 * Curves.easeOut.transform(t),
                                        child: _buildCompositionButton(
                                          _compositionModes[index].label,
                                          t,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                        if (MediaQuery.of(context).orientation ==
                            Orientation.portrait) ...[
                          const SizedBox(height: 2),
                          if (_isInitialized) _buildZoomMeter(),
                          const SizedBox(height: 10),
                        ] else
                          const SizedBox(height: 8),
                        // Camera controls row. Flexible side regions keep the capture
                        // button dead-centre even when the right slot holds two
                        // controls (e.g. the spiral's turn + flip buttons).
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Gallery button (left, centred with capture button)
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: GestureDetector(
                                  onTap: _isRecording
                                      ? null
                                      : _openGalleryViewer,
                                  child: Container(
                                    width: 52,
                                    height: 52,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.30,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        kRadiusMd,
                                      ),
                                      // A softly gilded frame around the last shot, to
                                      // rhyme with the gold capture ring beside it.
                                      border: Border.all(
                                        color: kGold.withValues(alpha: 0.34),
                                        width: 1.0,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.30,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: _latestThumbnail != null
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              kRadiusMd - 1,
                                            ),
                                            child: Image.memory(
                                              _latestThumbnail!,
                                              fit: BoxFit.cover,
                                            ),
                                          )
                                        : _rotated(
                                            Icon(
                                              Icons.photo_library_outlined,
                                              color: kPaper.withValues(
                                                alpha: 0.6,
                                              ),
                                              size: 24,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ),

                            // Capture button (center) - tap for photo, hold for video
                            _buildGlassCaptureButton(),

                            // Right slot: mode-specific control(s) — e.g. spiral
                            // turn + flip — anchored right, mirroring the gallery.
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: _buildRightSlotControl(),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Recording timer — pill badge, matches UI design language
          if (_isRecording)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedBuilder(
                  animation: _glowAnimation!,
                  builder: (_, _) {
                    final pulse = _glowAnimation?.value ?? 1.0;
                    final e = _recordingStopwatch.elapsed;
                    final m = e.inMinutes
                        .remainder(60)
                        .toString()
                        .padLeft(2, '0');
                    final s = e.inSeconds
                        .remainder(60)
                        .toString()
                        .padLeft(2, '0');
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                          width: 0.5,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Pulsing red dot — uses the existing glow animation
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF3B30),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFFFF3B30,
                                  ).withValues(alpha: 0.65 * pulse),
                                  blurRadius: 7,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '$m:$s',
                            style: const TextStyle(
                              color: kGold,
                              fontSize: 13,
                              fontWeight: FontWeight.w300,
                              letterSpacing: 3.0,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),

          // Capture animation: the shot flies from centre-frame straight into
          // the gallery thumbnail (bottom-left), shrinking and fading away.
          if (_showBounceAnimation && _animatingMedia != null)
            AnimatedBuilder(
              animation: _bounceController!,
              builder: (context, child) {
                final size = MediaQuery.of(context).size;
                final fly = Curves.easeInOutCubic.transform(
                  _bounceController!.value,
                );

                // Start card (centred, portrait) → gallery-thumb target.
                final startW = size.width * 0.6;
                final startH = startW * 4 / 3;
                const endW = 50.0, endH = 50.0;
                final startCx = size.width / 2;
                final startCy = size.height * 0.5; // distance from bottom
                const endCx = 46.0, endCy = 64.0; // ~gallery-thumb centre

                final w = ui.lerpDouble(startW, endW, fly)!;
                final h = ui.lerpDouble(startH, endH, fly)!;
                final cx = ui.lerpDouble(startCx, endCx, fly)!;
                final cy = ui.lerpDouble(startCy, endCy, fly)!;
                final radius = ui.lerpDouble(20, 8, fly)!;

                // Quick pop-in, then dissolve into the thumbnail at the end.
                final appear = (_bounceController!.value / 0.12).clamp(
                  0.0,
                  1.0,
                );
                final tail = ((fly - 0.82) / 0.18).clamp(0.0, 1.0);
                final opacity = (Curves.easeOut.transform(appear) * (1 - tail))
                    .clamp(0.0, 1.0);

                return Positioned(
                  left: cx - w / 2,
                  bottom: cy - h / 2,
                  child: Opacity(
                    opacity: opacity,
                    child: Container(
                      width: w,
                      height: h,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.9),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 18,
                            spreadRadius: 1,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius - 2),
                        child: Image.file(_animatingMedia!, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                );
              },
            ),

          // Vertical zoom meter — landscape only, right edge
          if (_isInitialized &&
              MediaQuery.of(context).orientation == Orientation.landscape)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Center(child: _buildVerticalZoomMeter()),
            ),

          // Alignment / horizon hint — top centre, below panel. Shown for the
          // alignment modes (power points) and Horizon Grid. It shares this spot
          // with the "best for" tip bubble, so it CROSS-FADES in as the tip
          // retracts (gated on !_showTip via the switcher child, not the `if`) —
          // a hard pop-in here used to mask the tip's upward retract animation.
          if ((_modePowerPoints != null ||
                  _compositionMode == CompositionMode.horizonGrid) &&
              !_isRecording &&
              !_modeLocked && // locked → the Pro card is the message, not a hint
              _gridVisible)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedAlign(
                  alignment: _userTopAlign,
                  duration: const Duration(milliseconds: 340),
                  curve: Curves.easeOutCubic,
                  child: AnimatedPadding(
                    padding: _bannerInset(
                      MediaQuery.of(context).padding.top + 86,
                    ),
                    duration: const Duration(milliseconds: 340),
                    curve: Curves.easeOutCubic,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      transitionBuilder: (child, anim) =>
                          FadeTransition(opacity: anim, child: child),
                      // No keys — the types differ, and explicit keys crash the
                      // switcher with "Duplicate keys" if _showTip flips twice
                      // within 280ms (fast belt scrolling).
                      child: _showTip
                          ? const SizedBox.shrink()
                          : RepaintBoundary(
                              child: ValueListenableBuilder<int>(
                                valueListenable:
                                    _compositionMode ==
                                        CompositionMode.horizonGrid
                                    ? _hzLevel
                                    : _alignLevel,
                                builder: (_, level, _) => _bannerRotated(
                                  _buildCompositionHint(level),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),

          // "Best for" tip bubble — sits just below the panel in portrait, and
          // follows the rotation to the top edge of the user's view in landscape,
          // centred on the full screen with a gap off the edge.
          Positioned.fill(
            child: AnimatedAlign(
              alignment: _userTopAlign,
              duration: const Duration(milliseconds: 340),
              curve: Curves.easeOutCubic,
              child: AnimatedPadding(
                padding: _bannerInset(
                  (_topInset > 0
                          ? _topInset
                          : MediaQuery.of(context).padding.top + 56) +
                      2,
                ),
                duration: const Duration(milliseconds: 340),
                curve: Curves.easeOutCubic,
                child: _bannerRotated(_buildTipBubble()),
              ),
            ),
          ),

          // Shutter flash effect (on top of everything)
          if (_showShutterFlash)
            Positioned.fill(child: Container(color: Colors.white)),

          // FPS counter (testing) — top right. Disabled by default; toggle kShowFPS.
          if (kPhilyDebug && kShowFPS)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              right: 12,
              child: const IgnorePointer(child: _FpsOverlay()),
            ),

          // Debug-only Pro/trial control.
          if (kPhilyDebug)
            Positioned(
              top: MediaQuery.of(context).padding.top + 92,
              left: 12,
              child: GestureDetector(
                onTap: _showProDebugMenu,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.7),
                    ),
                  ),
                  child: const Text(
                    'DBG',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),

          // Launch render-pipeline warm-up — paints the guide overlay's heavy
          // (blur/gradient) draw ops almost-invisibly so Impeller compiles them
          // during launch, not on the first guide swipe. Removed after ~1.2s.
          if (_warming)
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.004,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                        painter: _CompositionPainter(
                          CompositionMode.ruleOfThirds,
                          faceBoxes: [_warmFace],
                          powerGlow: const [1.0, 1.0, 1.0, 1.0],
                          eyePoints: const [
                            Offset(0.45, 0.4),
                            Offset(0.55, 0.4),
                          ],
                        ),
                      ),
                      // Warm the dial's blur pipeline too (it's now its own layer).
                      CustomPaint(
                        painter: _LevelDialPainter(_warmAttitude, _bottomInset),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Branded loading state — full-screen, shown whenever the preview
          // isn't live: first launch, resolution switch (_isInitialized=false)
          // AND lens switches (_controller briefly null). Same loader everywhere
          // for a consistent feel. Crossfades out the instant the preview
          // returns; absorbs taps while loading so the shutter can't fire early.
          Builder(
            builder: (_) {
              final bool loading =
                  _error == null && (!_isInitialized || _controller == null);
              return Positioned.fill(
                child: AbsorbPointer(
                  absorbing: loading,
                  // NOTE: deliberately NO keys on the children. The types
                  // differ, so the switcher still sees every change — but with
                  // explicit keys, a quick loading→ready→loading flip (lens
                  // switch re-inits in <450ms) puts two same-keyed children in
                  // the switcher's stack at once → "Duplicate keys" crash.
                  // Keyless children fall back to a unique per-entry key.
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    child: loading
                        ? const BrandedLoader()
                        : const SizedBox.shrink(),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// "Best for" bubble — a compact blurb shown on mode change. Auto-hides after
  /// 3s (timer in [_showCompositionTip]); swipe up to dismiss immediately. Both
  /// the drop-in and the dismiss glide vertically (it's clipped at the panel
  /// edge by the caller, so it reads as sliding out from / back behind the
  /// panel, iMessage-style).
  /// Where the frame's "top" is for the current device hold, so the advisory
  /// pills FOLLOW the rotation and sit along the edge that has become "up".
  /// Rotate the phone clockwise → its left edge becomes the top → pills go left.
  Alignment get _userTopAlign => switch (_deviceTurns & 3) {
    // Landscape: the banner is vertically centred on the physical edge; the y
    // offset nudges it along the user's horizontal (toward their left). The two
    // holds get opposite signs because their physical vertical axes are flipped.
    1 => const Alignment(-1, 0.08),
    2 => Alignment.bottomCenter,
    3 => const Alignment(1, -0.08),
    _ => Alignment.topCenter,
  };

  /// Like [_rotated] but with a LAYOUT rotation ([RotatedBox]) — a wide pill
  /// becomes a tall box, so [AnimatedAlign] can pin it flush to the top edge in
  /// landscape (Transform.rotate keeps the wide box and leaves it stuck mid-frame).
  Widget _bannerRotated(Widget child) =>
      RotatedBox(quarterTurns: (-_deviceTurns) % 4, child: child);

  /// Gap between an advisory banner and the "top" edge for the current hold.
  /// In portrait that's [portraitTop] (below the panel); rotated it's a small gap
  /// off the leading edge, so the banner floats clear of the screen edge.
  EdgeInsets _bannerInset(double portraitTop) {
    const double gap = 24;
    return switch (_deviceTurns & 3) {
      1 => const EdgeInsets.only(left: gap),
      2 => const EdgeInsets.only(bottom: gap),
      3 => const EdgeInsets.only(right: gap),
      // Portrait: a small right inset nudges the centred bubble left of dead
      // centre (half the inset), consistently regardless of the pill's width.
      _ => EdgeInsets.only(top: portraitTop, right: 8),
    };
  }

  Widget _buildTipBubble() {
    final tip = _compositionTip;
    final orient = _compositionOrientation; // Portrait / Landscape / Both
    final bool visible = _showTip && tip != null && !_isRecording;
    const gold = kGold;
    return IgnorePointer(
      ignoring: !visible,
      // Controller-driven so the entrance replays cleanly on every show — see
      // _showCompositionTip (forward-from-0) and _dismissTip (reverse). An
      // AnimatedSwitcher cross-faded in place on mode-to-mode changes, which
      // read as "no animation"; this always drops the fresh advice in.
      child: AnimatedBuilder(
        animation: _tipAnim,
        builder: (context, child) {
          final double t = Curves.easeOutCubic.transform(
            _tipAnim.value.clamp(0.0, 1.0),
          );
          if (t <= 0.001 || child == null) return const SizedBox.shrink();
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * -14), // drop in from just above
              child: Transform.scale(
                scale: 0.96 + 0.04 * t,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
          );
        },
        child: tip == null
            ? null
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) < 0) _dismissTip(); // swipe up
                },
                // Tap → the full guide for this mode (swipe up to dismiss).
                onTap: () {
                  _dismissTip();
                  showCompositionGuide(context, _compositionMode);
                },
                child: Padding(
                  // The app's shared frosted glass — same material as the
                  // gallery/paywall chrome (real blur + specular bloom + rim).
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: ConstrainedBox(
                    // Cap the width so long tips wrap to a tidy block and, when
                    // rotated for landscape, never overrun the screen edge.
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: GlassSurface(
                      borderRadius: BorderRadius.circular(kRadiusLg),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 11,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Gold eyebrow.
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.auto_awesome_rounded,
                                color: gold,
                                size: 11,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'BEST FOR',
                                style: brandLabel(
                                  size: 8.5,
                                  weight: FontWeight.w600,
                                  color: gold.withValues(alpha: 0.85),
                                  letterSpacing: 2.4,
                                ),
                              ),
                              // Portrait / Landscape / Both recommendation.
                              if (orient != null) ...[
                                const SizedBox(width: 9),
                                Icon(
                                  orient == 'Portrait'
                                      ? Icons.stay_current_portrait_rounded
                                      : orient == 'Landscape'
                                      ? Icons.stay_current_landscape_rounded
                                      : Icons.screen_rotation_rounded,
                                  color: gold.withValues(alpha: 0.7),
                                  size: 10,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  orient.toUpperCase(),
                                  style: brandLabel(
                                    size: 8.5,
                                    weight: FontWeight.w600,
                                    color: gold.withValues(alpha: 0.7),
                                    letterSpacing: 1.6,
                                  ),
                                ),
                              ],
                              // Tappable-ness affordance — the bubble opens
                              // the mode's full guide sheet.
                              const SizedBox(width: 9),
                              Text(
                                'GUIDE ›',
                                style: brandLabel(
                                  size: 8.5,
                                  weight: FontWeight.w700,
                                  color: kGoldLit.withValues(alpha: 0.95),
                                  letterSpacing: 1.6,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tip,
                            textAlign: TextAlign.center,
                            style: brandLabel(
                              size: 12,
                              weight: FontWeight.w400,
                              color: kPaper.withValues(alpha: 0.95),
                              letterSpacing: 0.2,
                            ).copyWith(height: 1.25),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  // Every hint appearance gets a FRESH key (level + sequence): with stable
  // per-level keys, a level flapping A→B→A within the switch duration puts two
  // same-keyed children in the AnimatedSwitcher's stack → "Duplicate keys" crash.
  int _hintSeq = 0;
  int _hintLastLevel = -1;

  /// Top hint for Rule of Thirds. Smoothly morphs between three states:
  ///   0 — translucent instruction pill
  ///   1 — "Almost" (subject's box is on a point, but off-centre)
  ///   2 — "Perfect" (point near the box centre), ambient breathing gold glow.
  Widget _buildCompositionHint(int level) {
    if (level != _hintLastLevel) {
      _hintLastLevel = level;
      _hintSeq++;
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 340),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0).animate(anim),
          child: child,
        ),
      ),
      child: KeyedSubtree(
        key: ValueKey('hint-$level#$_hintSeq'),
        child: switch (level) {
          2 => _perfectBadge(),
          3 => _eyeLevelBadge(),
          1 => _almostBadge(),
          _ => _instructionPill(),
        },
      ),
    );
  }

  /// Unified glassy message pill — the shared style for the on-screen alignment
  /// / horizon hint bubbles. [emphasis] tints text + border gold (the "Perfect"/
  /// "Level" state) and [breathe] adds a soft pulsing gold glow.
  ///
  /// NOTE: deliberately NO BackdropFilter. These pills are shown persistently
  /// over the live camera, so a real blur would re-rasterise every frame and
  /// crater FPS. A white→dark gradient fakes the frosted look cheaply.
  Widget _glassPill({
    required Key key,
    required IconData icon,
    required String text,
    bool emphasis = false,
    bool breathe = false,
  }) {
    const gold = kGold;
    Widget build(double pulse) {
      final Color textColor = emphasis ? gold : kPaper.withValues(alpha: 0.92);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadiusLg),
          // Same diagonal sheen→dark recipe as the app's GlassSurface (a touch
          // darker at the base for legibility, since there's no real blur here).
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.20),
              Colors.white.withValues(alpha: 0.06),
              Colors.black.withValues(alpha: 0.42),
            ],
            stops: const [0.0, 0.45, 1.0],
          ),
          border: Border.all(
            color: emphasis
                ? gold.withValues(alpha: 0.5 + 0.4 * pulse)
                : Colors.white.withValues(alpha: 0.35),
            width: emphasis ? 1.0 : 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: emphasis
                  ? gold.withValues(alpha: 0.12 + 0.22 * pulse)
                  : Colors.black.withValues(alpha: 0.30),
              blurRadius: emphasis ? 14 : 12,
              spreadRadius: emphasis ? 0.5 : 0,
              offset: emphasis ? Offset.zero : const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: emphasis
                  ? gold.withValues(alpha: 0.75 + 0.25 * pulse)
                  : gold,
              size: 14,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: brandLabel(
                  size: emphasis ? 12.5 : 11.5,
                  weight: emphasis ? FontWeight.w600 : FontWeight.w400,
                  color: textColor,
                  letterSpacing: emphasis ? 1.0 : 0.2,
                ).copyWith(height: 1.25),
              ),
            ),
          ],
        ),
      );
    }

    if (!breathe) return KeyedSubtree(key: key, child: build(0));
    // Soft breathe for the "Perfect"/"Level" state. Only alpha animates.
    return AnimatedBuilder(
      key: key,
      animation: _faceAnim!,
      builder: (context, _) {
        final t = DateTime.now().millisecondsSinceEpoch / 900.0;
        return build(0.5 + 0.5 * math.sin(t));
      },
    );
  }

  /// "Perfect"/"Level" — emphasised, gently breathing golden pill.
  Widget _perfectBadge() {
    final bool hz = _compositionMode == CompositionMode.horizonGrid;
    return _glassPill(
      key: const ValueKey('hint-perfect'),
      icon: Icons.check_circle_rounded,
      text: hz ? 'Level' : 'Perfect',
      emphasis: true,
      breathe: true,
    );
  }

  /// "Eye level perfect" — both eyes sitting on the top grid line (portrait rule).
  Widget _eyeLevelBadge() {
    return _glassPill(
      key: const ValueKey('hint-eyelevel'),
      icon: Icons.remove_red_eye_rounded,
      text: 'Eye level perfect',
      emphasis: true,
      breathe: true,
    );
  }

  /// "Almost" — calm pill nudging the subject/horizon into place.
  Widget _almostBadge() {
    final bool hz = _compositionMode == CompositionMode.horizonGrid;
    return _glassPill(
      key: const ValueKey('hint-almost'),
      icon: Icons.adjust_rounded,
      text: hz ? 'Almost — level it out' : 'Almost — centre it',
    );
  }

  /// Default instruction pill. Wording adapts to the mode's target: grid
  /// intersections, the spiral's eye, or the horizon guide line.
  Widget _instructionPill() {
    final (IconData, String) content = switch (_compositionMode) {
      CompositionMode.fibonacciSpiral => (
        Icons.flare_rounded,
        "Place your subject on the spiral's eye",
      ),
      CompositionMode.horizonGrid => (
        Icons.straighten_rounded,
        'Hold your phone completely straight',
      ),
      _ => (Icons.grid_3x3_rounded, 'Place your subject on an intersection'),
    };
    return _glassPill(
      key: const ValueKey('hint-instruction'),
      icon: content.$1,
      text: content.$2,
    );
  }

  /// The right-hand control slot in the camera row: a mode-specific button when
  /// one applies (spiral rotate / aspect-ratio cycle), else empty space sized to
  /// match the gallery button so the capture button stays centred.
  Widget _buildRightSlotControl() {
    final controls = kCompositionByMode[_compositionMode]!.controls;
    if (controls.contains(CompoControl.aspectCycle)) {
      return _buildAspectRatioButton();
    }
    // Flip sits to the left of turn (consistent across Spiral + L-Arrangement).
    final buttons = <Widget>[
      if (controls.contains(CompoControl.flip))
        _flipButtonFor(_compositionMode),
      if (controls.contains(CompoControl.turn))
        _turnButtonFor(_compositionMode),
    ];
    if (buttons.isEmpty) return const SizedBox(width: 52);
    if (buttons.length == 1) return buttons.single;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [buttons.first, const SizedBox(width: 10), buttons.last],
    );
  }

  /// The turn (rotate) control for [m] — the mode-specific button that toggles
  /// its own state/glyph. Empty for modes without one.
  Widget _turnButtonFor(CompositionMode m) => switch (m) {
    CompositionMode.fibonacciSpiral => _buildSpiralRotateButton(),
    CompositionMode.diagonal => _buildDiagonalTurnButton(),
    CompositionMode.lArrangement => _buildLTurnButton(),
    _ => const SizedBox.shrink(),
  };

  /// The flip (mirror) control for [m]. Empty for modes without one.
  Widget _flipButtonFor(CompositionMode m) => switch (m) {
    CompositionMode.fibonacciSpiral => _buildSpiralFlipButton(),
    CompositionMode.goldenTriangles => _buildTrianglesFlipButton(),
    CompositionMode.vArrangement => _buildVFlipButton(),
    CompositionMode.lArrangement => _buildLFlipButton(),
    _ => const SizedBox.shrink(),
  };

  /// Aspect-ratio cycle control (Aspect Ratio mode). Each tap advances the crop
  /// ratio (1:1 → 4:5 → 16:9); the current label is shown on the button.
  Widget _buildAspectRatioButton() {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(
          () => _aspectIndex = (_aspectIndex + 1) % _aspectRatios.length,
        );
      },
      child: Container(
        width: 52,
        height: 52,
        decoration: glassChipDecoration(radius: 10),
        child: Center(
          child: _rotated(
            Text(
              _aspectRatios[_aspectIndex].label,
              style: const TextStyle(
                color: kGold,
                fontSize: 13,
                fontWeight: FontWeight.w400,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a right-slot action button that runs the shared grid-flip fade.
  /// [icon] is the (already transformed) glyph; [swap] mutates the orientation
  /// state at the fade's midpoint. Taps mid-flip are ignored.
  Widget _gridFlipButton({required Widget icon, required VoidCallback swap}) {
    return _GridActionButton(
      onTap: () {
        final c = _gridFlipController;
        if (c == null || c.isAnimating) return; // ignore taps mid-flip
        HapticFeedback.selectionClick();
        _startGridFlip(swap);
      },
      child: icon,
    );
  }

  /// Animates a card-style flip of [child] about [axis] whenever [flipped]
  /// toggles, so a flip button's glyph mirrors the direction of its grid model.
  Widget _animatedFlip(
    Widget child, {
    required bool flipped,
    required Axis axis,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: flipped ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
      builder: (context, t, w) {
        final m = Matrix4.identity()..setEntry(3, 2, 0.0012); // perspective
        axis == Axis.horizontal
            ? m.rotateY(t * math.pi)
            : m.rotateX(t * math.pi);
        return Transform(alignment: Alignment.center, transform: m, child: w);
      },
      child: child,
    );
  }

  static const Icon _kTurnIcon = Icon(
    Icons.rotate_90_degrees_cw_rounded,
    color: kGold,
    size: 24,
  );

  /// Rotate control (Fibonacci Spiral) — each tap turns the spiral 90° CW; the
  /// glyph rotates with it.
  Widget _buildSpiralRotateButton() => _gridFlipButton(
    icon: _rotatedTurns(_kTurnIcon, _spiralTurns),
    swap: () => _spiralTurns = (_spiralTurns + 1) & 3,
  );

  /// Flip control (Fibonacci Spiral) — mirrors the spiral horizontally so its
  /// eye lands on the opposite side; the glyph flips to match.
  Widget _buildSpiralFlipButton() => _gridFlipButton(
    icon: _rotated(
      _animatedFlip(
        const Icon(Icons.flip_rounded, color: kGold, size: 24),
        flipped: _spiralFlipped,
        axis: Axis.horizontal,
      ),
    ),
    swap: () => _spiralFlipped = !_spiralFlipped,
  );

  /// Turn control (Diagonal) — each tap springs the fan from the next corner.
  Widget _buildDiagonalTurnButton() => _gridFlipButton(
    icon: _rotatedTurns(_kTurnIcon, _diagonalTurns),
    swap: () => _diagonalTurns = (_diagonalTurns + 1) & 3,
  );

  /// Turn control (L-Arrangement) — each tap moves the L to the next corner.
  Widget _buildLTurnButton() => _gridFlipButton(
    icon: _rotatedTurns(_kTurnIcon, _lTurns),
    swap: () => _lTurns = (_lTurns + 1) & 3,
  );

  /// Flip control (L-Arrangement) — mirrors the L horizontally; glyph flips too.
  Widget _buildLFlipButton() => _gridFlipButton(
    icon: _rotated(
      _animatedFlip(
        const Icon(Icons.flip_rounded, color: kGold, size: 24),
        flipped: _lFlipped,
        axis: Axis.horizontal,
      ),
    ),
    swap: () => _lFlipped = !_lFlipped,
  );

  /// Flip control (Golden Triangles) — mirrors the set across the vertical axis;
  /// the glyph flips horizontally to match.
  Widget _buildTrianglesFlipButton() => _gridFlipButton(
    icon: _rotated(
      _animatedFlip(
        const Icon(Icons.flip_rounded, color: kGold, size: 24),
        flipped: _trianglesFlipped,
        axis: Axis.horizontal,
      ),
    ),
    swap: () => _trianglesFlipped = !_trianglesFlipped,
  );

  /// Flip control (V-Arrangement) — turns the V upside-down (V ↔ ∧); the glyph
  /// flips vertically to match.
  Widget _buildVFlipButton() => _gridFlipButton(
    icon: _rotated(
      _animatedFlip(
        const Icon(Icons.swap_vert_rounded, color: kGold, size: 24),
        flipped: _vFlipped,
        axis: Axis.vertical,
      ),
    ),
    swap: () => _vFlipped = !_vFlipped,
  );

  Widget _buildGlassCaptureButton() {
    return AnimatedBuilder(
      animation: Listenable.merge([_buttonBopAnimation, _glowAnimation]),
      builder: (context, child) {
        final scale = _buttonBopAnimation?.value ?? 1.0;
        final glowIntensity = _isRecording
            ? (_glowAnimation?.value ?? 0.3)
            : 0.3;

        return Transform.scale(
          scale: scale,
          child: GestureDetector(
            onTap: _isInitialized && !_isRecording ? _capturePhoto : null,
            onLongPressStart: _isInitialized
                ? (_) => _startVideoRecording()
                : null,
            onLongPressEnd: _isInitialized
                ? (_) => _stopVideoRecording()
                : null,
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // Outer glow — a warm gilded halo at rest that swells to a bright
                // pulse while recording, plus a soft contact shadow for lift.
                boxShadow: _isRecording
                    ? [
                        BoxShadow(
                          color: Colors.white.withValues(
                            alpha: 0.6 * glowIntensity,
                          ),
                          blurRadius: 30,
                          spreadRadius: 4,
                        ),
                        BoxShadow(
                          color: kGold.withValues(alpha: 0.45 * glowIntensity),
                          blurRadius: 22,
                          spreadRadius: 2,
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: kGold.withValues(alpha: 0.30),
                          blurRadius: 18,
                          spreadRadius: 1,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              child: Stack(
                children: [
                  // Opaque circular backdrop — prevents composition lines showing through
                  Positioned.fill(
                    child: ClipOval(
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.55),
                      ),
                    ),
                  ),

                  // Centre-frame live preview peek.
                  // BackdropFilter can only sample pixels physically behind the
                  // widget (bottom of screen). Instead, render a second CameraPreview
                  // at full-screen dimensions inside an OverflowBox so that the
                  // centre of the camera frame always appears in the centre of the
                  // circle, regardless of where the button sits on screen.
                  // Flutter's Texture widget safely shares the same GPU texture
                  // across multiple widgets, so there is no performance cost.
                  Center(
                    child: ClipOval(
                      child: SizedBox(
                        width: 58,
                        height: 58,
                        child: _isInitialized && _controller != null
                            ? OverflowBox(
                                alignment: Alignment.center,
                                minWidth: 0,
                                maxWidth: double.infinity,
                                minHeight: 0,
                                maxHeight: double.infinity,
                                child: SizedBox(
                                  // Render the preview at full-screen size so the
                                  // OverflowBox centres the frame and the 58×58 clip
                                  // reveals only the very centre of the camera feed.
                                  width: MediaQuery.of(context).size.width,
                                  height: MediaQuery.of(context).size.height,
                                  child: CameraPreview(_controller!),
                                ),
                              )
                            : Container(
                                color: Colors.black.withValues(alpha: 0.30),
                              ),
                      ),
                    ),
                  ),

                  // Gilded rim — at rest, a machined-metal bezel (sweep-gradient
                  // champagne→gold→antique, like a polished watch ring catching
                  // light); while recording it brightens to a pulsing white ring.
                  if (_isRecording)
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.transparent,
                        border: Border.all(
                          color: Colors.white.withValues(
                            alpha: 0.6 + (0.3 * glowIntensity),
                          ),
                          width: 2.5,
                        ),
                      ),
                    )
                  else
                    const Positioned.fill(
                      child: CustomPaint(painter: MetalRingPainter(width: 2.5)),
                    ),

                  // Fine inner hairline — a second, glassier ring just inside the
                  // gilt for a jewelled double-ring.
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(4.5),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.28),
                            width: 0.8,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Top left light reflection (glass highlight)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      width: 35,
                      height: 35,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0.5),
                            Colors.white.withValues(alpha: 0.2),
                            Colors.white.withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.3, 0.6, 1.0],
                        ),
                      ),
                    ),
                  ),

                  // Secondary subtle reflection (right side)
                  Positioned(
                    top: 25,
                    right: 10,
                    child: Container(
                      width: 15,
                      height: 15,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0.25),
                            Colors.white.withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Frosted-glass toggle that dims the composition overlay for a clean frame
  /// (gold + lit when shown, muted with a struck-through grid when hidden).
  Widget _buildGridToggle() {
    const gold = kGold;
    final on = _gridVisible;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _gridVisible = !_gridVisible);
      },
      // Smoked-glass chip (gradient-faked): its old BackdropFilter re-blurred
      // the live preview behind it EVERY frame — this looks the same and is free.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 42,
        height: 42,
        decoration: glassChipDecoration(circle: true, active: on),
        child: Icon(
          on ? Icons.grid_3x3_rounded : Icons.grid_off,
          color: on ? gold : Colors.white.withValues(alpha: 0.6),
          size: 20,
        ),
      ),
    );
  }

  /// Vertical exposure (EV) slider with a draggable sun knob. Drag up = brighter.
  /// EV-notifier-driven: the on-screen exposure drag moves only this readout.
  Widget _buildExposureSlider(double h) {
    const gold = kGold;
    final range = _maxExposure - _minExposure;
    const knob = 24.0;
    return ValueListenableBuilder<double>(
      valueListenable: _evN,
      builder: (context, ev, _) {
        final frac = range > 0
            ? ((ev - _minExposure) / range).clamp(0.0, 1.0)
            : 0.5;
        return SizedBox(
          width: 34,
          height: h,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Track.
              Container(
                width: 2,
                height: h,
                decoration: BoxDecoration(
                  color: gold.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(1),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 3),
                  ],
                ),
              ),
              // Sun knob.
              Positioned(
                bottom: frac * (h - knob),
                child: Container(
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.35),
                    boxShadow: [
                      BoxShadow(
                        color: gold.withValues(alpha: 0.4),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.wb_sunny_rounded,
                    color: gold,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// A short, very responsive vertical slider that nudges the Cross crossbar up
  /// and down within its fixed vertical arm. The drag maps straight onto the
  /// track — a small move sweeps the whole range, so it feels far more sensitive
  /// than the (deliberately gentle) exposure slider.
  /// Glowing, draggable rotate handle that sits at the BOTTOM tip of the cross's
  /// vertical arm (its base). It signals "grab me and spin" (a ↻ grip), glows +
  /// scales up while held, and orbits the pivot as the cross turns.
  Widget _buildCrossRotateHandle() {
    // Position against the camera-visible BAND — the exact space the painter
    // draws the cross in (translated by the top inset, height = band) — so the
    // handle stays glued to the arm tip on every device, whatever the safe-area
    // and panel heights are.
    final Size sz = MediaQuery.of(context).size;
    final double bandH = sz.height - _topInset - _bottomInset;
    final double cx = sz.width * 0.5;
    final double pivotY =
        _topInset + bandH * (kCrossTopFrac + kCrossBottomFrac) / 2;
    // Sits just past the bottom arm tip (a touch lower on screen), orbiting the
    // pivot by the angle.
    final double l =
        bandH * (kCrossBottomFrac - kCrossTopFrac) / 2 + _kCrossHandleDrop;
    // Listens to the cross ticker directly, so orbiting/glowing repaints only
    // this small handle — never the page.
    return ValueListenableBuilder<({double y, double angle, double glow})>(
      valueListenable: _crossN,
      builder: (context, c, _) {
        final double hx = cx - l * math.sin(c.angle);
        final double hy = pivotY + l * math.cos(c.angle);
        final double g = c.glow;
        final double size = 36 + 6 * g;
        return Positioned(
          left: hx - size / 2,
          top: hy - size / 2,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (_) => _onCrossGrab(),
            onPanUpdate: _onCrossSpin,
            onPanEnd: (_) => _onCrossRelease(),
            onPanCancel: _onCrossRelease,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.35 + 0.15 * g),
                border: Border.all(
                  color: kGold.withValues(alpha: 0.55 + 0.45 * g),
                  width: 1.2 + 0.8 * g,
                ),
                boxShadow: [
                  BoxShadow(
                    color: kGold.withValues(alpha: 0.22 + 0.5 * g),
                    blurRadius: 6 + 18 * g,
                    spreadRadius: 0.5 + 2 * g,
                  ),
                ],
              ),
              child: Icon(
                Icons.cached_rounded,
                color: kGold.withValues(alpha: 0.85 + 0.15 * g),
                size: 18 + 3 * g,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCrossSlider() {
    const double trackH = 150;
    const double knob = 22;
    const double range = kCrossBottomFrac - kCrossTopFrac;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Double-tap smoothly eases the cross back (recentre bar + straighten).
      onDoubleTap: () {
        HapticFeedback.selectionClick();
        _crossYTarget = kCrossDefaultY;
        _crossAngleTarget = 0;
        _ensureCrossSpinTicking();
      },
      onVerticalDragStart: (_) => _onCrossSlideStart(),
      onVerticalDragUpdate: (d) => _onCrossSlide((d.delta.dy / trackH) * range),
      onVerticalDragEnd: (_) => _onCrossSlideEnd(),
      onVerticalDragCancel: _onCrossSlideEnd,
      // Knob position + glow ride the cross ticker via the notifier, so a slide
      // repaints only this little track.
      child: ValueListenableBuilder<({double y, double angle, double glow})>(
        valueListenable: _crossN,
        builder: (context, c, _) {
          final double frac = ((c.y - kCrossTopFrac) / range).clamp(0.0, 1.0);
          final double g = c.glow; // selection glow drives the knob bloom
          return SizedBox(
            width: 36,
            height: trackH,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Track — brightens a touch while in use.
                Container(
                  width: 2,
                  height: trackH,
                  decoration: BoxDecoration(
                    color: kGold.withValues(alpha: 0.4 + 0.4 * g),
                    borderRadius: BorderRadius.circular(1),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 3),
                    ],
                  ),
                ),
                // Knob — glows + haloes while sliding.
                Positioned(
                  top: frac * (trackH - knob),
                  child: Container(
                    width: knob,
                    height: knob,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.4),
                      border: Border.all(
                        color: kGold.withValues(alpha: 0.3 + 0.5 * g),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: kGold.withValues(alpha: 0.35 + 0.45 * g),
                          blurRadius: 8 + 12 * g,
                          spreadRadius: 0.5 + 1.5 * g,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.unfold_more_rounded,
                      color: kGold,
                      size: 14,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The preview-facing "glass lip" — a whisper of paper-white where the chrome
  /// meets the live preview. Kept very faint: the statement edge is the
  /// [GildedHairline] laid along it — gold leaf catching light on the glass rim.
  static const BorderSide _kChromeLip = BorderSide(
    color: Color(0x14F6F1E7),
    width: 0.8,
  );

  /// Whether the camera chrome uses a real [BackdropFilter] frost (true frosted
  /// glass, but re-blurs the live preview every frame) or stays gradient-only.
  /// Off by default: the live blur caused jank, so we keep the FPS-safe gradient
  /// chrome. See [phily-fps-sensitivity]. Flip to true to try the real frost.
  static const bool _kFrostedChrome = false;

  /// Wraps a chrome [panel] in a real frosted-glass blur, clipped to its bounds.
  /// The panel's own scrim gradient composites over the blur, so the result reads
  /// as frosted glass rather than a plain blur. No-op when [_kFrostedChrome] off.
  Widget _frostedChrome(Widget panel) => _kFrostedChrome
      ? ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: panel,
          ),
        )
      : panel;

  /// Shared decoration for the top/bottom camera chrome: a smoked-glass scrim —
  /// deepest at the device edge for legibility, easing off toward the preview so
  /// the scene glows through the slab — finished with the warm [_kChromeLip].
  /// Pure gradients: zero per-frame cost over the live preview.
  BoxDecoration _chromeDecoration({required bool top}) => BoxDecoration(
    gradient: LinearGradient(
      begin: top ? Alignment.topCenter : Alignment.bottomCenter,
      end: top ? Alignment.bottomCenter : Alignment.topCenter,
      colors: const [
        Color(0xB30A0A0C), // deep smoked base at the device edge
        Color(0x850A0A0C),
        Color(0x2E0A0A0C), // thins out — the scene breathes through the glass
      ],
      stops: const [0.0, 0.55, 1.0],
    ),
    border: Border(
      top: top ? BorderSide.none : _kChromeLip,
      bottom: top ? _kChromeLip : BorderSide.none,
    ),
  );

  /// Small gilded countdown chip shown while the free trial runs — the gentle
  /// heads-up that Pro is ticking. Tap → paywall.
  Widget _buildTrialChip() {
    final int d = PhilyPro.instance.trialDaysLeft;
    final String label = d <= 0
        ? 'TRIAL ENDS TODAY'
        : 'TRIAL · $d DAY${d == 1 ? '' : 'S'} LEFT';
    return GestureDetector(
      onTap: () {
        hapticTap();
        showPhilyProPaywall(context);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: glassChipDecoration(radius: kRadiusLg, active: true),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.workspace_premium_rounded, color: kGold, size: 12),
            const SizedBox(width: 5),
            Text(
              label,
              style: brandLabel(
                size: 9,
                weight: FontWeight.w600,
                color: kGold,
                letterSpacing: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopSettingsPanel() {
    const Color gold = kGold;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTopPanelBody(gold),
        // Gold-leaf edge where the chrome meets the preview.
        const GildedHairline(opacity: 0.55),
      ],
    );
  }

  Widget _buildTopPanelBody(Color gold) {
    return _frostedChrome(
      Container(
        key: _topPanelKey,
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 10,
          bottom: 14,
          left: 20,
          right: 20,
        ),
        decoration: _chromeDecoration(top: true),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Flash control
            _buildSettingButton(
              icon: _flashMode == FlashMode.off
                  ? Icons.flash_off_rounded
                  : _flashMode == FlashMode.auto
                  ? Icons.flash_auto_rounded
                  : Icons.flash_on_rounded,
              iconColor: _flashMode == FlashMode.off ? Colors.white : gold,
              caption: _flashMode == FlashMode.off
                  ? 'FLASH'
                  : _flashMode == FlashMode.auto
                  ? 'AUTO'
                  : 'ON',
              onTap: _toggleFlash,
            ),

            // Divider
            Container(
              height: 22,
              width: 0.5,
              color: kPaper.withValues(alpha: 0.14),
            ),

            // Format control
            _buildSettingButton(label: _imageFormat, onTap: _toggleImageFormat),

            // Divider
            Container(
              height: 22,
              width: 0.5,
              color: kPaper.withValues(alpha: 0.14),
            ),

            // Resolution control
            _buildSettingButton(
              label: _resolution == ResolutionPreset.veryHigh ? '24MP' : '48MP',
              onTap: _toggleResolution,
            ),

            // Divider
            Container(
              height: 22,
              width: 0.5,
              color: kPaper.withValues(alpha: 0.14),
            ),

            // Guide — the always-visible front door to the composition guide
            // for the current mode (long-press on a belt pill and tapping the
            // tip bubble are the shortcuts). Dimmed on None: nothing to teach.
            Opacity(
              opacity: _compositionMode == CompositionMode.none ? 0.35 : 1.0,
              child: _buildSettingButton(
                icon: Icons.menu_book_rounded,
                caption: 'GUIDE',
                onTap: () => showCompositionGuide(context, _compositionMode),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingButton({
    String? label,
    IconData? icon,
    Color? iconColor,
    String? caption,
    required VoidCallback onTap,
  }) {
    final bool isIconActive =
        icon != null && iconColor != null && iconColor != Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: _rotated(
          icon != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: iconColor ?? Colors.white, size: 18),
                    const SizedBox(height: 3),
                    Text(
                      caption ?? '',
                      style: brandLabel(
                        size: 7.5,
                        weight: FontWeight.w600,
                        color: isIconActive
                            ? kGold
                            : kPaper.withValues(alpha: 0.42),
                        letterSpacing: 1.8,
                      ),
                    ),
                  ],
                )
              : Text(
                  label!.toUpperCase(),
                  style: brandLabel(
                    size: 11,
                    weight: FontWeight.w500,
                    color: kPaper.withValues(alpha: 0.92),
                    letterSpacing: 1.8,
                  ),
                ),
        ),
      ),
    );
  }

  /// A belt label whose "selectedness" is a continuous value [t] (0 off-centre →
  /// 1 centred). The gilded pill — fill, rim, glow — and the text colour all
  /// interpolate with [t], so as you scroll the gold pill **materialises** into
  /// the centre label and **dissolves** out of the leaving one, rather than
  /// snapping at the settle point. No BackdropFilter (a gradient fakes the glass)
  /// so it's cheap to animate every frame for the few visible labels.
  ///
  /// Mode labels stay horizontal (not _rotated) — a long upright label can't fit
  /// the thin belt in landscape; only control icons rotate.
  Widget _buildCompositionButton(String type, double t) {
    final double e = Curves.easeOut.transform(t.clamp(0.0, 1.0));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusLg),
        // Champagne-lit gilded glass: a lit top lip melting into a whisper of
        // gold — the pill reads as a jewelled chip, not a tinted box. Alphas all
        // ride [e], so it materialises into the centred label and dissolves out
        // of the leaving one. Still pure gradients (belt animates every frame).
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            kGoldLit.withValues(alpha: 0.16 * e),
            kGold.withValues(alpha: 0.075 * e),
            kGold.withValues(alpha: 0.012 * e),
          ],
          stops: const [0.0, 0.38, 1.0],
        ),
        border: Border.all(color: kGold.withValues(alpha: 0.5 * e)),
        boxShadow: e > 0.02
            ? [
                BoxShadow(
                  color: kGold.withValues(alpha: 0.12 * e),
                  blurRadius: 11,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        type.toUpperCase(),
        textAlign: TextAlign.center,
        style: brandLabel(
          size: 9.5,
          weight: FontWeight.w600,
          color: Color.lerp(kPaper.withValues(alpha: 0.34), kGold, e)!,
          letterSpacing: 1.8,
        ),
      ),
    );
  }

  Future<void> _switchToUltraWide() async {
    if (_ultraWideCamera == null || _isUsingUltraWide || _isSwitchingLens) {
      return;
    }
    _isSwitchingLens = true;
    _stopImageStream();
    final old = _controller;
    _controller = null;
    if (mounted) {
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }
    await old?.dispose();
    final nc = CameraController(
      _ultraWideCamera!,
      _resolution,
      enableAudio: true,
    );
    try {
      await nc.initialize();
    } catch (e) {
      debugLog('_switchToUltraWide: $e');
      try {
        await nc.dispose();
      } catch (_) {}
      _isSwitchingLens = false;
      return;
    }
    await nc.lockCaptureOrientation(DeviceOrientation.portraitUp);
    await nc.setFlashMode(_flashMode);
    // Use cached zoom range if available (saved during pre-warm), otherwise query.
    final double uwPhysMin = _uwCachedMinZoom ?? await nc.getMinZoomLevel();
    _maxZoom =
        _uwCachedMaxZoom ??
        (await nc.getMaxZoomLevel()).clamp(0, _zoomMax).toDouble();
    _ultraWideScaleFactor = uwPhysMin / 0.5;
    _minZoom = 0.5;
    _isUsingUltraWide = true;
    _controller = nc;
    _isSwitchingLens = false;
    if (mounted) setState(() {});
    await _startImageStream();
  }

  Future<void> _switchToMainCamera() async {
    if (!_isUsingUltraWide || _isSwitchingLens) return;
    _isSwitchingLens = true;
    _stopImageStream();
    final old = _controller;
    _controller = null;
    if (mounted) {
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }
    await old?.dispose();
    final nc = CameraController(_cameras![0], _resolution, enableAudio: true);
    try {
      await nc.initialize();
    } catch (e) {
      debugLog('_switchToMainCamera: $e');
      try {
        await nc.dispose();
      } catch (_) {}
      _isSwitchingLens = false;
      return;
    }
    await nc.lockCaptureOrientation(DeviceOrientation.portraitUp);
    await nc.setFlashMode(_flashMode);
    _minZoom = await nc.getMinZoomLevel();
    _maxZoom = (await nc.getMaxZoomLevel()).clamp(0, _zoomMax).toDouble();
    _setZoomState(_currentZoom.clamp(_minZoom, _maxZoom));
    _isUsingUltraWide = false;
    _controller = nc;
    _recordRefAspect();
    _isSwitchingLens = false;
    if (mounted) setState(() {});
    await _startImageStream();
  }

  /// Records a zoom change: updates the logic-side field and pushes the display
  /// notifier, so only the meter/labels repaint — no page rebuild per move.
  void _setZoomState(double z) {
    _currentZoom = z;
    _zoomN.value = z;
  }

  /// Zoom readout text. Below 1.0× the ultra-wide lens is active and its range
  /// tops out just under 1.0× (hitting 1.0 switches back to the main lens), so
  /// the displayed value is capped at 0.9× — the label never claims "1.0×"
  /// while still on the ultra-wide (0.99999 would round up to exactly that).
  String _zoomLabel(double zoom) =>
      '${(zoom < 1.0 ? math.min(zoom, 0.9) : zoom).toStringAsFixed(1)}×';

  /// The zoom "feel" dispatcher — called on every zoom change (drag, pinch,
  /// fling). Three tiers of feedback:
  ///  • crossing a hardware switchover stop (the gold ticks) → a firmer
  ///    lightImpact detent + readout pop;
  ///  • crossing any labelled stop (majors on the 1–25× belt, every 0.1× on
  ///    the ultra dial) → readout pop;
  ///  • every 0.2× (0.05× on the ultra dial) → a whisper selectionClick tick.
  void _zoomHapticTick(double targetZoom) {
    // Static bounds (not _minZoom/_maxZoom — those hold the active
    // controller's PHYSICAL range, which on the two-controller ultra-wide path
    // starts at 1.0 and would swallow every sub-1× tick).
    final double z = targetZoom.clamp(0.5, _zoomMax);
    final double prev = _lastFeltZoom;
    if (z == prev) return;
    _lastFeltZoom = z;

    // Detent: swept across a hardware lens-switchover factor?
    bool detent = false;
    for (final s in _switchoverFactors) {
      if ((prev < s) != (z < s)) {
        detent = true;
        break;
      }
    }

    // Labelled-stop crossing → pop the readout (synced with the detent).
    bool crossedLabel = detent;
    if (!crossedLabel) {
      if (z < 1.0 || prev < 1.0) {
        crossedLabel = (prev * 10).floor() != (z * 10).floor();
      } else {
        for (final m in const [1.0, 2.0, 5.0, 10.0, 15.0, 20.0, 25.0]) {
          if ((prev < m) != (z < m)) {
            crossedLabel = true;
            break;
          }
        }
      }
    }
    if (crossedLabel) _readoutPop.forward(from: 0);

    // Finer notches below 1.0× — the ultra-wide belt spans only 0.5 units, so
    // 0.2× steps would tick just twice across the whole scrub.
    final double notch = z < 1.0 ? 0.05 : 0.2;
    final int step = (z / notch).round();
    if (detent) {
      HapticFeedback.lightImpact(); // deeper notch at the meaningful stops
      _lastZoomTick = step; // swallow the whisper tick for this crossing
    } else if (step != _lastZoomTick) {
      _lastZoomTick = step;
      HapticFeedback.selectionClick();
    }
  }

  /// Clamp a scrub value to the belt range, landing one firm "hard stop" thud
  /// the moment the finger pushes past either end — the range ends feel like a
  /// physical dial hitting its stop. Re-arms once the value comes back inside.
  double _clampWithStopThud(double raw, double lo, double hi) {
    final bool atStop = raw < lo - 1e-9 || raw > hi + 1e-9;
    if (atStop && !_zoomAtStop) HapticFeedback.mediumImpact();
    _zoomAtStop = atStop;
    return raw.clamp(lo, hi);
  }

  /// Fling coast: the belt keeps spinning with friction after release, ticks
  /// firing as it passes stops, and lands a hard-stop thud if it reaches an
  /// end of the range.
  void _onZoomFling() {
    final double v = _zoomFling.value;
    final double lo = _zoomLo, hi = _zoomHi;
    if (v <= lo || v >= hi) {
      _zoomFling.stop();
      if (!_zoomAtStop) {
        _zoomAtStop = true;
        HapticFeedback.mediumImpact();
      }
    }
    _setCameraZoom(v.clamp(lo, hi));
  }

  Future<void> _setCameraZoom(double value) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    _zoomHapticTick(value);

    if (_usesVirtualCamera) {
      // ── Native seamless-zoom path ───────────────────────────────────────────
      // Writes directly to AVCaptureDevice.videoZoomFactor, bypassing the
      // Flutter plugin's setZoomLevel path. This is the same device the plugin's
      // AVCaptureSession holds, so the change applies on the very next frame —
      // zero session teardown, zero black frame, no controller swap ever.
      final double clamped = value.clamp(_minZoom, _maxZoom);
      try {
        await _CameraZoomChannel.instance.setZoom(clamped);
        if (mounted) _setZoomState(clamped);
      } catch (e) {
        // Native channel unavailable — fall back to plugin path.
        debugLog('_setCameraZoom native failed ($e) — using plugin fallback');
        try {
          await _controller!.setZoomLevel(clamped);
          if (mounted) _setZoomState(clamped);
        } catch (e2) {
          debugLog('_setCameraZoom plugin: $e2');
        }
      }
      return;
    }

    // ── Two-controller fallback (no virtual device on this hardware) ─────────
    if (_isSwitchingLens) return;
    final double v = value.clamp(0.5, _zoomMax);

    if (v < 1.0) {
      if (!_isUsingUltraWide) {
        if (_ultraWideCamera != null) {
          await _switchToUltraWide();
          if (_controller == null || !_controller!.value.isInitialized) return;
        } else {
          final double clamped = _minZoom;
          try {
            await _controller!.setZoomLevel(clamped);
          } catch (_) {}
          if (mounted) _setZoomState(clamped);
          return;
        }
      }
      final double physical = (v * _ultraWideScaleFactor).clamp(
        _ultraWideScaleFactor * 0.5,
        _maxZoom,
      );
      try {
        await _controller!.setZoomLevel(physical);
        if (mounted) _setZoomState(v);
      } catch (e) {
        debugLog('_setCameraZoom ultra-wide: $e');
      }
    } else {
      if (_isUsingUltraWide) {
        await _switchToMainCamera();
        if (_controller == null || !_controller!.value.isInitialized) return;
      }
      final double clamped = v.clamp(_minZoom, _maxZoom);
      try {
        await _controller!.setZoomLevel(clamped);
        if (mounted) _setZoomState(clamped);
      } catch (e) {
        debugLog('_setCameraZoom main: $e');
      }
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Zoom meter — horizontal scroll wheel with hairline ticks
  // ────────────────────────────────────────────────────────────────────────────

  /// Switch the zoom bar between the ultra-wide (0.5–1.0×) and normal (1–25×)
  /// lens ranges, jumping to that range's base and updating the lens.
  void _setLensMode(bool ultra) {
    if (_ultraZoomMode == ultra || (ultra && !_hasUltraWide)) return;
    HapticFeedback.selectionClick();
    _zoomFling.stop();
    // Morph the dial density (36↔320 px/unit) instead of snapping — the ticks
    // visibly stretch apart / compress like a mechanical zoom ring.
    _pxFrom = _beltPxNow;
    _pxTo = ultra ? 320.0 : 36.0;
    _dialMorph.forward(from: 0);
    setState(() => _ultraZoomMode = ultra);
    _setCameraZoom(ultra ? 0.5 : 1.0);
  }

  /// Tiny segmented switch for the lens range, shown on the zoom bar.
  Widget _buildLensToggle() {
    Widget seg(String label, bool ultra) {
      final bool active = _ultraZoomMode == ultra;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _setLensMode(ultra),
        child: AnimatedContainer(
          duration: kDurFast,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: active ? kGold : Colors.transparent,
            borderRadius: BorderRadius.circular(kRadiusLg),
          ),
          child: Text(
            label,
            style: brandLabel(
              size: 9,
              weight: FontWeight.w600,
              color: active ? Colors.black : kPaper.withValues(alpha: 0.55),
              letterSpacing: 0.4,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(kRadiusLg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg('.5×', true), seg('1×', false)],
      ),
    );
  }

  Widget _buildZoomMeter() {
    // Drag leverage lives in _beltPxNow: 36px ≈ 1× on the 1–25× belt, 320 on
    // the 0.5-unit ultra dial, tweened between them on lens-mode switches.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Readout + tick wheel listen to the zoom notifier, so scrubbing the
        // meter (or pinching) repaints just these two, not the page.
        AnimatedBuilder(
          animation: Listenable.merge([_zoomN, _readoutPop]),
          builder: (context, _) => Transform.scale(
            // A quick 12% pop as the readout crosses a labelled stop, synced
            // with the detent haptic.
            scale: 1 + 0.12 * math.sin(math.pi * _readoutPop.value),
            child: Text(
              _zoomLabel(_zoomN.value.clamp(_zoomLo, _zoomHi)),
              style: const TextStyle(
                color: kGold,
                fontSize: 13,
                fontWeight: FontWeight.w300,
                letterSpacing: 1.4,
              ),
            ),
          ),
        ),
        const SizedBox(height: 1),
        // The belt (full width, centred) with the lens switch floated on its
        // left edge, so adding the switch doesn't shift the belt.
        Stack(
          alignment: Alignment.centerLeft,
          children: [
            GestureDetector(
              onHorizontalDragStart: (d) {
                _zoomFling.stop(); // a fresh grab takes over from coasting
                _zoomAtStop = false; // re-arm the range-end thud
                _beltEngage.forward(); // the wheel swells under the finger
                _meterDragStart = d.localPosition.dx;
                // Read the live field — the meter no longer rebuilds per move,
                // so a value captured at build time could be stale.
                _zoomAtDragStart = _currentZoom.clamp(_zoomLo, _zoomHi);
              },
              onHorizontalDragUpdate: (d) {
                final double delta = d.localPosition.dx - _meterDragStart;
                _setCameraZoom(
                  _clampWithStopThud(
                    _zoomAtDragStart - delta / _beltPxNow,
                    _zoomLo,
                    _zoomHi,
                  ),
                );
              },
              onHorizontalDragEnd: (d) {
                _beltEngage.reverse();
                // Fling: the wheel keeps spinning with friction after release,
                // ticks firing as it coasts — a real jog dial.
                final double vz = -(d.primaryVelocity ?? 0) / _beltPxNow;
                if (vz.abs() < 0.3) return;
                _zoomAtStop = false;
                _zoomFling.value = _currentZoom.clamp(_zoomLo, _zoomHi);
                _zoomFling.animateWith(
                  FrictionSimulation(0.135, _zoomFling.value, vz),
                );
              },
              onHorizontalDragCancel: () => _beltEngage.reverse(),
              child: SizedBox(
                width: double.infinity,
                height: 36,
                child: AnimatedBuilder(
                  // Repaints on zoom changes, the engage swell, and the
                  // lens-mode density morph — still painter-only, never a
                  // page rebuild.
                  animation: Listenable.merge([
                    _zoomN,
                    _beltEngage,
                    _dialMorph,
                  ]),
                  builder: (context, _) => CustomPaint(
                    painter: _ZoomMeterPainter(
                      zoom: _zoomN.value.clamp(_zoomLo, _zoomHi),
                      minZoom: _zoomLo,
                      maxZoom: _zoomHi,
                      pxPerUnit: _beltPxNow,
                      switchoverFactors: _switchoverFactors,
                      active: Curves.easeOut.transform(_beltEngage.value),
                    ),
                  ),
                ),
              ),
            ),
            if (_hasUltraWide)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _buildLensToggle(),
              ),
          ],
        ),
      ],
    );
  }

  // ── Landscape vertical zoom meter ──────────────────────────────────────────
  // A semicircle that pops out from the right edge of the screen.
  // Drag up to zoom in, drag down to zoom out.

  Widget _buildVerticalZoomMeter() {
    const double pxPerUnit = 32.0;
    const double h = 220.0;
    const double w =
        68.0; // radius of the semicircle = protrusion from screen edge

    return ClipPath(
      clipper: _SemicircleFromRightClipper(),
      child: Container(
        width: w,
        height: h,
        color: Colors.black.withValues(alpha: 0.50),
        child: GestureDetector(
          onVerticalDragStart: (d) {
            _zoomFling.stop();
            _zoomAtStop = false; // re-arm the range-end thud
            _meterDragStart = d.localPosition.dy;
            // Live field, not a build-time capture (no per-move rebuilds now).
            _zoomAtDragStart = _currentZoom.clamp(0.5, _zoomMax);
          },
          onVerticalDragUpdate: (d) {
            final delta = d.localPosition.dy - _meterDragStart;
            // Up (negative delta) → zoom in; down → zoom out. Firm thud when
            // the drag pushes past either end of the full range.
            _setCameraZoom(
              _clampWithStopThud(
                _zoomAtDragStart - delta / pxPerUnit,
                0.5,
                _zoomMax,
              ),
            );
          },
          onVerticalDragEnd: (_) {},
          child: ValueListenableBuilder<double>(
            valueListenable: _zoomN,
            builder: (context, zoom, _) => CustomPaint(
              painter: _VerticalZoomMeterPainter(
                zoom: zoom.clamp(0.5, _zoomMax),
                maxZoom: _zoomMax,
                pxPerUnit: pxPerUnit,
                switchoverFactors: _switchoverFactors,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (_error != null) {
      // On-brand failure state — even this screen wears the gold-on-black
      // language (aura mark, serif headline, gilded retry chip), matching the
      // gallery's empty state instead of a red debug screen.
      return Container(
        color: kBackground,
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 128,
              height: 128,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [kGold.withValues(alpha: 0.14), Colors.transparent],
                  stops: const [0.0, 0.72],
                ),
              ),
              child: Icon(
                Icons.no_photography_outlined,
                color: kPaper.withValues(alpha: 0.35),
                size: 48,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Camera unavailable',
              style: brandDisplay(
                size: 22,
                weight: FontWeight.w500,
                color: kPaper.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: brandLabel(
                size: 11.5,
                weight: FontWeight.w400,
                color: kPaper.withValues(alpha: 0.45),
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 22),
            GestureDetector(
              onTap: () {
                hapticTap();
                setState(() => _error = null);
                _initializeCamera();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                decoration: glassChipDecoration(
                  radius: kRadiusLg,
                  active: true,
                ),
                child: Text(
                  'TRY AGAIN',
                  style: brandLabel(
                    size: 10.5,
                    weight: FontWeight.w600,
                    color: kGold,
                    letterSpacing: 2.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // First-time initialisation — plain black; the branded loader overlay (top
    // of the Stack) is the visible loading state and covers this.
    if (!_isInitialized) {
      return Container(color: Colors.black);
    }

    // Lens is mid-switch — controller disposed, new one not ready yet.
    // Return plain black; this frame is very brief (pre-warmed hardware).
    if (_controller == null) {
      return Container(color: Colors.black);
    }

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(_previewStretchX, 1.0, 1.0),
      child: CameraPreview(_controller!),
    );
  }
}

/// Shared chrome for the right-slot mode-action buttons (spiral rotate, focal
/// turn, triangles / V flip): a 52pt dark rounded square with a hairline border.
/// [child] is the (transformed) glyph; [onTap] performs the action. Centralising
/// the look here keeps every mode button identical and easy to reuse.
class _GridActionButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _GridActionButton({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: glassChipDecoration(radius: 10),
        child: Center(child: child),
      ),
    );
  }
}
