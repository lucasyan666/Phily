import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
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
import 'package:phily/theme.dart';

part 'camera_overlays.dart';

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
  // The spiral is always drawn a quarter-turn off the stored value, so it sits
  // in the rotated (landscape) orientation by default; the rotate button cycles
  // from there. Used for both the painter and the alignment eye so they match.
  int get _spiralTurnsEffective => (_spiralTurns + 1) & 3;
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
  // Throttle the per-frame animal (cat/dog) Vision call; the box's grace window
  // keeps it steady between detections, so this is invisible but saves a native
  // request on roughly half the frames.
  int _lastAnimalMs = 0;
  List<Map<String, dynamic>> _lastAnimalDets = const [];

  // Experimental: highlight buildings in None mode via Apple Vision rectangle
  // detection (architectural rects — facades/windows). Throttled native call;
  // results are normalised preview-space rects the painter highlights.
  static const bool _buildingsEnabled = true;
  int _lastBuildingMs = 0;
  final List<Rect> _buildingBoxes = [];
  final ValueNotifier<int> _buildingRepaint = ValueNotifier(0);

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

  // Downsample factor applied to camera frames before face detection. 3 = run
  // detection at a third resolution — far cheaper for ML Kit and the rotation
  // pass, with face proportions preserved. Raise for more FPS, lower (→2) if
  // small/distant faces start getting missed.
  static const int _detScale = 3;

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
    _accelSub =
        accelerometerEventStream(
          samplingPeriod: SensorInterval.gameInterval,
        ).listen((e) {
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
            setState(
              () => _deviceTurns = turns!,
            ); // rebuild so UI controls rotate
          }

          // Drive the gravity horizon while Horizon Grid is active.
          if (_compositionMode == CompositionMode.horizonGrid) {
            _updateHorizonFromMotion();
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
    _buildingRepaint.dispose();
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

  /// On-screen exposure drag — deliberately gentle: ~2.5 screen-heights of
  /// travel covers the whole EV range, so one big swipe nudges only about a
  /// third of the bar. [dyUp] is the upward drag in px (positive = brighter).
  void _adjustExposureScreen(double dyUp) {
    final double h = MediaQuery.of(context).size.height;
    _adjustExposure(dyUp, h * 2.5);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseZoom = _currentZoom;
    _swipeStartX = _swipeLastX = details.focalPoint.dx;
    _swipeStartY = _swipeLastY = details.focalPoint.dy;
    _swipeMaxPointers = details.pointerCount;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails details) async {
    _swipeMaxPointers = math.max(_swipeMaxPointers, details.pointerCount);
    final double prevX = _swipeLastX;
    final double prevY = _swipeLastY;
    _swipeLastX = details.focalPoint.dx;
    _swipeLastY = details.focalPoint.dy;
    if (_controller == null || !_controller!.value.isInitialized) return;

    // Two fingers → pinch zoom (down to 0.5×; _setCameraZoom clamps the lens).
    if (details.pointerCount > 1) {
      final double newZoom = (_baseZoom * details.scale).clamp(0.5, _maxZoom);
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
      // Horizon Grid doesn't touch camera frames at all — its line comes from
      // the gravity sensor (_updateHorizonFromMotion). The other detection modes
      // share the face/animal path.
      switch (_compositionMode) {
        case CompositionMode.none:
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

    // ── Buildings (None mode only) via Apple Vision rectangle detection.
    // Throttled ~5 Hz; highlighted directly (separate from the tracking boxes),
    // and cleared when leaving None so they don't linger under a grid.
    if (_buildingsEnabled && _compositionMode == CompositionMode.none) {
      if (nowMs - _lastBuildingMs > 200) {
        _lastBuildingMs = nowMs;
        try {
          final raw = await _cameraChannel.invokeMethod<List>(
            'detectBuildings',
            {'bgra': winBytes, 'width': winOw, 'height': winOh},
          );
          if (!mounted) return;
          final tmp = <Map<String, dynamic>>[];
          _addVisionDets(raw, tmp, qt, 'building');
          _buildingBoxes
            ..clear()
            ..addAll(
              tmp
                  .map(
                    (d) => Rect.fromLTWH(
                      d['x'] as double,
                      d['y'] as double,
                      d['w'] as double,
                      d['h'] as double,
                    ),
                  )
                  // Keep only large rectangles — drop the small windows / keyboard
                  // keys / signage the rectangle detector also finds.
                  .where((r) => r.shortestSide >= 0.22),
            );
          _buildingRepaint.value++;
        } catch (_) {}
      }
    } else if (_buildingBoxes.isNotEmpty) {
      _buildingBoxes.clear();
      _buildingRepaint.value++;
    }

    _updateFaceTargets(dets); // ticker animates the displayed boxes
  }

  /// Compute the horizon line target from the device's gravity vector (Horizon
  /// Grid mode). The angle is the phone's roll (the true horizon counter-rotates
  /// to stay level); the on-screen height comes from the camera's pitch +
  /// vertical FOV. Image-independent → works in any light, costs nothing. The
  /// 60fps ticker eases the displayed line toward these targets.
  void _updateHorizonFromMotion() {
    final double gx = _gravX, gy = _gravY, gz = _gravZ;

    // Roll: phone tilt around the optical axis. Gravity (as measured, points
    // opposite real gravity) is ≈(0, +g, 0) when upright portrait.
    final double roll = math.atan2(gx, gy);
    // Pitch: camera elevation above the true horizon (+ = aimed up at sky).
    final double pitch = math.atan2(gz, math.sqrt(gx * gx + gy * gy));

    // On-screen line angle — the horizon counter-rotates against the phone roll
    // so it stays aligned with the real world (a true level). Small deadzone so a
    // near-level hold reads dead-flat.
    double ang = roll;
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

  /// Downsample (by [scale]) + physically rotate ([qt] quarter-turns CW) a BGRA
  /// buffer so subjects are upright. Returns tightly-packed bytes plus the output
  /// dimensions. Copies a whole BGRA pixel as one 32-bit word (≈4× fewer indexed
  /// ops than per-byte, and no per-byte bounds checks) — this loop runs on the UI
  /// isolate every frame, so its speed directly affects preview smoothness.
  (Uint8List, int, int) _rotatedBytes(
    Uint8List src,
    int w,
    int h,
    int srcBpr,
    int qt, {
    int scale = _detScale,
  }) {
    final int s = scale;
    final int sw = w ~/ s, sh = h ~/ s;
    final int outW = (qt == 1 || qt == 3) ? sh : sw;
    final int outH = (qt == 1 || qt == 3) ? sw : sh;
    final out32 = Uint32List(outW * outH);

    // Fast path: view source + destination as 32-bit pixels. Requires the source
    // to be word-aligned (camera BGRA rows always are). Falls back to bytes if not.
    if (src.offsetInBytes % 4 == 0 && srcBpr % 4 == 0) {
      final src32 = src.buffer.asUint32List(
        src.offsetInBytes,
        src.lengthInBytes ~/ 4,
      );
      final int srcStride = srcBpr ~/ 4;
      for (var dy = 0; dy < outH; dy++) {
        int di = dy * outW;
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
          out32[di++] = src32[sy * srcStride + sx];
        }
      }
      return (out32.buffer.asUint8List(), outW, outH);
    }

    // Byte fallback (unaligned source).
    final bytes = out32.buffer.asUint8List();
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
  // Horizon message-bubble level: 0 = guide only, 1 = detected (not level),
  // 2 = level on the guide. Drives the shared top hint bubble + the haptic.
  final ValueNotifier<int> _hzLevel = ValueNotifier(0);
  int _hzPrevLevel = 0;
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
          _spiralTurnsEffective,
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
          // Slide up like a sheet. Opaque so the live camera isn't rendered
          // behind the whole gallery (that was tanking the frame rate).
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
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: CompositionPainter(
                      _compositionMode,
                      glowSegs: _glowSegMap.values.toList(),
                      faceBoxes: _faceBoxes,
                      powerGlow: _powerGlow,
                      topInset: _topInset,
                      bottomInset: _bottomInset,
                      spiralTurns: _spiralTurnsEffective,
                      aspect: _aspectRatios[_aspectIndex].ratio,
                      horizon: _horizon,
                      buildingBoxes: _buildingBoxes,
                      repaint: Listenable.merge([
                        _faceAnim,
                        _horizon,
                        _buildingRepaint,
                      ]),
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
                        return GestureDetector(
                          // Tap a mode to jump to it (in addition to swiping).
                          // opaque so the whole page slot is tappable, not just
                          // the label glyph.
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _goToCompositionIndex(index),
                          child: Center(
                            child: Opacity(
                              opacity: opacity.clamp(0.3, 1.0),
                              child: _buildCompositionButton(
                                _compositionModes[index].label,
                                isSelected: index == _currentCompositionIndex,
                              ),
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
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    child: loading
                        ? const BrandedLoader(key: ValueKey('loader'))
                        : const SizedBox.shrink(key: ValueKey('ready')),
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
  Widget _buildTipBubble() {
    final tip = _compositionTip;
    final bool visible = _showTip && tip != null && !_isRecording;
    const gold = kGold;
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
    const gold = kGold;
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
            color: kGold,
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
    const gold = kGold;
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
    const gold = kGold;
    final range = _maxExposure - _minExposure;
    final frac = range > 0
        ? ((_exposureOffset - _minExposure) / range).clamp(0.0, 1.0)
        : 0.5;
    const knob = 24.0;
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
                  BoxShadow(color: gold.withValues(alpha: 0.4), blurRadius: 8),
                ],
              ),
              child: const Icon(Icons.wb_sunny_rounded, color: gold, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopSettingsPanel() {
    const Color gold = kGold;
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
                            ? kGold
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
    const Color gold = kGold;
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
                      color: kGold,
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
            color: kGold,
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
