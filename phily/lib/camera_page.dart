import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:gal/gal.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:phily/screens/branded_loader.dart';
import 'package:phily/screens/gallery_viewer.dart';
import 'dart:io';
import 'dart:ui' as ui;

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
  // user point the spiral's eye at any corner. Persists across mode switches.
  int _spiralTurns = 0;
  // Aspect Ratio mode: selected crop ratio. Cycled by a button in that mode.
  static const List<({String label, double ratio})> _aspectRatios = [
    (label: '1:1', ratio: 1.0),
    (label: '4:5', ratio: 4 / 5),
    (label: '16:9', ratio: 16 / 9),
  ];
  int _aspectIndex = 1; // default 4:5 (most useful for social portraits)
  // "Best for" tip bubble shown briefly when the composition mode changes.
  bool _showTip = false;
  Timer? _tipTimer;
  static const List<CompositionMode> _compositionModes = CompositionMode.values;
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
  double _minExposure = 0, _maxExposure = 0; // device EV range

  // Zoom
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  // Swipe-to-switch-composition tracking (single-finger horizontal swipe on the
  // preview). Kept separate from pinch-zoom via the max-pointer-count check.
  double _swipeStartX = 0, _swipeStartY = 0, _swipeLastX = 0, _swipeLastY = 0;
  int _swipeMaxPointers = 0;
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

  // ML Kit face detector — runs on the CameraImage directly (no method-channel
  // image round trip), so detection latency is low enough for live tracking.
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableContours: false,
      enableLandmarks: false,
      enableClassification: false,
      minFaceSize: 0.1,
    ),
  );

  // Downsample factor applied to camera frames before face detection. 2 = run
  // detection at half resolution — far cheaper for ML Kit and the rotation pass,
  // with face proportions preserved. Raise for more FPS, set 1 if faces are missed.
  static const int _detScale = 2;

  // Also detect cats/dogs (Apple Vision). Adds one native call per frame.
  static const bool _animalsEnabled = true;

  // Physical device orientation (the UI is portrait-locked, so we read the
  // accelerometer directly). Quarter-turns clockwise from portrait: 0/1/2/3.
  // Drives the ML Kit rotation + box back-mapping so detection works sideways.
  int _deviceTurns = 0;
  StreamSubscription<AccelerometerEvent>? _accelSub;

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
    _accelSub = accelerometerEventStream().listen((e) {
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
      }
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

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _startOrientationListener();
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
        debugPrint(
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
        debugPrint('getVirtualCameraId: $e');
      }
      final virtualCam = virtualId != null
          ? _cameras!.where((c) => c.name == virtualId).firstOrNull
          : null;
      debugPrint('getVirtualCameraId=$virtualId  matched=${virtualCam?.name}');

      if (virtualCam != null) {
        debugPrint('Virtual multi-camera found: ${virtualCam.name}');
        _usesVirtualCamera = true;
        _ultraWideCamera = null;
        _controller = CameraController(
          virtualCam,
          _resolution,
          enableAudio: true,
        );
      } else {
        debugPrint(
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
            debugPrint('Switchover factors: $_switchoverFactors');
          }
        } catch (e) {
          debugPrint('getZoomInfo failed: $e');
        }
        _currentZoom = _currentZoom.clamp(_minZoom, _maxZoom);
        await _CameraZoomChannel.instance.setZoom(_currentZoom);
      }
      debugPrint(
        'Zoom range: $_minZoom – $_maxZoom | ultra-wide: ${_ultraWideCamera?.name}',
      );

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
      // Begin streaming frames for composition alignment detection.
      await _startImageStream();
    } catch (e) {
      setState(() {
        _error = 'Camera initialization failed: $e';
      });
      debugPrint('Camera error: $e');
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
          debugPrint(
            '_resolveUltraWide: matched "${match.name}" via native channel',
          );
          return match;
        }
        debugPrint('_resolveUltraWide: uid "$uid" not found in camera list');
      } else {
        debugPrint(
          '_resolveUltraWide: channel returned null (no ultra-wide on device)',
        );
      }
    } catch (e) {
      debugPrint('_resolveUltraWide: channel error — $e');
    }

    // Fallback: first additional back camera.
    final fallback = _cameras!
        .where(
          (c) =>
              c.lensDirection == CameraLensDirection.back && c != _cameras![0],
        )
        .firstOrNull;
    if (fallback != null) {
      debugPrint('_resolveUltraWide: fallback to "${fallback.name}"');
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
      debugPrint('Starting thumbnail load...');

      if (!await _ensurePhotoPermission()) {
        debugPrint('Photo library permission denied or not granted');
        return;
      }

      // Get all assets sorted by creation date (most recent first)
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.common, // Gets both images and videos
        hasAll: true,
        onlyAll: true,
      );

      debugPrint('Found ${albums.length} albums');

      if (albums.isEmpty) {
        debugPrint('No albums found');
        return;
      }

      // Get the most recent asset from the "All" album
      final recentAlbum = albums.first;
      final assetCount = await recentAlbum.assetCountAsync;
      debugPrint('Album "${recentAlbum.name}" has $assetCount assets');

      if (assetCount == 0) {
        debugPrint('No assets in album');
        return;
      }

      final List<AssetEntity> recentAssets = await recentAlbum
          .getAssetListRange(start: 0, end: 1);

      if (recentAssets.isEmpty) {
        debugPrint('Failed to get recent assets');
        return;
      }

      debugPrint('Loading thumbnail for asset: ${recentAssets.first.id}');

      // Get thumbnail data
      final Uint8List? thumbnail = await recentAssets.first
          .thumbnailDataWithSize(const ThumbnailSize(200, 200), quality: 90);

      debugPrint(
        'Thumbnail loaded: ${thumbnail != null ? "${thumbnail.length} bytes" : "null"}',
      );

      if (mounted && thumbnail != null) {
        setState(() {
          _latestThumbnail = thumbnail;
        });
        debugPrint('Thumbnail set in state');
      }
    } catch (e) {
      debugPrint('Error loading latest thumbnail: $e');
    }
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _tipTimer?.cancel();
    _focusHideTimer?.cancel();
    _accelSub?.cancel();
    _faceAnim?.dispose();
    _alignLevel.dispose();
    _horizon.dispose();
    _hzLevel.dispose();
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
    _focusHideTimer = Timer(const Duration(milliseconds: 3500), () {
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
    setState(() => _exposureOffset = next);
    try {
      await _controller!.setExposureOffset(next);
    } catch (_) {}
    _scheduleFocusHide();
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseZoom = _currentZoom;
    _swipeStartX = _swipeLastX = details.focalPoint.dx;
    _swipeStartY = _swipeLastY = details.focalPoint.dy;
    _swipeMaxPointers = details.pointerCount;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails details) async {
    _swipeMaxPointers = math.max(_swipeMaxPointers, details.pointerCount);
    _swipeLastX = details.focalPoint.dx;
    _swipeLastY = details.focalPoint.dy;
    if (_controller == null || !_controller!.value.isInitialized) return;
    // Allow pinching down to 0.5× — _setCameraZoom handles the lens boundary.
    final double newZoom = (_baseZoom * details.scale).clamp(0.5, _maxZoom);
    if ((newZoom - _currentZoom).abs() < 0.01) return;
    await _setCameraZoom(newZoom);
  }

  void _onScaleEnd(ScaleEndDetails _) {
    // Only a single-finger gesture counts as a composition swipe (never a pinch).
    if (_swipeMaxPointers > 1) return;
    final double dx = _swipeLastX - _swipeStartX;
    final double dy = _swipeLastY - _swipeStartY;
    // Require a clearly horizontal swipe past a threshold.
    if (dx.abs() > 60 && dx.abs() > dy.abs() * 1.5) {
      _changeCompositionBy(dx < 0 ? 1 : -1); // swipe left → next, right → prev
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

  /// Compact "best for" blurb for the current mode, or null when there's
  /// nothing worth saying (None).
  String? get _compositionTip {
    switch (_compositionMode) {
      case CompositionMode.none:
        return null;
      case CompositionMode.horizonGrid:
        return 'Landscapes & seascapes — level the horizon onto the golden line for a balanced, sky-forward frame.';
      case CompositionMode.ruleOfThirds:
        return 'Everyday shots — people, landscapes, street. Put your subject on a dot.';
      case CompositionMode.goldenSection:
        return 'Portraits & fine-art landscapes — subject a touch more central.';
      case CompositionMode.goldenTriangles:
        return 'Scenes with strong diagonals — roads, stairs, reclining poses.';
      case CompositionMode.spiralSection:
        return 'A single hero subject — nest it toward the spiral.';
      case CompositionMode.fibonacciSpiral:
        return 'Flowing scenes — rivers, paths, shells. Lead the eye to the centre.';
      case CompositionMode.harmoniousTriangles:
        return 'Balancing complex scenes & architecture.';
      case CompositionMode.cross:
        return 'Symmetrical, centred subjects — reflections, formal architecture.';
      case CompositionMode.focalMass:
        return 'One dominant subject against negative space — minimalism.';
      case CompositionMode.vArrangement:
        return 'Group portraits, valleys, converging lines.';
      case CompositionMode.diagonal:
        return 'Energy & motion — street, action, leading lines.';
      case CompositionMode.radial:
        return 'Flowers, wheels, sunbursts, radial food plating.';
      case CompositionMode.lArrangement:
        return 'Product & still life — frame a subject in a corner.';
      case CompositionMode.compoundCurve:
        return 'Winding rivers & roads, the S-curve of the figure.';
      case CompositionMode.pyramid:
        return 'Groups of people, mountains, stable still life.';
      case CompositionMode.circular:
        return 'Round plates of food, groups in a circle, round subjects.';
      case CompositionMode.symmetry:
        return 'Reflections, faces, doorways — centre on the line.';
      case CompositionMode.aspectRatio:
        return 'Frame for social or print — tap to cycle 1:1 · 4:5 · 16:9.';
    }
  }

  /// Show the "best for" bubble for ~3s. Re-arms the timer on each call so a
  /// quick scrub through modes keeps the latest bubble visible.
  void _showCompositionTip() {
    if (_compositionTip == null) {
      _dismissTip();
      return;
    }
    _tipTimer?.cancel();
    setState(() => _showTip = true);
    _tipTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showTip = false);
    });
  }

  /// Hide the bubble immediately (swipe-up, or moving to a tip-less mode).
  void _dismissTip() {
    _tipTimer?.cancel();
    if (_showTip && mounted) setState(() => _showTip = false);
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
      debugPrint('startImageStream: $e');
    }
  }

  /// Stops the image stream. Safe to call when not streaming.
  void _stopImageStream() {
    try {
      if (_controller != null && _controller!.value.isStreamingImages) {
        _controller!.stopImageStream();
      }
    } catch (e) {
      debugPrint('stopImageStream: $e');
    }
  }

  Future<void> _capturePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

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
      // Restart stream after capture.
      await _startImageStream();
    } catch (e) {
      debugPrint('Error taking photo: $e');
      await _startImageStream();
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

      // Refresh thumbnail after save completes
      _loadLatestThumbnail();
    } catch (e) {
      debugPrint('Error saving media: $e');
    }
  }

  Future<void> _startVideoRecording() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isRecording)
      return;

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

    // Trigger bop animation
    _buttonBopController!.forward(from: 0);

    // Start glow pulsing animation
    _glowController!.forward();

    try {
      // Video recording cannot run alongside an image stream.
      _stopImageStream();
      await _controller!.startVideoRecording();
    } catch (e) {
      debugPrint('Error starting video: $e');
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
      debugPrint('Error stopping video: $e');
      _glowController!.reset();
      await _startImageStream();
    }
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    // Always run detection so overlays can show even when composition mode
    // is `none` (useful for experimentation). Heavy composition-only logic
    // remains gated on the selected mode.
    final now = DateTime.now();
    // ~16 fps. Lower = more responsive tracking, but more CPU. With the cached
    // single-orientation detection this stays cheap enough for smooth tracking.
    if (now.difference(_lastFrameTime).inMilliseconds < 60) return;
    if (_isProcessingFrame) return;
    _isProcessingFrame = true;
    _lastFrameTime = now;
    try {
      // Detection runs for None (boxes only), Horizon Grid (horizon line) and
      // the alignment modes — Rule of Thirds, Phi Grid (intersection alignment)
      // and Fibonacci Spiral (eye alignment) — for boxes + glow + haptic.
      switch (_compositionMode) {
        case CompositionMode.none:
        case CompositionMode.horizonGrid:
        case CompositionMode.ruleOfThirds:
        case CompositionMode.goldenSection:
        case CompositionMode.fibonacciSpiral:
          await _analyzeDetections(image);
          break;
        default:
          break;
      }
    } catch (e) {
      debugPrint('_onCameraFrame: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  // Caches the physical quarter-turn rotation that finds faces per device-turns.
  final Map<int, int> _qtCache = {};

  // Same idea but for the horizon: which rotation makes the horizon HORIZONTAL
  // in the analysed buffer. A sea/sky scene has no faces to calibrate with, so
  // we discover it by horizon strength and cache it per device-turns.
  final Map<int, int> _hzQtCache = {};
  int _hzProbeMs = 0;

  /// Real-time face detection via ML Kit. ML Kit on iOS ignores InputImage
  /// rotation metadata, so to detect faces when the phone is held sideways we
  /// must PHYSICALLY rotate the pixel buffer to upright, detect, then map the
  /// boxes back into the original (portrait) buffer space the fixed preview shows.
  Future<void> _analyzeDetections(CameraImage image) async {
    if (image.format.group != ImageFormatGroup.bgra8888) return;
    final plane = image.planes.first;
    final int w = image.width, h = image.height;
    final turns = _deviceTurns;

    // Build the downsampled+rotated buffer ONCE at the best-known rotation and
    // reuse it for both ML Kit (faces) and Vision (subjects) — one synchronous
    // pixel loop on the UI isolate per frame.
    int qt = _qtCache[turns] ?? 0;
    var (winBytes, winOw, winOh) = _rotatedBytes(
      plane.bytes,
      w,
      h,
      plane.bytesPerRow,
      qt,
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
      dets.add({
        'x': cx - stretchedW / 2,
        'y': ny,
        'w': stretchedW,
        'h': nh,
        'label': 'face',
        'confidence': 1.0,
      });
    }

    // ── Animals (cats/dogs) via Apple Vision, reusing the same upright buffer ───
    if (_animalsEnabled) {
      try {
        final raw = await _cameraChannel.invokeMethod<List>('detectAnimals', {
          'bgra': winBytes,
          'width': winOw,
          'height': winOh,
        });
        if (!mounted) return;
        _addVisionDets(raw, dets, qt, 'animal');
      } catch (_) {}
    }

    // ── Horizon (Horizon Grid mode) — highlight the detected horizon line ──────
    if (_compositionMode == CompositionMode.horizonGrid) {
      try {
        final int hNow = DateTime.now().millisecondsSinceEpoch;
        const double confStrength = 18; // luma+colour step to trust it
        const int stableFrames = 2; // consecutive consistent frames to show

        // Run the detector on the buffer rotated by [q] quarter-turns, cropped
        // to the camera-visible band so it ignores the scene hidden behind the
        // top/bottom panels. The band is a screen-space y-range; where it lands
        // in the rotated buffer depends on [q] (see _hzBandCrop).
        Future<(Map?, double)> tryQt(int q) async {
          final (b, bw, bh) = _rotatedBytes(
            plane.bytes,
            w,
            h,
            plane.bytesPerRow,
            q,
          );
          final (cx0, cy0, cx1, cy1) = _hzBandCrop(q);
          final r = await _cameraChannel.invokeMethod('detectHorizon', {
            'bgra': b,
            'width': bw,
            'height': bh,
            'cropX0': cx0,
            'cropY0': cy0,
            'cropX1': cx1,
            'cropY1': cy1,
          });
          final m = r is Map ? r : null;
          return (m, (m?['strength'] as num?)?.toDouble() ?? 0.0);
        }

        // Discover the orientation that makes the horizon horizontal (no faces
        // needed). Once a strong horizon appears, lock that rotation so later
        // frames only do one rotation. Probing is throttled so a no-horizon
        // scene doesn't pay four rotations every frame.
        int hzQt = _hzQtCache[turns] ?? 0;
        Map? hRaw;
        if (_hzQtCache.containsKey(turns)) {
          final (m, _) = await tryQt(hzQt);
          if (!mounted) return;
          hRaw = m;
        } else if (hNow - _hzProbeMs > 200) {
          _hzProbeMs = hNow;
          double best = 0;
          for (final q in const [0, 1, 2, 3]) {
            final (m, s) = await tryQt(q);
            if (!mounted) return;
            if (s > best) {
              best = s;
              hRaw = m;
              hzQt = q;
            }
          }
          if (best >= 22) _hzQtCache[turns] = hzQt;
          debugPrint(
            '[Horizon] probe best=${best.toStringAsFixed(0)} qt=$hzQt'
            '${best >= 22 ? ' LOCKED' : ' (weak)'}',
          );
        }

        final num strength = (hRaw is Map ? hRaw['strength'] as num? : null) ?? 0;
        final bool hasLine = hRaw is Map &&
            hRaw['angle'] != null &&
            hRaw['x'] != null &&
            strength >= confStrength;

        if (hasLine) {
          // Map the point AND a second point a short step along the line back
          // through the inverse rotation (hzQt) + preview stretch — deriving the
          // angle from two mapped points keeps the sign/rotation correct for any
          // device orientation automatically.
          final double a = (hRaw['angle'] as num).toDouble();
          final double ux = (hRaw['x'] as num).toDouble();
          final double uy = (hRaw['y'] as num).toDouble();
          const double d = 0.1;
          final p0 = _mapHorizonPt(ux, uy, hzQt);
          final p1 = _mapHorizonPt(
            ux + math.cos(a) * d,
            uy + math.sin(a) * d,
            hzQt,
          );
          double ang = math.atan2(p1.$2 - p0.$2, p1.$1 - p0.$1);
          // Snap a near-level line to dead-flat (leniency): tiny residual tilt
          // from detection reads as a clean horizontal instead of a slight slope.
          if (ang.abs() < 0.045) ang = 0.0; // within ~2.6°

          // Consistency vs the previous frame's raw line. Generous tolerances:
          // a live sea jitters a little, and the detection is already gated by
          // strength, so we don't need a tight match to trust it.
          final bool consistent = _hzRawA != null &&
              (_lerpAngle(_hzRawA!, ang, 1.0) - _hzRawA!).abs() < 0.10 &&
              (p0.$1 - _hzRawX!).abs() < 0.15 &&
              (p0.$2 - _hzRawY!).abs() < 0.15;
          _hzRawA = ang;
          _hzRawX = p0.$1;
          _hzRawY = p0.$2;
          _hzStable = consistent ? math.min(_hzStable + 1, 12) : 0;

          if (_hzStable >= stableFrames) {
            if (!_hzActive) {
              debugPrint(
                '[Horizon] line ON  ax=${p0.$1.toStringAsFixed(2)} '
                'ay=${p0.$2.toStringAsFixed(2)} ang=${ang.toStringAsFixed(2)}',
              );
            }
            _hzTAngle = ang;
            _hzTAx = p0.$1;
            _hzTAy = p0.$2;
            _hzActive = true;
            _horizonSeenMs = hNow;
            _ensureHorizonTicking();
          }
        } else {
          _hzStable = 0;
          _hzRawA = null;
        }
        // Fade out unless a *stable* horizon was confirmed recently. Covers all
        // three loss cases: gone, too weak, or jumping between competing lines
        // (the latter keeps _hzStable below threshold so _horizonSeenMs stalls).
        if (_hzActive && hNow - _horizonSeenMs > 300) _hzActive = false;
      } catch (_) {}
    }

    _updateFaceTargets(dets); // ticker animates the displayed boxes
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

  /// Downsample (by [_detScale]) + physically rotate ([qt] quarter-turns CW) a
  /// BGRA buffer so faces/animals are upright. Returns tightly-packed bytes plus
  /// the output dimensions. Shared by ML Kit (faces) and Vision (animals).
  (Uint8List, int, int) _rotatedBytes(
    Uint8List src,
    int w,
    int h,
    int srcBpr,
    int qt,
  ) {
    final int s = _detScale;
    final int sw = w ~/ s, sh = h ~/ s;
    final int outW = (qt == 1 || qt == 3) ? sh : sw;
    final int outH = (qt == 1 || qt == 3) ? sw : sh;
    final bytes = Uint8List(outW * outH * 4);
    for (var dy = 0; dy < outH; dy++) {
      for (var dx = 0; dx < outW; dx++) {
        final int sx, sy;
        switch (qt) {
          case 1:
            sx = dy * s;
            sy = h - 1 - dx * s;
            break;
          case 3:
            sx = w - 1 - dy * s;
            sy = dx * s;
            break;
          case 2:
            sx = w - 1 - dx * s;
            sy = h - 1 - dy * s;
            break;
          default:
            sx = dx * s;
            sy = dy * s;
        }
        final si = sy * srcBpr + sx * 4;
        final di = (dy * outW + dx) * 4;
        bytes[di] = src[si];
        bytes[di + 1] = src[si + 1];
        bytes[di + 2] = src[si + 2];
        bytes[di + 3] = src[si + 3];
      }
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

  /// Map a normalised point in the upright detection buffer back into full-screen
  /// preview-normalised space (inverse rotation + the preview's horizontal
  /// stretch), so the horizon line sits exactly where face boxes would.
  (double, double) _mapHorizonPt(double ux, double uy, int qt) {
    final c = _invRotNorm(ux, uy, qt);
    return ((c.$1 - 0.5) * _previewStretchX + 0.5, c.$2);
  }

  /// The camera-visible band (between the top/bottom panels) expressed as a crop
  /// rectangle in the buffer that's been rotated by [qt] quarter-turns. The band
  /// is the preview-space y-range [topFrac, 1−botFrac]; this is its pre-image
  /// under the same rotation [_invRotNorm] uses, so cropping the rotated buffer
  /// to it keeps only the pixels the user can actually see.
  (double, double, double, double) _hzBandCrop(int qt) {
    final double t = _topInsetFrac, b = _bottomInsetFrac;
    switch (qt) {
      case 1:
        return (b, 0.0, 1.0 - t, 1.0);
      case 2:
        return (0.0, b, 1.0, 1.0 - t);
      case 3:
        return (t, 0.0, 1.0 - b, 1.0);
      default: // 0
        return (0.0, t, 1.0, 1.0 - b);
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

  // Must match the horizontal stretch applied to the preview in _buildPreview
  // (Matrix4.diagonal3Values(1.17, 1.0, 1.0)) so detection boxes line up with
  // faces across the full width, not just the centre.
  static const double _previewStretchX = 1.17;

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
    ({double angle, double ax, double ay, double op, double aligned})?
  >
  _horizon = ValueNotifier(null);
  int _horizonSeenMs = 0;
  // Horizon message-bubble level: 0 = guide only, 1 = detected (not level),
  // 2 = level on the guide. Drives the shared top hint bubble + the haptic.
  final ValueNotifier<int> _hzLevel = ValueNotifier(0);
  int _hzPrevLevel = 0;
  // Confident target (set only after the detection is strong AND stable).
  double? _hzTAngle, _hzTAx, _hzTAy;
  bool _hzActive = false; // a horizon is currently believed present
  // Displayed (eased) state + whether it's been seeded since the last appearance.
  double _hzDAngle = 0, _hzDAx = 0.5, _hzDAy = 0.5, _hzDOp = 0;
  bool _hzInit = false;
  // Temporal stability tracking: last raw detection + consecutive-consistent count.
  double? _hzRawA, _hzRawX, _hzRawY;
  int _hzStable = 0;

  // Rule-of-Thirds power points (normalised) — intersections of the 1/3 lines.
  static const List<List<double>> _powerPoints = [
    [1 / 3, 1 / 3],
    [2 / 3, 1 / 3],
    [1 / 3, 2 / 3],
    [2 / 3, 2 / 3],
  ];
  // Phi-Grid power points — intersections of the golden-section lines at
  // 1/φ² ≈ 0.382 and 1/φ ≈ 0.618.
  static const double _phiLo = 0.3819660113;
  static const double _phiHi = 0.6180339887;
  static const List<List<double>> _phiPoints = [
    [_phiLo, _phiLo],
    [_phiHi, _phiLo],
    [_phiLo, _phiHi],
    [_phiHi, _phiHi],
  ];
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
    switch (_compositionMode) {
      case CompositionMode.ruleOfThirds:
        return _powerPoints;
      case CompositionMode.goldenSection:
        return _phiPoints;
      case CompositionMode.fibonacciSpiral:
        // Single target: the spiral's eye (convergence point), as a band
        // fraction so it matches the dot the painter draws.
        if (_bandW <= 0 || _bandH <= 0) return null; // band not measured yet
        final eye = _goldenSpiralEyePx(
          Size(_bandW, _bandH),
          _spiralTurns,
          CompositionPainter._goldenSpiralFill,
        );
        return [
          [eye.dx / _bandW, eye.dy / _bandH],
        ];
      default:
        return null;
    }
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
        b.matched = true;
        b.lastSeenMs = now;
      } else {
        _faceBoxes.add(_FaceBox(cx, cy, w, h, now)); // new — fades/scales in
      }
    }

    // ── Alignment (Rule of Thirds / Phi Grid intersections, Spiral eye) ─────
    // Only in an alignment mode: flag each box with the target point it sits on
    // (if any), and fire a haptic the moment a box becomes newly aligned.
    final align = _modePowerPoints != null;
    // Target points remapped into the band the painter draws them in, so the
    // alignment test matches the dots on screen. May be 4 (grids) or 1 (spiral).
    final pp = _bandPowerPoints();
    bool newlyPerfect = false;
    for (final b in _faceBoxes) {
      int near = -1;
      bool perfect = false;
      if (align && b.matched) {
        final double halfW = b.tw / 2, halfH = b.th / 2;
        final double mx = halfW * (1 + _alignMargin);
        final double my = halfH * (1 + _alignMargin);
        double bestD = double.infinity;
        for (var i = 0; i < pp.length; i++) {
          final dx = pp[i][0] - b.tcx;
          final dy = pp[i][1] - b.tcy;
          // Inside the box (+margin) → counts as "almost".
          if (dx.abs() <= mx && dy.abs() <= my) {
            final d = dx * dx + dy * dy;
            if (d < bestD) {
              bestD = d;
              near = i;
            }
          }
        }
        // "Perfect" = the chosen point sits near the box centre (within
        // _perfectFrac of the box half-size, radially).
        if (near >= 0) {
          final nx = (pp[near][0] - b.tcx) / (halfW <= 0 ? 1 : halfW);
          final ny = (pp[near][1] - b.tcy) / (halfH <= 0 ? 1 : halfH);
          perfect = (nx * nx + ny * ny) <= _perfectFrac * _perfectFrac;
        }
      }
      // Haptic only on the transition into a fresh "perfect".
      if (perfect && !b.perfect) newlyPerfect = true;
      b.intersection = near;
      b.perfect = perfect;
    }
    if (newlyPerfect) _haptic('alignmentPing', intensity: 1.0);

    // Drive the hint via a notifier — 0 none, 1 almost (in box), 2 perfect
    // (near centre). Only the hint rebuilds, so flip-flops can't hurt FPS.
    int level = 0;
    if (align) {
      for (final b in _faceBoxes) {
        if (!b.matched || b.intersection < 0) continue;
        level = b.perfect ? 2 : math.max(level, 1);
        if (level == 2) break;
      }
    }
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

    // Grace window: a box that briefly stops matching (ML Kit drops the odd
    // frame) holds its position + opacity rather than flickering out. It only
    // fades once it's been unseen for longer than this.
    const int graceMs = 300;
    _faceBoxes.removeWhere((b) => !b.matched && b.opacity < 0.02);
    final pTarget = [0.0, 0.0, 0.0, 0.0];
    for (final b in _faceBoxes) {
      b.cx += (b.tcx - b.cx) * posK;
      b.cy += (b.tcy - b.cy) * posK;
      b.w += (b.tw - b.w) * posK;
      b.h += (b.th - b.h) * posK;
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
            CompositionPainter._horizonGuideRatio;
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
      }
      _hzPrevLevel = lvl;
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
      if (!await _ensurePhotoPermission()) return;
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common, // photos + videos
        hasAll: true,
        onlyAll: true,
      );
      if (albums.isEmpty) return;
      final album = albums.first;
      final count = await album.assetCountAsync;
      if (count == 0 || !mounted) return;

      _stopImageStream(); // no need to detect while the gallery covers the screen
      await Navigator.of(context).push(
        PageRouteBuilder(
          // Slide up like a sheet; pull-down-to-dismiss slides it back down.
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 260),
          pageBuilder: (_, _, _) => GalleryGridPage(album: album, count: count),
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
      debugPrint('Error opening gallery: $e');
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
      debugPrint('Error setting flash mode: $e');
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

    if (mounted) {
      setState(() {
        _resolution = newResolution;
        _isInitialized = true;
      });
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
                              painter: _FocusBracketPainter(
                                gold: Color(0xFFE5C158),
                              ),
                            ),
                          ),
                          if (_aeAfLocked) ...[
                            const SizedBox(height: 5),
                            const Text(
                              'AE/AF LOCK',
                              style: TextStyle(
                                color: Color(0xFFE5C158),
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
              child: IgnorePointer(
                ignoring: !_focusShown,
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
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: CompositionPainter(
                      _compositionMode,
                      glowSegs: _glowSegMap.values.toList(),
                      faceBoxes: _faceBoxes,
                      powerGlow: _powerGlow,
                      topInset: _topInset,
                      bottomInset: _bottomInset,
                      spiralTurns: _spiralTurns,
                      aspect: _aspectRatios[_aspectIndex].ratio,
                      horizon: _horizon,
                      repaint: Listenable.merge([_faceAnim, _horizon]),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Top settings panel
          Positioned(
            key: const ValueKey('topPanel'),
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopSettingsPanel(),
          ),

          // Grid on/off toggle — dims the overlay for a clean frame.
          if (_isInitialized && !_isRecording)
            Positioned(
              bottom: (_bottomInset > 0 ? _bottomInset : 160) + 14,
              right: 16,
              child: _buildGridToggle(),
            ),

          // Zoom level indicator — thin right-edge tag
          if (_currentZoom > _minZoom + 0.05)
            Positioned(
              top: 0,
              bottom: 0,
              right: 12,
              child: Align(
                alignment: Alignment.center,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.10),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      '${_currentZoom.toStringAsFixed(1)}×',
                      style: const TextStyle(
                        color: Color(0xFFE5C158),
                        fontSize: 11,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 0.8,
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
            child: Container(
              key: _bottomPanelKey,
              padding: const EdgeInsets.only(
                left: 20,
                right: 20,
                bottom: 16,
                top: 4,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.48),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.07),
                    width: 0.5,
                  ),
                ),
              ),
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
                        });
                        _showCompositionTip(); // "best for" bubble (~3s)
                      },
                      itemCount: _compositionModes.length,
                      itemBuilder: (context, index) {
                        final double opacity =
                            (index - _currentCompositionIndex).abs() <= 1
                            ? 1.0 -
                                  (index - _currentCompositionIndex).abs() * 0.4
                            : 0.3;
                        return Center(
                          child: Opacity(
                            opacity: opacity.clamp(0.3, 1.0),
                            child: _buildCompositionButton(
                              _compositionModes[index].label,
                              isSelected: index == _currentCompositionIndex,
                            ),
                          ),
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
                  // Camera controls row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Gallery button (left, centred with capture button)
                      GestureDetector(
                        onTap: _isRecording ? null : _openGalleryViewer,
                        child: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.30),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.28),
                              width: 1.0,
                            ),
                          ),
                          child: _latestThumbnail != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(9),
                                  child: Image.memory(
                                    _latestThumbnail!,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : _rotated(
                                  Icon(
                                    Icons.photo_library_outlined,
                                    color: Colors.white.withValues(alpha: 0.55),
                                    size: 24,
                                  ),
                                ),
                        ),
                      ),

                      // Capture button (center) - tap for photo, hold for video
                      _buildGlassCaptureButton(),

                      // Right slot: a mode-specific control (spiral rotate /
                      // aspect-ratio cycle), otherwise empty space for symmetry.
                      _buildRightSlotControl(),
                    ],
                  ),
                ],
              ),
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
                              color: Color(0xFFE5C158),
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
                final appear = (_bounceController!.value / 0.12).clamp(0.0, 1.0);
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
          // alignment modes (power points) and Horizon Grid; suppressed while the
          // tip bubble shows (they share the same spot).
          if ((_modePowerPoints != null ||
                  _compositionMode == CompositionMode.horizonGrid) &&
              !_isRecording &&
              !_showTip &&
              _gridVisible)
            Positioned(
              top: MediaQuery.of(context).padding.top + 92,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: RepaintBoundary(
                    child: ValueListenableBuilder<int>(
                      valueListenable:
                          _compositionMode == CompositionMode.horizonGrid
                          ? _hzLevel
                          : _alignLevel,
                      builder: (_, level, __) => _buildCompositionHint(level),
                    ),
                  ),
                ),
              ),
            ),

          // "Best for" tip bubble — drops down from behind the top panel on mode
          // change and retracts back up under it (iMessage-style). Anchored at
          // the panel's bottom edge and clipped there so it tucks cleanly under
          // the chrome on both auto-dismiss and swipe-up.
          Positioned(
            top: _topInset > 0
                ? _topInset
                : MediaQuery.of(context).padding.top + 56,
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRect(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: _buildTipBubble(),
                ),
              ),
            ),
          ),

          // Shutter flash effect (on top of everything)
          if (_showShutterFlash)
            Positioned.fill(child: Container(color: Colors.white)),

          // FPS counter (testing) — top right.
          Positioned(
            top: MediaQuery.of(context).padding.top + 60,
            right: 12,
            child: const IgnorePointer(child: _FpsOverlay()),
          ),

          // Branded loading state — full-screen, shown only while the camera is
          // starting up and gated on real readiness (_isInitialized), not a
          // timer. Crossfades out the instant the preview is live; absorbs taps
          // while loading so the shutter can't fire early.
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: !_isInitialized && _error == null,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 450),
                child: (!_isInitialized && _error == null)
                    ? const BrandedLoader(key: ValueKey('loader'))
                    : const SizedBox.shrink(key: ValueKey('ready')),
              ),
            ),
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
  Widget _buildTipBubble() {
    final tip = _compositionTip;
    final bool visible = _showTip && tip != null && !_isRecording;
    const gold = Color(0xFFE5C158);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        // Drops in gently (settle), retracts upward with a touch of acceleration.
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        // Slide + scale only (no opacity layer) so the frosted backdrop blur
        // stays live throughout; the panel-edge clip handles disappearance.
        transitionBuilder: (child, anim) => SlideTransition(
          position: Tween<Offset>(
            // Travels > full height so it fully clears the panel edge.
            begin: const Offset(0, -1.4),
            end: Offset.zero,
          ).animate(anim),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(anim),
            alignment: Alignment.topCenter,
            child: child,
          ),
        ),
        child: !visible
            ? const SizedBox.shrink(key: ValueKey('noTip'))
            : GestureDetector(
                key: ValueKey(_compositionMode),
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) < 0) _dismissTip(); // swipe up
                },
                onTap: _dismissTip,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  // Soft drop shadow for lift off the preview.
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    // Frost the camera behind the pill.
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          // Top sheen → dark base: glassy, and keeps white text
                          // legible over any camera scene.
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.14),
                              Colors.black.withValues(alpha: 0.34),
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.30),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.auto_awesome_rounded,
                              color: gold,
                              size: 14,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                tip,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.92),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w400,
                                  letterSpacing: 0.2,
                                  height: 1.25,
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
    );
  }

  /// Top hint for Rule of Thirds. Smoothly morphs between three states:
  ///   0 — translucent instruction pill
  ///   1 — "Almost" (subject's box is on a point, but off-centre)
  ///   2 — "Perfect" (point near the box centre), ambient breathing gold glow.
  Widget _buildCompositionHint(int level) {
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
      child: switch (level) {
        2 => _perfectBadge(),
        1 => _almostBadge(),
        _ => _instructionPill(),
      },
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
    const gold = Color(0xFFE5C158);
    Widget build(double pulse) {
      final Color textColor = emphasis
          ? gold
          : Colors.white.withValues(alpha: 0.92);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.18),
              Colors.black.withValues(alpha: 0.52),
            ],
          ),
          border: Border.all(
            color: emphasis
                ? gold.withValues(alpha: 0.45 + 0.40 * pulse)
                : Colors.white.withValues(alpha: 0.28),
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
              color: emphasis ? gold.withValues(alpha: 0.75 + 0.25 * pulse) : gold,
              size: 14,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: textColor,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.2,
                  height: 1.25,
                ),
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
        'Line your horizon up with the gold line',
      ),
      _ => (
        Icons.grid_3x3_rounded,
        'Place your subject on an intersection',
      ),
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
    switch (_compositionMode) {
      case CompositionMode.fibonacciSpiral:
        return _buildSpiralRotateButton();
      case CompositionMode.aspectRatio:
        return _buildAspectRatioButton();
      default:
        return const SizedBox(width: 52);
    }
  }

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
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.28),
            width: 1.0,
          ),
        ),
        child: Center(
          child: _rotated(
            Text(
              _aspectRatios[_aspectIndex].label,
              style: const TextStyle(
                color: Color(0xFFE5C158),
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

  /// Rotate control shown in the controls row while Fibonacci Spiral is active.
  /// Each tap turns the spiral 90° clockwise, cycling its eye through the four
  /// corners. Styled to mirror the gallery button on the opposite side.
  Widget _buildSpiralRotateButton() {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _spiralTurns = (_spiralTurns + 1) & 3);
      },
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.28),
            width: 1.0,
          ),
        ),
        child: _rotated(
          const Icon(
            Icons.rotate_90_degrees_cw_rounded,
            color: Color(0xFFE5C158),
            size: 24,
          ),
        ),
      ),
    );
  }

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
                // Outer glow shadow - animated during recording
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
                          color: Colors.white.withValues(
                            alpha: 0.4 * glowIntensity,
                          ),
                          blurRadius: 20,
                        ),
                      ]
                    : null,
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

                  // Main glass container - no blur
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.transparent,
                      border: Border.all(
                        color: _isRecording
                            ? Colors.white.withValues(
                                alpha: 0.6 + (0.3 * glowIntensity),
                              )
                            : Colors.white.withValues(alpha: 0.7),
                        width: 2.5,
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
    const gold = Color(0xFFE5C158);
    final on = _gridVisible;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _gridVisible = !_gridVisible);
      },
      child: ClipOval(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: on ? 0.26 : 0.40),
              border: Border.all(
                color: on
                    ? gold.withValues(alpha: 0.65)
                    : Colors.white.withValues(alpha: 0.20),
                width: on ? 1.0 : 0.8,
              ),
            ),
            child: Icon(
              on ? Icons.grid_3x3_rounded : Icons.grid_off,
              color: on ? gold : Colors.white.withValues(alpha: 0.6),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }

  /// Vertical exposure (EV) slider with a draggable sun knob. Drag up = brighter.
  Widget _buildExposureSlider(double h) {
    const gold = Color(0xFFE5C158);
    final range = _maxExposure - _minExposure;
    final frac = range > 0
        ? ((_exposureOffset - _minExposure) / range).clamp(0.0, 1.0)
        : 0.5;
    const knob = 24.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) => _adjustExposure(-d.delta.dy, h),
      child: SizedBox(
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
      ),
    );
  }

  Widget _buildTopSettingsPanel() {
    const Color gold = Color(0xFFE5C158);
    return Container(
      key: _topPanelKey,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 10,
        bottom: 14,
        left: 20,
        right: 20,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.48),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.07),
            width: 0.5,
          ),
        ),
      ),
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
            onTap: _toggleFlash,
          ),

          // Divider
          Container(
            height: 22,
            width: 0.5,
            color: Colors.white.withValues(alpha: 0.15),
          ),

          // Format control
          _buildSettingButton(label: _imageFormat, onTap: _toggleImageFormat),

          // Divider
          Container(
            height: 22,
            width: 0.5,
            color: Colors.white.withValues(alpha: 0.15),
          ),

          // Resolution control
          _buildSettingButton(
            label: _resolution == ResolutionPreset.veryHigh ? '24MP' : '48MP',
            onTap: _toggleResolution,
          ),
        ],
      ),
    );
  }

  Widget _buildSettingButton({
    String? label,
    IconData? icon,
    Color? iconColor,
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
                      'FLASH',
                      style: TextStyle(
                        color: isIconActive
                            ? const Color(0xFFE5C158)
                            : Colors.white.withValues(alpha: 0.42),
                        fontSize: 7.5,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 1.6,
                      ),
                    ),
                  ],
                )
              : Text(
                  label!.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 1.8,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildCompositionButton(String type, {bool isSelected = false}) {
    const Color gold = Color(0xFFE5C158);
    return isSelected
        ? ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: gold.withValues(alpha: 0.10),
                  border: Border.all(
                    color: gold.withValues(alpha: 0.65),
                    width: 1.0,
                  ),
                ),
                alignment: Alignment.center,
                child: _rotated(
                  Text(
                    type.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFE5C158),
                      fontSize: 9,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: _rotated(
              Text(
                type.toUpperCase(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.32),
                  fontSize: 9,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          );
  }

  Future<void> _switchToUltraWide() async {
    if (_ultraWideCamera == null || _isUsingUltraWide || _isSwitchingLens)
      return;
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
      debugPrint('_switchToUltraWide: $e');
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
      debugPrint('_switchToMainCamera: $e');
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
    _currentZoom = _currentZoom.clamp(_minZoom, _maxZoom);
    _isUsingUltraWide = false;
    _controller = nc;
    _isSwitchingLens = false;
    if (mounted) setState(() {});
    await _startImageStream();
  }

  Future<void> _setCameraZoom(double value) async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    if (_usesVirtualCamera) {
      // ── Native seamless-zoom path ───────────────────────────────────────────
      // Writes directly to AVCaptureDevice.videoZoomFactor, bypassing the
      // Flutter plugin's setZoomLevel path. This is the same device the plugin's
      // AVCaptureSession holds, so the change applies on the very next frame —
      // zero session teardown, zero black frame, no controller swap ever.
      final double clamped = value.clamp(_minZoom, _maxZoom);
      try {
        await _CameraZoomChannel.instance.setZoom(clamped);
        if (mounted) setState(() => _currentZoom = clamped);
      } catch (e) {
        // Native channel unavailable — fall back to plugin path.
        debugPrint('_setCameraZoom native failed ($e) — using plugin fallback');
        try {
          await _controller!.setZoomLevel(clamped);
          if (mounted) setState(() => _currentZoom = clamped);
        } catch (e2) {
          debugPrint('_setCameraZoom plugin: $e2');
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
          if (mounted) setState(() => _currentZoom = clamped);
          return;
        }
      }
      final double physical = (v * _ultraWideScaleFactor).clamp(
        _ultraWideScaleFactor * 0.5,
        _maxZoom,
      );
      try {
        await _controller!.setZoomLevel(physical);
        if (mounted) setState(() => _currentZoom = v);
      } catch (e) {
        debugPrint('_setCameraZoom ultra-wide: $e');
      }
    } else {
      if (_isUsingUltraWide) {
        await _switchToMainCamera();
        if (_controller == null || !_controller!.value.isInitialized) return;
      }
      final double clamped = v.clamp(_minZoom, _maxZoom);
      try {
        await _controller!.setZoomLevel(clamped);
        if (mounted) setState(() => _currentZoom = clamped);
      } catch (e) {
        debugPrint('_setCameraZoom main: $e');
      }
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Zoom meter — horizontal scroll wheel with hairline ticks
  // ────────────────────────────────────────────────────────────────────────────

  Widget _buildZoomMeter() {
    const double pxPerUnit = 36.0;
    final double clampedZoom = _currentZoom.clamp(0.5, _zoomMax);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${clampedZoom < 1 ? clampedZoom.toStringAsFixed(1) : clampedZoom.toStringAsFixed(1)}×',
          style: const TextStyle(
            color: Color(0xFFE5C158),
            fontSize: 13,
            fontWeight: FontWeight.w300,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 1),
        GestureDetector(
          onHorizontalDragStart: (d) {
            _meterDragStart = d.localPosition.dx;
            _zoomAtDragStart = clampedZoom;
          },
          onHorizontalDragUpdate: (d) {
            final double delta = d.localPosition.dx - _meterDragStart;
            final double newZoom = (_zoomAtDragStart - delta / pxPerUnit).clamp(
              0.5,
              _zoomMax,
            );
            _setCameraZoom(newZoom);
          },
          onHorizontalDragEnd: (_) {},
          child: SizedBox(
            width: double.infinity,
            height: 36,
            child: CustomPaint(
              painter: _ZoomMeterPainter(
                zoom: clampedZoom,
                maxZoom: _zoomMax,
                pxPerUnit: pxPerUnit,
                switchoverFactors: _switchoverFactors,
              ),
            ),
          ),
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
    final double clampedZoom = _currentZoom.clamp(0.5, _zoomMax);

    return ClipPath(
      clipper: _SemicircleFromRightClipper(),
      child: Container(
        width: w,
        height: h,
        color: Colors.black.withValues(alpha: 0.50),
        child: GestureDetector(
          onVerticalDragStart: (d) {
            _meterDragStart = d.localPosition.dy;
            _zoomAtDragStart = clampedZoom;
          },
          onVerticalDragUpdate: (d) {
            final delta = d.localPosition.dy - _meterDragStart;
            // Up (negative delta) → zoom in; down → zoom out.
            final newZoom = (_zoomAtDragStart - delta / pxPerUnit).clamp(
              0.5,
              _zoomMax,
            );
            _setCameraZoom(newZoom);
          },
          onVerticalDragEnd: (_) {},
          child: CustomPaint(
            painter: _VerticalZoomMeterPainter(
              zoom: clampedZoom,
              maxZoom: _zoomMax,
              pxPerUnit: pxPerUnit,
              switchoverFactors: _switchoverFactors,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (_error != null) {
      return Container(
        color: const Color(0xFF1a1a1a),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 80),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
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
      transform: Matrix4.diagonal3Values(1.17, 1.0, 1.0),
      child: CameraPreview(_controller!),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Focus bracket painter — corner-bracket focus indicator
// ─────────────────────────────────────────────────────────────────────────────

class _FocusBracketPainter extends CustomPainter {
  final Color gold;
  const _FocusBracketPainter({required this.gold});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gold
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = true;

    const double arm = 14.0;
    final double w = size.width;
    final double h = size.height;

    // Top-left corner
    canvas.drawLine(Offset(0, arm), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), Offset(arm, 0), paint);
    // Top-right corner
    canvas.drawLine(Offset(w - arm, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, arm), paint);
    // Bottom-right corner
    canvas.drawLine(Offset(w, h - arm), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w - arm, h), paint);
    // Bottom-left corner
    canvas.drawLine(Offset(arm, h), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(0, h - arm), paint);

    // Center focus dot
    canvas.drawCircle(
      Offset(w / 2, h / 2),
      1.5,
      paint
        ..style = PaintingStyle.fill
        ..color = gold.withValues(alpha: 0.70),
    );
  }

  @override
  bool shouldRepaint(_FocusBracketPainter old) => old.gold != gold;
}

// ────────────────────────────────────────────────────────────────────────────
// Zoom meter painter — hairline tick wheel
// ────────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────────
// Native seamless zoom bridge
// Communicates with AVCaptureDevice.videoZoomFactor directly via MethodChannel,
// bypassing Flutter’s own CameraController zoom path. This is what makes
// lens switching truly seamless — the device’s active session is never torn
// down; iOS handles physical lens selection internally.
// ────────────────────────────────────────────────────────────────────────────

class _CameraZoomChannel {
  static const MethodChannel _ch = MethodChannel('com.phily.camera/zoom');
  static final instance = _CameraZoomChannel._();
  _CameraZoomChannel._();

  /// Immediate zoom — for continuous drag input.
  /// Writes AVCaptureDevice.videoZoomFactor directly; reflects on next frame.
  Future<void> setZoom(double factor) =>
      _ch.invokeMethod('setZoom', {'factor': factor});

  /// Hardware-animated zoom ramp — for discrete level taps.
  /// Uses AVCaptureDevice.ramp(toVideoZoomFactor:withRate:) which is
  /// frame-accurate and cancels any previous ramp atomically.
  Future<void> rampZoom(double factor, {double rate = 5.0}) =>
      _ch.invokeMethod('rampZoom', {'factor': factor, 'rate': rate});

  /// Returns {min, max, current, switchoverFactors} from the native device.
  /// switchoverFactors contains the exact zoom levels where iOS transitions
  /// between physical lenses (e.g. [2.0, 6.0] on iPhone 14 Pro).
  Future<Map<String, dynamic>?> getZoomInfo() async {
    final raw = await _ch.invokeMethod<Map>('getZoomInfo');
    if (raw == null) return null;
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
}

class _ZoomMeterPainter extends CustomPainter {
  final double zoom; // current logical zoom level
  final double maxZoom; // software upper bound (25.0)
  final double pxPerUnit; // logical pixels per 1×
  final List<double> switchoverFactors; // hardware lens-switch boundaries

  const _ZoomMeterPainter({
    required this.zoom,
    required this.maxZoom,
    required this.pxPerUnit,
    this.switchoverFactors = const [],
  });

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _gold = Color(0xFFE5C158);

  // Major tick labels shown on the wheel.
  static const List<double> _major = [0.5, 1, 2, 5, 10, 15, 20, 25];

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height;

    // How many zoom units are visible on each side of centre.
    final double visibleUnits = (size.width / 2) / pxPerUnit;

    final double lo = (zoom - visibleUnits - 1).floorToDouble().clamp(
      0.5,
      maxZoom,
    );
    final double hi = (zoom + visibleUnits + 1).ceilToDouble().clamp(
      0.5,
      maxZoom,
    );

    // Draw minor ticks every 0.1×, major ticks at the _major values.
    final Paint tickPaint = Paint()
      ..color = _white.withValues(alpha: 0.28)
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.butt;

    final Paint majorPaint = Paint()
      ..color = _white.withValues(alpha: 0.55)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.butt;

    // Centre indicator line (gold)
    final Paint centrePaint = Paint()
      ..color = _gold
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.butt;

    final TextPainter tp = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );

    // Iterate every 0.1× step in the visible range.
    double v = (lo * 10).round() / 10;
    while (v <= hi + 0.05) {
      final double x = cx + (v - zoom) * pxPerUnit;
      if (x < 0 || x > size.width) {
        v = (v * 10).round() / 10 + 0.1;
        continue;
      }

      // A tick is a hardware lens-switchover boundary if it matches one of the
      // virtualDeviceSwitchOverVideoZoomFactors reported by iOS. These get a
      // gold accent tick (like the native Camera app's 0.5×/1×/2× indicators).
      final bool isSwitchover = switchoverFactors.any(
        (s) => (v - s).abs() < 0.08,
      );
      final bool isMajor =
          _major.any((m) => (v - m).abs() < 0.02) || isSwitchover;
      final double tickH = isSwitchover ? 20.0 : (isMajor ? 16.0 : 8.0);
      final Paint p = isSwitchover
          ? (Paint()
              ..color = _gold.withValues(alpha: 0.75)
              ..strokeWidth = 1.2
              ..strokeCap = StrokeCap.butt)
          : (isMajor ? majorPaint : tickPaint);

      canvas.drawLine(Offset(x, cy - tickH), Offset(x, cy), p);

      if (isMajor) {
        final String label = v < 1
            ? v.toStringAsFixed(1)
            : v.toInt().toString();
        tp.text = TextSpan(
          text: label,
          style: TextStyle(
            color: isSwitchover
                ? _gold.withValues(alpha: 0.80)
                : _white.withValues(alpha: 0.55),
            fontSize: 8,
            fontWeight: isSwitchover ? FontWeight.w400 : FontWeight.w300,
            letterSpacing: 0.5,
          ),
        );
        tp.layout();
        tp.paint(canvas, Offset(x - tp.width / 2, cy - tickH - tp.height - 2));
      }

      v = ((v * 10).round() / 10) + 0.1;
      v = double.parse(v.toStringAsFixed(1)); // avoid float drift
    }

    // Centre indicator
    canvas.drawLine(Offset(cx, cy - 22), Offset(cx, cy), centrePaint);
  }

  @override
  bool shouldRepaint(_ZoomMeterPainter old) =>
      old.zoom != zoom || old.switchoverFactors != switchoverFactors;
}

// ─────────────────────────────────────────────────────────────────────────────
// Semicircle clipper — clips a rectangle to the left half of a circle whose
// centre sits at the right edge. Creates the "popping out from the right" shape.
// ─────────────────────────────────────────────────────────────────────────────

class _SemicircleFromRightClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    // Arc centre is at the right edge, vertically centred.
    // Sweeping 180° counterclockwise from top traces the left semicircle.
    path.addArc(
      Rect.fromCenter(
        center: Offset(size.width, size.height / 2),
        width: size.height, // diameter = height → radius = height/2
        height: size.height,
      ),
      -math.pi / 2, // start at top  (12 o'clock)
      -math.pi, // sweep 180° CCW → through 9 o'clock to 6 o'clock
    );
    path.close(); // straight line back along the right edge
    return path;
  }

  @override
  bool shouldReclip(_SemicircleFromRightClipper _) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Vertical zoom meter painter — like _ZoomMeterPainter but rotated 90°.
// Ticks are horizontal lines emanating from the right edge.
// Drag up = zoom in, drag down = zoom out.
// ─────────────────────────────────────────────────────────────────────────────

class _VerticalZoomMeterPainter extends CustomPainter {
  final double zoom;
  final double maxZoom;
  final double pxPerUnit;
  final List<double> switchoverFactors;

  const _VerticalZoomMeterPainter({
    required this.zoom,
    required this.maxZoom,
    required this.pxPerUnit,
    this.switchoverFactors = const [],
  });

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _gold = Color(0xFFE5C158);
  static const List<double> _major = [0.5, 1, 2, 5, 10, 15, 20, 25];

  @override
  void paint(Canvas canvas, Size size) {
    final double cy = size.height / 2;
    final double rx = size.width; // right edge — tick origin

    final double visibleUnits = (size.height / 2) / pxPerUnit;
    final double lo = (zoom - visibleUnits - 1).floorToDouble().clamp(
      0.5,
      maxZoom,
    );
    final double hi = (zoom + visibleUnits + 1).ceilToDouble().clamp(
      0.5,
      maxZoom,
    );

    final Paint tickPaint = Paint()
      ..color = _white.withValues(alpha: 0.28)
      ..strokeWidth = 0.8;
    final Paint majorPaint = Paint()
      ..color = _white.withValues(alpha: 0.55)
      ..strokeWidth = 1.0;
    final Paint centrePaint = Paint()
      ..color = _gold
      ..strokeWidth = 1.5;

    final TextPainter tp = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    );

    double v = (lo * 10).round() / 10;
    while (v <= hi + 0.05) {
      final double y = cy + (v - zoom) * pxPerUnit;
      if (y < 0 || y > size.height) {
        v = double.parse(((v * 10).round() / 10 + 0.1).toStringAsFixed(1));
        continue;
      }

      final bool isSwitchover = switchoverFactors.any(
        (s) => (v - s).abs() < 0.08,
      );
      final bool isMajor =
          _major.any((m) => (v - m).abs() < 0.02) || isSwitchover;
      final double tickLen = isSwitchover ? 22.0 : (isMajor ? 16.0 : 7.0);

      final Paint p = isSwitchover
          ? (Paint()
              ..color = _gold.withValues(alpha: 0.75)
              ..strokeWidth = 1.2)
          : (isMajor ? majorPaint : tickPaint);

      // Horizontal tick from right edge going left
      canvas.drawLine(Offset(rx - tickLen, y), Offset(rx, y), p);

      if (isMajor) {
        final String label = v < 1
            ? v.toStringAsFixed(1)
            : v.toInt().toString();
        tp.text = TextSpan(
          text: label,
          style: TextStyle(
            color: isSwitchover
                ? _gold.withValues(alpha: 0.85)
                : _white.withValues(alpha: 0.55),
            fontSize: 8,
            fontWeight: isSwitchover ? FontWeight.w400 : FontWeight.w300,
            letterSpacing: 0.4,
          ),
        );
        tp.layout();
        // Label sits just to the left of the tick, vertically centred on it
        tp.paint(
          canvas,
          Offset(rx - tickLen - tp.width - 3, y - tp.height / 2),
        );
      }

      v = double.parse(((v * 10).round() / 10 + 0.1).toStringAsFixed(1));
    }

    // Centre indicator — gold horizontal line at current zoom position
    canvas.drawLine(Offset(rx - 26, cy), Offset(rx, cy), centrePaint);

    // Current zoom label centred on the indicator
    final String zLabel =
        '${zoom < 1 ? zoom.toStringAsFixed(1) : zoom.toStringAsFixed(1)}×';
    tp.text = TextSpan(
      text: zLabel,
      style: const TextStyle(
        color: _gold,
        fontSize: 11,
        fontWeight: FontWeight.w300,
        letterSpacing: 1.0,
      ),
    );
    tp.layout();
    tp.paint(
      canvas,
      Offset(rx - tickLen(zoom) - tp.width - 6, cy - tp.height / 2),
    );
  }

  double tickLen(double v) {
    final isSwitchover = switchoverFactors.any((s) => (v - s).abs() < 0.08);
    final isMajor = _major.any((m) => (v - m).abs() < 0.02) || isSwitchover;
    return isSwitchover ? 22.0 : (isMajor ? 16.0 : 7.0);
  }

  @override
  bool shouldRepaint(_VerticalZoomMeterPainter old) =>
      old.zoom != zoom || old.switchoverFactors != switchoverFactors;
}

// ─────────────────────────────────────────────────────────────────────────────
// Composition mode enum
// ─────────────────────────────────────────────────────────────────────────────

enum CompositionMode {
  none,
  horizonGrid,
  ruleOfThirds,
  goldenSection,
  goldenTriangles,
  spiralSection,
  fibonacciSpiral,
  harmoniousTriangles,
  cross,
  focalMass,
  vArrangement,
  diagonal,
  radial,
  lArrangement,
  compoundCurve,
  pyramid,
  circular,
  symmetry,
  aspectRatio;

  String get label {
    switch (this) {
      case CompositionMode.none:
        return 'None';
      case CompositionMode.horizonGrid:
        return 'Horizon Grid';
      case CompositionMode.ruleOfThirds:
        return 'Rule of Thirds';
      case CompositionMode.goldenSection:
        return 'Phi Grid';
      case CompositionMode.goldenTriangles:
        return 'Golden Triangles';
      case CompositionMode.spiralSection:
        return 'Spiral Section';
      case CompositionMode.fibonacciSpiral:
        return 'Fibonacci Spiral';
      case CompositionMode.harmoniousTriangles:
        return 'Harmonious Triangles';
      case CompositionMode.cross:
        return 'Cross';
      case CompositionMode.focalMass:
        return 'Focal Mass';
      case CompositionMode.vArrangement:
        return 'V Arrangement';
      case CompositionMode.diagonal:
        return 'Diagonal';
      case CompositionMode.radial:
        return 'Radial';
      case CompositionMode.lArrangement:
        return 'L Arrangement';
      case CompositionMode.compoundCurve:
        return 'Compound Curve';
      case CompositionMode.pyramid:
        return 'Pyramid';
      case CompositionMode.circular:
        return 'Circular';
      case CompositionMode.symmetry:
        return 'Symmetry';
      case CompositionMode.aspectRatio:
        return 'Aspect Ratio';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Single painter that dispatches to the correct drawing routine
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Glow segment — a normalised grid-line coordinate with per-frame intensity
// ─────────────────────────────────────────────────────────────────────────────

// Coordinates are normalised to [0,1]. Intensity fades in/out each analysis frame.
class _GlowSeg {
  double x1, y1, x2, y2;
  double intensity;
  _GlowSeg(this.x1, this.y1, this.x2, this.y2, this.intensity);
}

/// An animated face indicator. Holds the current (eased) box and the latest
/// detection target, plus opacity/appearance so it can fade and ease smoothly
/// at display framerate, decoupled from the slower detection rate.
class _FaceBox {
  // Current animated values (normalised screen space, centre + size).
  double cx, cy, w, h;
  // Latest detection target.
  double tcx, tcy, tw, th;
  double opacity; // 0..1, fades in on appear / out on loss
  double appear; // 0..1, drives a subtle scale-in
  bool matched; // matched in the most recent detection cycle
  int lastSeenMs; // last time it was matched — grace window before fading
  int
  intersection; // index 0..3 of the rule-of-thirds power point it's on, -1 none
  bool perfect; // true when that point sits near the box centre
  double alignGlow; // 0..1 animated alignment-glow strength
  _FaceBox(this.cx, this.cy, this.w, this.h, this.lastSeenMs)
    : tcx = cx,
      tcy = cy,
      tw = w,
      th = h,
      opacity = 0,
      appear = 0,
      matched = true,
      intersection = -1,
      perfect = false,
      alignGlow = 0;
}

/// Lightweight on-screen FPS meter (testing). Counts vsync ticks via a Ticker
/// and reports the actual rendered frame rate, updating ~twice a second.
class _FpsOverlay extends StatefulWidget {
  const _FpsOverlay();
  @override
  State<_FpsOverlay> createState() => _FpsOverlayState();
}

class _FpsOverlayState extends State<_FpsOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _frames = 0;
  int _lastMs = DateTime.now().millisecondsSinceEpoch;
  double _fps = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      _frames++;
      final now = DateTime.now().millisecondsSinceEpoch;
      final dt = now - _lastMs;
      if (dt >= 500) {
        setState(() => _fps = _frames * 1000 / dt);
        _frames = 0;
        _lastMs = now;
      }
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = _fps >= 55
        ? const Color(0xFF4CD964) // green
        : _fps >= 30
        ? const Color(0xFFE5C158) // gold
        : const Color(0xFFFF3B30); // red
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${_fps.toStringAsFixed(0)} FPS',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Pixel position (in [size] space) of the Fibonacci-spiral "eye" — the point
/// the arcs converge to — for [turns] 90° clockwise rotations and [fill] frame
/// fraction. Mirrors `_drawGoldenSpiral`'s geometry exactly so the alignment
/// target and the dot the user sees always coincide. Shared by the painter and
/// the alignment logic.
Offset _goldenSpiralEyePx(Size size, int turns, double fill) {
  const double phi = 1.6180339887;
  final int t = turns & 3;
  final bool swap = t.isOdd;
  final double fw = swap ? size.height : size.width;
  final double fh = swap ? size.width : size.height;
  final double maxW = fw * fill, maxH = fh * fill;
  double w = maxW, h = w / phi;
  if (h > maxH) {
    h = maxH;
    w = h * phi;
  }
  Rect rect = Rect.fromLTWH((fw - w) / 2, (fh - h) / 2, w, h);
  int dir = 0;
  // Cut squares until the remaining rect collapses onto the eye (sub-pixel).
  for (int i = 0; i < 20; i++) {
    final double sq = math.min(rect.width, rect.height);
    switch (dir) {
      case 0:
        rect = Rect.fromLTRB(rect.left, rect.top, rect.right - sq, rect.bottom);
        break;
      case 1:
        rect = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom - sq);
        break;
      case 2:
        rect = Rect.fromLTRB(rect.left + sq, rect.top, rect.right, rect.bottom);
        break;
      default:
        rect = Rect.fromLTRB(rect.left, rect.top + sq, rect.right, rect.bottom);
    }
    dir = (dir + 1) % 4;
  }
  final Offset local = rect.center;
  // Same transform the painter applies: about the band centre, rotate t·90°,
  // with the (fw × fh) frame centred there.
  final double a = t * (math.pi / 2);
  final double dx = local.dx - fw / 2, dy = local.dy - fh / 2;
  final double rx = dx * math.cos(a) - dy * math.sin(a);
  final double ry = dx * math.sin(a) + dy * math.cos(a);
  return Offset(size.width / 2 + rx, size.height / 2 + ry);
}

class CompositionPainter extends CustomPainter {
  final CompositionMode mode;

  /// Lines from the active grid that are currently edge-aligned.
  final List<_GlowSeg> glowSegs;

  /// Animated face indicators (drawn as corner brackets).
  final List<_FaceBox> faceBoxes;

  /// Per-power-point glow strength (0..1) for Rule-of-Thirds alignment.
  final List<double> powerGlow;

  /// Heights (px) of the top/bottom UI panels. The composition grid is drawn
  /// only within the camera-visible band `[topInset, height − bottomInset]`,
  /// so guide lines stop at the panel edges instead of sliding under them.
  final double topInset;
  final double bottomInset;

  /// Fibonacci-spiral orientation in 90° clockwise turns (0..3).
  final int spiralTurns;

  /// Selected crop ratio (W/H) for the Aspect Ratio mode.
  final double aspect;

  /// Detected horizon (preview space): roll angle + an anchor point on the line
  /// (full-screen normalised) + fade opacity + alignment-with-guide [0..1], or
  /// null. Drawn in Horizon Grid mode.
  final ValueNotifier<
    ({double angle, double ax, double ay, double op, double aligned})?
  >?
  horizon;
  CompositionPainter(
    this.mode, {
    List<_GlowSeg>? glowSegs,
    List<_FaceBox>? faceBoxes,
    List<double>? powerGlow,
    this.topInset = 0,
    this.bottomInset = 0,
    this.spiralTurns = 0,
    this.aspect = 1.0,
    this.horizon,
    Listenable? repaint,
  }) : glowSegs = glowSegs ?? const [],
       faceBoxes = faceBoxes ?? const [],
       powerGlow = powerGlow ?? const [0, 0, 0, 0],
       super(repaint: repaint);

  static const Color _gold = Color(0xFFFFFFFF);
  static const double _sw = 0.8;

  /// Fraction of the frame the golden-spiral rectangle fills (1.0 = edge-to-
  /// edge like the reference; lower for more breathing room).
  static const double _goldenSpiralFill = 1.0;

  /// Where the Horizon Grid's guide line sits, as a fraction of the camera band
  /// from the top. 0.618 = the golden-section "low horizon" — the line falls in
  /// the lower part of the frame, leaving ~62% sky above, which landscape
  /// research finds the most balanced default (sky-forward, not centred/static).
  /// Foreground-heavy scenes suit the upper golden line (0.382) instead.
  static const double _horizonGuideRatio = 0.6180339887;

  /// Normal white hairline paint used by all draw methods.
  Paint _gp({StrokeCap cap = StrokeCap.butt}) => Paint()
    ..color = _gold.withValues(alpha: 0.45)
    ..strokeWidth = _sw
    ..style = PaintingStyle.stroke
    ..strokeCap = cap
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  Paint get _p => _gp(cap: StrokeCap.round);

  /// Draws one rounded L-shaped corner bracket. [sx]/[sy] are ±1 indicating the
  /// direction the arms extend from the corner [c]; [arm] is arm length, [r] the
  /// rounding radius at the corner.
  void _corner(
    Canvas canvas,
    Offset c,
    int sx,
    int sy,
    double arm,
    double r,
    Paint p,
  ) {
    final path = Path()
      ..moveTo(c.dx + sx * arm, c.dy)
      ..lineTo(c.dx + sx * r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + sy * r)
      ..lineTo(c.dx, c.dy + sy * arm);
    canvas.drawPath(path, p);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Composition grids are confined to the camera-visible band *between* the
    // top/bottom UI panels: translate to the band top, clip to its height, and
    // hand every draw method a band-sized canvas. Guide lines (and the Rule-of-
    // Thirds power points) therefore stop at the panel edges instead of sliding
    // underneath them. Face brackets (drawn afterwards) stay full-screen so they
    // keep tracking subjects anywhere on the preview, even over the panels.
    final double bandH = size.height - topInset - bottomInset;
    final bool banded = bandH > 1;
    final Size grid = banded ? Size(size.width, bandH) : size;

    canvas.save();
    if (banded) {
      canvas.translate(0, topInset);
      canvas.clipRect(Rect.fromLTWH(0, 0, grid.width, grid.height));
    }
    switch (mode) {
      case CompositionMode.none:
        break;
      case CompositionMode.horizonGrid:
        // Guide line + detected horizon are drawn after restore() (full-screen,
        // like the face boxes), so nothing to draw inside the banded clip.
        break;
      case CompositionMode.ruleOfThirds:
        _drawRuleOfThirds(canvas, grid);
        break;
      case CompositionMode.goldenSection:
        _drawGoldenSection(canvas, grid);
        break;
      case CompositionMode.goldenTriangles:
        _drawGoldenTriangles(canvas, grid);
        break;
      case CompositionMode.spiralSection:
        _drawSpiralSection(canvas, grid);
        break;
      case CompositionMode.fibonacciSpiral:
        _drawGoldenSpiral(canvas, grid);
        break;
      case CompositionMode.harmoniousTriangles:
        _drawHarmoniousTriangles(canvas, grid);
        break;
      case CompositionMode.cross:
        _drawCross(canvas, grid);
        break;
      case CompositionMode.focalMass:
        _drawFocalMass(canvas, grid);
        break;
      case CompositionMode.vArrangement:
        _drawVArrangement(canvas, grid);
        break;
      case CompositionMode.diagonal:
        _drawDiagonal(canvas, grid);
        break;
      case CompositionMode.radial:
        _drawRadial(canvas, grid);
        break;
      case CompositionMode.lArrangement:
        _drawLArrangement(canvas, grid);
        break;
      case CompositionMode.compoundCurve:
        _drawCompoundCurve(canvas, grid);
        break;
      case CompositionMode.pyramid:
        _drawPyramid(canvas, grid);
        break;
      case CompositionMode.circular:
        _drawCircular(canvas, grid);
        break;
      case CompositionMode.symmetry:
        _drawSymmetry(canvas, grid);
        break;
      case CompositionMode.aspectRatio:
        _drawAspectRatio(canvas, grid);
        break;
    }

    // ── Target points (glow when a subject lands on them) ──────────────────────
    // Rule of Thirds uses the 1/3 intersections; Phi Grid uses the golden-
    // section intersections at 1/φ² ≈ 0.382 and 1/φ ≈ 0.618; Fibonacci Spiral
    // uses a single point — the spiral's eye.
    final List<List<double>>? pts = switch (mode) {
      CompositionMode.ruleOfThirds => const [
        [1 / 3, 1 / 3],
        [2 / 3, 1 / 3],
        [1 / 3, 2 / 3],
        [2 / 3, 2 / 3],
      ],
      CompositionMode.goldenSection => const [
        [0.3819660113, 0.3819660113],
        [0.6180339887, 0.3819660113],
        [0.3819660113, 0.6180339887],
        [0.6180339887, 0.6180339887],
      ],
      CompositionMode.fibonacciSpiral => () {
        final eye = _goldenSpiralEyePx(grid, spiralTurns, _goldenSpiralFill);
        return [
          [eye.dx / grid.width, eye.dy / grid.height],
        ];
      }(),
      _ => null,
    };
    if (pts != null) {
      const gold = Color(0xFFE5C158);
      for (var i = 0; i < pts.length; i++) {
        final c = Offset(pts[i][0] * grid.width, pts[i][1] * grid.height);
        final g = (i < powerGlow.length ? powerGlow[i] : 0.0).clamp(0.0, 1.0);
        // Faint dot always; blooms into a soft glowing ring when aligned.
        canvas.drawCircle(
          c,
          2.0,
          Paint()..color = gold.withValues(alpha: 0.25 + 0.55 * g),
        );
        if (g > 0.01) {
          canvas.drawCircle(
            c,
            6.0 + 10.0 * g,
            Paint()
              ..color = gold.withValues(alpha: 0.45 * g)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4.0 + 6.0 * g),
          );
          canvas.drawCircle(
            c,
            5.0 + 4.0 * g,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = gold.withValues(alpha: 0.8 * g),
          );
        }
      }
    }
    canvas.restore();

    // ── Horizon Grid: a golden guide line marking the ideal horizon placement,
    // plus the live detected horizon that glows gold as it lands on the guide. ──
    if (mode == CompositionMode.horizonGrid) {
      const gold = Color(0xFFE5C158);
      final double bandSpan = size.height - topInset - bottomInset;
      final double guideY = topInset + bandSpan * _horizonGuideRatio;
      final hz = horizon?.value;
      // Alignment with the guide is computed once in the ticker (single source
      // of truth — also drives the message bubble + haptic). Labels live in the
      // shared top message bubble, not on the line.
      final double aligned = hz?.aligned ?? 0;

      // Guide line: dashed gold, always visible; blooms when aligned.
      if (aligned > 0.02) {
        canvas.drawLine(
          Offset(0, guideY),
          Offset(size.width, guideY),
          Paint()
            ..color = gold.withValues(alpha: 0.55 * aligned)
            ..strokeWidth = 4.0
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0),
        );
      }
      _drawDashedLine(
        canvas,
        Offset(0, guideY),
        Offset(size.width, guideY),
        Paint()
          ..color = gold.withValues(alpha: (0.42 + 0.5 * aligned).clamp(0.0, 1.0))
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.butt,
        dash: 9,
        gap: 7,
      );

      // Detected horizon line (fades with op). Clipped to the camera-visible
      // band so a tilted line never bleeds into the top/bottom panels.
      if (hz != null && hz.op > 0.01) {
        final double op = hz.op;
        final Offset c = Offset(hz.ax * size.width, hz.ay * size.height);
        final double L = size.width * 1.6; // extend well past both edges
        final Offset dir = Offset(math.cos(hz.angle), math.sin(hz.angle));
        final p1 = c - dir * L;
        final p2 = c + dir * L;
        // Level cue: gold intensifies as the line approaches horizontal.
        final level = (1 - (hz.angle.abs() / 0.20)).clamp(0.0, 1.0);
        canvas.save();
        canvas.clipRect(
          Rect.fromLTWH(0, topInset, size.width, bandSpan),
        );
        canvas.drawLine(
          p1,
          p2,
          Paint()
            ..color = gold.withValues(alpha: (0.25 + 0.35 * level) * op)
            ..strokeWidth = 3.5
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0),
        );
        canvas.drawLine(
          p1,
          p2,
          Paint()
            ..color = gold.withValues(alpha: 0.85 * op)
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round
            ..isAntiAlias = true,
        );
        canvas.restore();
      }
    }

    _paintFaceBoxes(canvas, size);

    // Selective glow pass — redraw only the lines that have edge support,
    // using a gold blur paint so they illuminate without affecting other lines.
    if (glowSegs.isNotEmpty) {
      final glowPaint = Paint()
        ..strokeWidth = _sw + 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.5);
      for (final seg in glowSegs) {
        if (seg.intensity <= 0) continue;
        glowPaint.color = const Color(
          0xFFE5C158,
        ).withValues(alpha: (0.65 * seg.intensity).clamp(0.0, 1.0));
        canvas.drawLine(
          Offset(seg.x1 * size.width, seg.y1 * size.height),
          Offset(seg.x2 * size.width, seg.y2 * size.height),
          glowPaint,
        );
      }
    }
  }

  /// Full-screen face/animal corner brackets (camera AF style). Drawn on its own
  /// full-screen layer so boxes track faces anywhere, even over the UI panels.
  void _paintFaceBoxes(Canvas canvas, Size size) {
    for (final b in faceBoxes) {
      if (b.opacity <= 0.01) continue;
      // Subtle scale-in: start 8% smaller and settle to full size on appear.
      final scale = 0.92 + 0.08 * b.appear;
      final w = b.w * size.width * scale;
      final h = b.h * size.height * scale;
      final cx = b.cx * size.width;
      final cy = b.cy * size.height;
      final rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);

      final a = b.opacity.clamp(0.0, 1.0);
      final align = b.alignGlow.clamp(0.0, 1.0);
      const gold = Color(0xFFE5C158); // composition-text gold (aligned)
      const grid = Color(0xFFFFFFFF); // grid-line white (not aligned)
      final arm = (math.min(rect.width, rect.height) * 0.26).clamp(8.0, 26.0);
      final r = math.min(8.0, arm * 0.6);

      // colorT: 0 = grid white (no alignment), 1 = full gold (point inside box).
      // align ramps 0 → 0.45 ("Almost") → 1.0 ("Perfect"), so reaching ~0.45
      // already gives full gold; the glow keeps intensifying toward Perfect.
      final colorT = (align / 0.45).clamp(0.0, 1.0);
      final Color lineColor = Color.lerp(grid, gold, colorT)!;

      // Blurred glow is the expensive part — only for boxes on a point (align>0),
      // light for "Almost", heavy for "Perfect". Other faces are cheap strokes.
      if (align > 0.02) {
        final glow = Paint()
          ..color = gold.withValues(alpha: (0.18 + 0.5 * align) * a)
          ..strokeWidth = 4.0 + 4.0 * align
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.5 + 4.0 * align);
        _corner(canvas, rect.topLeft, 1, 1, arm, r, glow);
        _corner(canvas, rect.topRight, -1, 1, arm, r, glow);
        _corner(canvas, rect.bottomRight, -1, -1, arm, r, glow);
        _corner(canvas, rect.bottomLeft, 1, -1, arm, r, glow);
      }

      // Thin grid-white when not aligned; thicker gold when on a point.
      final stroke = Paint()
        ..color = lineColor.withValues(alpha: (0.42 + 0.5 * colorT) * a)
        ..strokeWidth = 1.2 + 1.8 * align
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      _corner(canvas, rect.topLeft, 1, 1, arm, r, stroke);
      _corner(canvas, rect.topRight, -1, 1, arm, r, stroke);
      _corner(canvas, rect.bottomRight, -1, -1, arm, r, stroke);
      _corner(canvas, rect.bottomLeft, 1, -1, arm, r, stroke);
    }
  }

  /// Draws a dashed line from [a] to [b] (used by the Horizon Grid guide line).
  void _drawDashedLine(
    Canvas canvas,
    Offset a,
    Offset b,
    Paint paint, {
    double dash = 8,
    double gap = 6,
  }) {
    final double total = (b - a).distance;
    if (total <= 0) return;
    final Offset dir = (b - a) / total;
    double d = 0;
    while (d < total) {
      final double end = math.min(d + dash, total);
      canvas.drawLine(a + dir * d, a + dir * end, paint);
      d = end + gap;
    }
  }

  // ── Rule of Thirds ──────────────────────────────────────────────────────────
  // Two equally spaced verticals + two equally spaced horizontals → 9 equal cells.
  // StrokeCap.butt ensures lines stay strictly within the frame boundaries.
  void _drawRuleOfThirds(Canvas canvas, Size s) {
    final p = _gp();

    final double col1 = s.width / 3;
    final double col2 = s.width * 2 / 3;
    final double row1 = s.height / 3;
    final double row2 = s.height * 2 / 3;

    // Vertical lines — from top edge to bottom edge
    canvas.drawLine(Offset(col1, 0), Offset(col1, s.height), p);
    canvas.drawLine(Offset(col2, 0), Offset(col2, s.height), p);

    // Horizontal lines — from left edge to right edge
    canvas.drawLine(Offset(0, row1), Offset(s.width, row1), p);
    canvas.drawLine(Offset(0, row2), Offset(s.width, row2), p);
  }

  // ── Golden Section ──────────────────────────────────────────────────────────
  // Divides width and height by the golden ratio φ ≈ 1.618.
  // Each dimension is split at (1/φ) ≈ 0.618 from one edge
  // and at (1/φ²) ≈ 0.382 from the other, giving two lines per axis.
  void _drawGoldenSection(Canvas canvas, Size s) {
    final p = _gp();

    const double phi = 1.6180339887;
    // Smaller division: 1/φ² ≈ 0.382 from one edge
    // Larger division: 1/φ  ≈ 0.618 from the same edge (= 1 − 0.382)
    final double wSmall = s.width / (phi * phi); // ≈ 0.382 × W
    final double wLarge = s.width / phi; // ≈ 0.618 × W
    final double hSmall = s.height / (phi * phi);
    final double hLarge = s.height / phi;

    // Vertical lines — span full height, flush to top and bottom edges
    canvas.drawLine(Offset(wSmall, 0), Offset(wSmall, s.height), p);
    canvas.drawLine(Offset(wLarge, 0), Offset(wLarge, s.height), p);

    // Horizontal lines — span full width, flush to left and right edges
    canvas.drawLine(Offset(0, hSmall), Offset(s.width, hSmall), p);
    canvas.drawLine(Offset(0, hLarge), Offset(s.width, hLarge), p);
  }

  // ── Golden Triangles ────────────────────────────────────────────────────────
  // One main diagonal (TL→BR) plus a perpendicular dropped from each of the
  // two remaining corners (TR and BL) onto that diagonal.
  // Result: 3 unique lines, 4 non-overlapping triangles, all within the frame.
  void _drawGoldenTriangles(Canvas canvas, Size s) {
    final p = _gp();

    final double w = s.width;
    final double h = s.height;
    final double d2 = w * w + h * h; // |diagonal|²

    // 1. Main diagonal: top-left → bottom-right
    canvas.drawLine(Offset(0, 0), Offset(w, h), p);

    // 2. Perpendicular from top-right corner (w, 0) to main diagonal
    //    Foot: t = (w·w + 0·h) / d2
    final double t2 = (w * w) / d2;
    canvas.drawLine(Offset(w, 0), Offset(t2 * w, t2 * h), p);

    // 3. Perpendicular from bottom-left corner (0, h) to main diagonal
    //    Foot: t = (0·w + h·h) / d2
    final double t3 = (h * h) / d2;
    canvas.drawLine(Offset(0, h), Offset(t3 * w, t3 * h), p);
  }

  // ── Spiral Section ──────────────────────────────────────────────────────────
  // Outer frame border + 6 phi-ratio dividing lines spiraling inward from the
  // top-left corner. Each line spans only the current sub-rectangle so there
  // are no overlapping edges and no lines outside the frame.
  void _drawSpiralSection(Canvas canvas, Size s) {
    final p = _gp();

    const double phi = 1.6180339887;

    // Outer frame border — the first (largest) nested rectangle.
    canvas.drawRect(Rect.fromLTWH(0, 0, s.width, s.height), p);

    double x = 0, y = 0, w = s.width, h = s.height;

    // At each step, divide the current rectangle at the golden section (1/φ of
    // the relevant dimension), draw the dividing line, then draw the resulting
    // nested rectangle border. The cut direction rotates through all four sides
    // so the rectangles spiral clockwise from the top edge toward an interior
    // "eye" — the same convergence point as the Fibonacci spiral arc.
    //
    // Cut sequence:  bottom → left → top → right  (repeat)
    //   case 0: horizontal line at y + h/φ        → keep top   h/φ strip
    //   case 1: vertical   line at x + w − w/φ    → keep right w/φ strip
    //   case 2: horizontal line at y + h − h/φ    → keep bottom h/φ strip
    //   case 3: vertical   line at x + w/φ        → keep left  w/φ strip
    for (int i = 0; i < 8; i++) {
      if (w < 2 || h < 2) break;
      switch (i % 4) {
        case 0:
          final double keepH = h / phi;
          canvas.drawLine(Offset(x, y + keepH), Offset(x + w, y + keepH), p);
          h = keepH;
          break;
        case 1:
          final double keepW = w / phi;
          final double removeW = w - keepW; // = w / φ²
          canvas.drawLine(
            Offset(x + removeW, y),
            Offset(x + removeW, y + h),
            p,
          );
          x += removeW;
          w = keepW;
          break;
        case 2:
          final double keepH = h / phi;
          final double removeH = h - keepH; // = h / φ²
          canvas.drawLine(
            Offset(x, y + removeH),
            Offset(x + w, y + removeH),
            p,
          );
          y += removeH;
          h = keepH;
          break;
        case 3:
          final double keepW = w / phi;
          canvas.drawLine(Offset(x + keepW, y), Offset(x + keepW, y + h), p);
          w = keepW;
          break;
      }
      // Draw the nested rectangle produced by this iteration.
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), p);
    }
  }

  // ── Golden Spiral ───────────────────────────────────────────────────────────
  // Parametric logarithmic golden spiral: r = a·exp(b·θ), where
  // b = ln(φ)/(π/2) so the radius grows by φ every quarter-turn.
  // Eye at the golden-section intersection (upper-right region); outermost
  // arm aims toward the bottom-left corner, spiralling 1.5 full turns.
  // void _drawGoldenSpiral(Canvas canvas, Size s) {
  //   final p = Paint()
  //     ..color = _gold.withValues(alpha: 0.70)
  //     ..strokeWidth = _sw
  //     ..style = PaintingStyle.stroke
  //     ..strokeCap = StrokeCap.round
  //     ..isAntiAlias = true;

  //   const double phi = 1.6180339887;
  //   // Growth rate: radius multiplies by φ every π/2 radians
  //   final double b = math.log(phi) / (math.pi / 2);

  //   // Eye at golden-section intersection (upper-right area)
  //   final double cx = s.width / phi;          // ≈ 0.618 × W
  //   final double cy = s.height / (phi * phi); // ≈ 0.382 × H

  //   // Outermost arm aims toward the bottom-left corner of the frame
  //   final double thetaEnd   = math.atan2(s.height - cy, -cx);
  //   const double totalTheta = 3.0 * math.pi; // 1.5 full turns inward
  //   final double thetaStart = thetaEnd - totalTheta;

  //   // Scale so r = rMax at thetaEnd (arm reaches the farthest frame corner)
  //   double rMax = 0.0;
  //   for (final c in [
  //     Offset(0, 0), Offset(s.width, 0),
  //     Offset(0, s.height), Offset(s.width, s.height),
  //   ]) {
  //     final d = (c - Offset(cx, cy)).distance;
  //     if (d > rMax) rMax = d;
  //   }
  //   final double a = rMax * math.exp(-b * thetaEnd);

  //   final path = Path();
  //   const int steps = 400;
  //   for (int i = 0; i <= steps; i++) {
  //     final double theta = thetaStart + totalTheta * i / steps;
  //     final double r     = a * math.exp(b * theta);
  //     final double px    = cx + r * math.cos(theta);
  //     final double py    = cy + r * math.sin(theta);
  //     i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
  //   }
  //   canvas.drawPath(path, p);
  // }

  void _drawGoldenSpiral(Canvas canvas, Size s) {
    final p = _p;
    const double phi = 1.6180339887;

    // 90°-per-step rotation lets the user aim the spiral's eye at any corner.
    // Odd steps stand the spiral on its long edge, so we fit the golden rectangle
    // into a frame with width/height swapped, then rotate the whole drawing about
    // the band centre to drop it back into place (still fitting the band).
    final int turns = spiralTurns & 3;
    final bool swap = turns.isOdd;
    final double fw = swap ? s.height : s.width;
    final double fh = swap ? s.width : s.height;

    // Largest *landscape* golden rectangle (φ:1, wider than tall) that fits the
    // (possibly swapped) frame, centred — the classic golden-spiral framing.
    final double maxW = fw * _goldenSpiralFill;
    final double maxH = fh * _goldenSpiralFill;
    double w = maxW;
    double h = w / phi;
    if (h > maxH) {
      h = maxH;
      w = h * phi;
    }
    Rect rect = Rect.fromLTWH((fw - w) / 2, (fh - h) / 2, w, h);

    canvas.save();
    // Rotate the drawing frame about the band centre; the (fw × fh) frame is
    // centred there so the rotated rectangle lands back inside the band.
    canvas.translate(s.width / 2, s.height / 2);
    canvas.rotate(turns * (math.pi / 2));
    canvas.translate(-fw / 2, -fh / 2);

    // Outer golden-rectangle border (the largest nested square's frame).
    canvas.drawRect(rect, p);

    // Start by cutting the right square so the spiral winds inward toward the
    // left, the eye settling near the lower-left golden-section point.
    int dir = 0;
    final path = Path();
    bool isFirst = true;

    // Cut squares, drawing the golden-section dividing line for each (the lines
    // overlaid in the reference) plus a continuous quarter-arc through it. 12
    // iterations reach the sub-pixel "eye".
    for (int i = 0; i < 12; i++) {
      final double sqSize = math.min(rect.width, rect.height);
      Offset center;
      double startAngle;
      const double sweepAngle = math.pi / 2;

      if (dir == 0) {
        // Cut Right Square — divider is its left edge (vertical, full height).
        center = Offset(rect.right - sqSize, rect.top);
        startAngle = 0;
        canvas.drawLine(
          Offset(rect.right - sqSize, rect.top),
          Offset(rect.right - sqSize, rect.bottom),
          p,
        );
        rect = Rect.fromLTRB(
          rect.left,
          rect.top,
          rect.right - sqSize,
          rect.bottom,
        );
      } else if (dir == 1) {
        // Cut Bottom Square — divider is its top edge (horizontal, full width).
        center = Offset(rect.right, rect.bottom - sqSize);
        startAngle = math.pi / 2;
        canvas.drawLine(
          Offset(rect.left, rect.bottom - sqSize),
          Offset(rect.right, rect.bottom - sqSize),
          p,
        );
        rect = Rect.fromLTRB(
          rect.left,
          rect.top,
          rect.right,
          rect.bottom - sqSize,
        );
      } else if (dir == 2) {
        // Cut Left Square — divider is its right edge (vertical, full height).
        center = Offset(rect.left + sqSize, rect.bottom);
        startAngle = math.pi;
        canvas.drawLine(
          Offset(rect.left + sqSize, rect.top),
          Offset(rect.left + sqSize, rect.bottom),
          p,
        );
        rect = Rect.fromLTRB(
          rect.left + sqSize,
          rect.top,
          rect.right,
          rect.bottom,
        );
      } else {
        // Cut Top Square — divider is its bottom edge (horizontal, full width).
        center = Offset(rect.left, rect.top + sqSize);
        startAngle = -math.pi / 2;
        canvas.drawLine(
          Offset(rect.left, rect.top + sqSize),
          Offset(rect.right, rect.top + sqSize),
          p,
        );
        rect = Rect.fromLTRB(
          rect.left,
          rect.top + sqSize,
          rect.right,
          rect.bottom,
        );
      }

      final arcRect = Rect.fromCircle(center: center, radius: sqSize);
      path.arcTo(arcRect, startAngle, sweepAngle, isFirst);
      isFirst = false;
      dir = (dir + 1) % 4;
    }

    canvas.drawPath(path, p);
    canvas.restore();
  }

  // ── Harmonious Triangles ────────────────────────────────────────────────────
  // Both diagonals, each with its two perpendiculars from the opposite corners.
  // TL→BR set (Golden Triangles) + TR→BL set (its mirror) = 6 lines, 8 triangles.
  void _drawHarmoniousTriangles(Canvas canvas, Size s) {
    // Golden Triangles flipped horizontally: x → (w − x).
    // Original uses TL→BR diagonal; flipped uses TR→BL diagonal,
    // with perpendiculars from TL and BR to that diagonal.
    final p = _gp();

    final double w = s.width;
    final double h = s.height;
    final double d2 = w * w + h * h;

    // 1. Main diagonal: top-right → bottom-left  (mirror of TL→BR)
    canvas.drawLine(Offset(w, 0), Offset(0, h), p);

    // 2. Perpendicular from top-left corner (0, 0) to TR→BL diagonal.
    //    TR→BL direction vector: (−w, h).
    //    t = [(0−w)·(−w) + (0−0)·h] / d2 = w²/d2
    final double t2 = (w * w) / d2;
    canvas.drawLine(Offset(0, 0), Offset(w - t2 * w, t2 * h), p);

    // 3. Perpendicular from bottom-right corner (w, h) to TR→BL diagonal.
    //    t = [(w−w)·(−w) + (h−0)·h] / d2 = h²/d2
    final double t3 = (h * h) / d2;
    canvas.drawLine(Offset(w, h), Offset(w - t3 * w, t3 * h), p);
  }

  // ── Cross ───────────────────────────────────────────────────────────────────
  void _drawCross(Canvas canvas, Size s) {
    final p = _p;

    // Christian cross — centered horizontally, positioned in the upper portion
    // of the frame. The vertical arm is longer below the crossbar than above.
    final double cx = s.width * 0.50;
    final double cy = s.height * 0.38; // crossbar sits at upper-center

    // Vertical arm: short above the crossbar, long below — classic cross ratio.
    final double armUp = s.height * 0.10;
    final double armDown = s.height * 0.30;

    // Horizontal crossbar: symmetric, does not reach screen edges.
    final double armLeft = s.width * 0.18;
    final double armRight = s.width * 0.18;

    // Vertical line
    canvas.drawLine(Offset(cx, cy - armUp), Offset(cx, cy + armDown), p);
    // Horizontal crossbar
    canvas.drawLine(Offset(cx - armLeft, cy), Offset(cx + armRight, cy), p);
  }

  // ── Focal Mass ──────────────────────────────────────────────────────────────
  // Scattered dot cluster in the upper-center (like reference image)
  void _drawFocalMass(Canvas canvas, Size s) {
    // Landscape-oriented focal mass: wide horizontal spread, tight vertical.
    // Dense cluster of dots left-of-centre that thins and scatters rightward,
    // matching the reference composition diagram.
    final double cx = s.width * 0.42; // cluster sits left of centre
    final double cy = s.height * 0.50; // vertical centre

    // Wide horizontal, narrow vertical — the defining trait of this composition.
    const double scatterX = 120.0; // broad horizontal half-width
    const double scatterY = 32.0; // tight vertical half-height
    const int count = 220;

    final rng = math.Random(7);
    final dotPaint = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < count; i++) {
      final double u1 = rng.nextDouble().clamp(1e-9, 1.0);
      final double u2 = rng.nextDouble();
      final double n1 =
          math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
      final double n2 =
          math.sqrt(-2.0 * math.log(u1)) * math.sin(2 * math.pi * u2);

      final double dx = n1 * scatterX;
      final double dy = n2 * scatterY;

      // Anisotropic distance — core = 0, edge of scatter ellipse = 1.
      final double distNorm = math
          .sqrt(math.pow(dx / scatterX, 2) + math.pow(dy / scatterY, 2))
          .clamp(0.0, 1.0);

      // Steeper falloff so density drops sharply away from the core mass.
      final double coreInfluence = math.exp(-distNorm * distNorm * 5.5);

      final double radius = 0.8 + 1.4 * coreInfluence;
      final double alpha = 0.12 + 0.58 * coreInfluence;

      dotPaint.color = _gold.withValues(alpha: alpha);
      canvas.drawCircle(Offset(cx + dx, cy + dy), radius, dotPaint);
    }

    // Dense core cluster — extra tight dots at the focal centre.
    const double coreScatterX = 28.0;
    const double coreScatterY = 9.0;
    const int coreCount = 110;
    final rngCore = math.Random(31);
    for (int i = 0; i < coreCount; i++) {
      final double u1 = rngCore.nextDouble().clamp(1e-9, 1.0);
      final double u2 = rngCore.nextDouble();
      final double n1 =
          math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
      final double n2 =
          math.sqrt(-2.0 * math.log(u1)) * math.sin(2 * math.pi * u2);
      final double dx = n1 * coreScatterX;
      final double dy = n2 * coreScatterY;
      final double distNorm = math
          .sqrt(math.pow(dx / coreScatterX, 2) + math.pow(dy / coreScatterY, 2))
          .clamp(0.0, 1.0);
      final double influence = math.exp(-distNorm * distNorm * 5.0);
      final double radius = 0.6 + 2.0 * influence;
      final double alpha = 0.32 + 0.48 * influence;
      dotPaint.color = _gold.withValues(alpha: alpha);
      canvas.drawCircle(Offset(cx + dx, cy + dy), radius, dotPaint);
    }
  }

  // ── V Arrangement ───────────────────────────────────────────────────────────
  // V shape opening upward, vertex at bottom-center
  void _drawVArrangement(Canvas canvas, Size s) {
    final p = _p;

    // Vertex at lower-center; arms rise symmetrically to the upper corners
    // of a contained region — fully visible, no clipping at edges.
    final double vx = s.width * 0.50; // horizontal center
    final double vy = s.height * 0.78; // vertex near bottom

    // Arm endpoints — symmetric, inset from frame edges.
    final double topY = s.height * 0.12;
    final double topLeftX = s.width * 0.08;
    final double topRightX = s.width * 0.92;

    // Left arm: vertex → upper-left
    canvas.drawLine(Offset(vx, vy), Offset(topLeftX, topY), p);
    // Right arm: vertex → upper-right (mirror)
    canvas.drawLine(Offset(vx, vy), Offset(topRightX, topY), p);
  }

  // ── Diagonal ────────────────────────────────────────────────────────────────
  // Two strong diagonals plus two parallel helpers — like the reference
  void _drawDiagonal(Canvas canvas, Size s) {
    final p = _p;

    // Both lines share a single origin at the top-right corner.
    // They fan toward the bottom-left corner, ending ~2 cm apart
    // (~85 logical px each side of the BL corner — distance ≈ 120 px).
    final Offset origin = Offset(s.width, 0);

    // Line 1 — ends on the left edge, 85px above the bottom-left corner.
    final Offset end1 = Offset(0, s.height - 85);

    // Line 2 — ends on the bottom edge, 85px right of the bottom-left corner.
    final Offset end2 = Offset(85, s.height);

    canvas.drawLine(origin, end1, p);
    canvas.drawLine(origin, end2, p);
  }

  // ── Radial ──────────────────────────────────────────────────────────────────
  // Lines radiating from center like a star
  void _drawRadial(Canvas canvas, Size s) {
    final p = _p;
    final Offset center = Offset(s.width / 2, s.height / 2);

    // Fixed arm length: 40% of the shorter screen dimension so all 8 lines
    // are equal length, stay well clear of the edges, and never overlap.
    final double armLength = math.min(s.width, s.height) * 0.40;

    // 8 lines = 16 arms evenly spaced at 360°/8 = 45° apart.
    const int count = 8;
    for (int i = 0; i < count; i++) {
      final double angle = i * 2 * math.pi / count;
      final double cos = math.cos(angle);
      final double sin = math.sin(angle);
      canvas.drawLine(
        Offset(center.dx - cos * armLength, center.dy - sin * armLength),
        Offset(center.dx + cos * armLength, center.dy + sin * armLength),
        p,
      );
    }
  }

  // ── L Arrangement ───────────────────────────────────────────────────────────
  void _drawLArrangement(Canvas canvas, Size s) {
    final p = _p;
    // Flipped both vertically (y→h−y) and horizontally (x→w−x).
    // Vertical bar on the LEFT ~32%.
    final double vx = s.width * 0.32;
    canvas.drawLine(
      Offset(vx, s.height * 0.20),
      Offset(vx, s.height * 0.82),
      p,
    );
    // Horizontal bar at the TOP, extending to the RIGHT.
    canvas.drawLine(
      Offset(vx, s.height * 0.20),
      Offset(s.width * 0.80, s.height * 0.20),
      p,
    );
  }

  // ── Compound Curve ──────────────────────────────────────────────────────────
  // S-curve through center using two cubic bezier segments
  void _drawCompoundCurve(Canvas canvas, Size s) {
    final p = _p;
    final path = Path();

    // S-curve flowing top→bottom across the full frame height (portrait).
    // Start: top edge at horizontal center.
    // End:   bottom edge at horizontal center.
    // Two cubic segments share a smooth join at the frame center,
    // with control points that pull each half in opposite horizontal
    // directions to form a balanced vertical S.
    //
    //  Top half:    bows right (CP1 right-upper, CP2 right-lower of center)
    //  Bottom half: bows left  (CP1 left-upper,  CP2 left-lower  of center)

    final double cx = s.width * 0.50;
    final double cy = s.height * 0.50;
    final double bow = s.width * 0.28; // horizontal amplitude of each arc

    // Segment 1: top-edge mid → frame center
    path.moveTo(cx, 0);
    path.cubicTo(
      cx + bow,
      s.height * 0.20, // CP1 — bows right
      cx + bow,
      s.height * 0.40, // CP2 — stays right before center
      cx,
      cy, // end at frame center
    );

    // Segment 2: frame center → bottom-edge mid (mirrors segment 1)
    path.cubicTo(
      cx - bow,
      s.height * 0.60, // CP1 — bows left
      cx - bow,
      s.height * 0.80, // CP2 — stays left before bottom
      cx,
      s.height, // end at bottom-edge mid
    );

    canvas.drawPath(path, p);
  }

  // ── Pyramid ─────────────────────────────────────────────────────────────────
  void _drawPyramid(Canvas canvas, Size s) {
    final p = _p;
    final Offset apex = Offset(s.width * 0.5, s.height * 0.22);
    final Offset baseL = Offset(s.width * 0.12, s.height * 0.80);
    final Offset baseR = Offset(s.width * 0.88, s.height * 0.80);
    final path = Path()
      ..moveTo(apex.dx, apex.dy)
      ..lineTo(baseL.dx, baseL.dy)
      ..lineTo(baseR.dx, baseR.dy)
      ..close();
    canvas.drawPath(path, p);
  }

  // ── Circular ────────────────────────────────────────────────────────────────
  void _drawCircular(Canvas canvas, Size s) {
    final p = _p;
    final Offset center = Offset(s.width / 2, s.height / 2);
    final double radius = math.min(s.width, s.height) * 0.36;
    canvas.drawCircle(center, radius, p);
  }

  // ── Symmetry ──────────────────────────────────────────────────────────────
  // A single crisp vertical mirror axis down the centre (with a faint horizontal
  // for reference). Place the subject on the line so the two halves balance.
  void _drawSymmetry(Canvas canvas, Size s) {
    final p = _p;
    final double cx = s.width / 2;
    // Vertical mirror axis — full height, the primary guide.
    canvas.drawLine(Offset(cx, 0), Offset(cx, s.height), p);
    // Faint horizontal reference at the vertical centre.
    final faint = Paint()
      ..color = _gold.withValues(alpha: 0.18)
      ..strokeWidth = _sw
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    canvas.drawLine(
      Offset(0, s.height / 2),
      Offset(s.width, s.height / 2),
      faint,
    );
  }

  // ── Aspect Ratio ────────────────────────────────────────────────────────────
  // Crop framing guide for the selected ratio ([aspect] = W/H). Draws the largest
  // crop of that ratio centred in the band and dims everything outside it, so the
  // user can frame for 1:1 / 4:5 / 16:9 social or print output.
  void _drawAspectRatio(Canvas canvas, Size s) {
    final double r = aspect <= 0 ? 1.0 : aspect;
    double w, h;
    if (s.width / s.height > r) {
      h = s.height;
      w = h * r;
    } else {
      w = s.width;
      h = w / r;
    }
    final Rect crop = Rect.fromCenter(
      center: Offset(s.width / 2, s.height / 2),
      width: w,
      height: h,
    );

    // Dim outside the crop using an even-odd path (band rect with the crop as a
    // hole).
    final dim = Path()
      ..addRect(Rect.fromLTWH(0, 0, s.width, s.height))
      ..addRect(crop)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.38));

    // Crop border.
    canvas.drawRect(crop, _gp());
  }

  @override
  bool shouldRepaint(CompositionPainter old) =>
      old.mode != mode ||
      old.glowSegs != glowSegs ||
      old.faceBoxes != faceBoxes ||
      old.topInset != topInset ||
      old.bottomInset != bottomInset ||
      old.spiralTurns != spiralTurns ||
      old.aspect != aspect;
}
