import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gal/gal.dart';
import 'package:photo_manager/photo_manager.dart';
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

  // Camera settings
  FlashMode _flashMode = FlashMode.off;
  ResolutionPreset _resolution = ResolutionPreset.veryHigh; // 24MP
  String _imageFormat = 'HEIF'; // HEIF or RAW
  CompositionMode _compositionMode = CompositionMode.none;
  static const List<CompositionMode> _compositionModes = CompositionMode.values;
  late PageController _compositionPageController;
  int _currentCompositionIndex = 0;

  // Tap-to-focus
  Offset? _focusPoint;
  AnimationController? _focusRingController;
  late Animation<double> _focusRingScale;
  late Animation<double> _focusRingOpacity;

  // Zoom
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
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

  // Animation for bounce effect
  AnimationController? _bounceController;
  Animation<double>? _bounceAnimation;
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
  // Detected objects (faces/animals/contours) returned from native Vision probes.
  // Each entry: {x,y,w,h,label,confidence,nearIntersect}
  List<Map<String, dynamic>> _detections = [];
  bool _isProcessingFrame = false;
  DateTime _lastFrameTime = DateTime.fromMillisecondsSinceEpoch(0);

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

  // Physical device orientation (the UI is portrait-locked, so we read the
  // accelerometer directly). Quarter-turns clockwise from portrait: 0/1/2/3.
  // Drives the ML Kit rotation + box back-mapping so detection works sideways.
  int _deviceTurns = 0;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  final picker = ImagePicker();

  static const MethodChannel _cameraChannel  = MethodChannel('phily/camera');
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
        turns = e.x > 0 ? 3 : 1;           // landscape (two directions)
      } else if (ay > ax + margin) {
        turns = e.y > 0 ? 0 : 2;           // portrait up / upside-down
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
    // Pre-warm the camera after short delay
    Future.delayed(const Duration(seconds: 1), () {
      _warmUpCamera();
    });

    // Focus ring animation: quick scale-in pulse then fade out
    _focusRingController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    );
    // Scale: starts at 1.4 (large), quickly settles to 1.0
    _focusRingScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 1.4,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.linear)),
        weight: 30,
      ),
    ]).animate(_focusRingController!);
    // Opacity: fully visible, then fades out in the last 40%
    _focusRingOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 60),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 40,
      ),
    ]).animate(_focusRingController!);
    _focusRingController!.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _focusPoint = null);
      }
    });

    // Initialize bounce animation
    _bounceController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _bounceAnimation = CurvedAnimation(
      parent: _bounceController!,
      curve: Curves.easeOutCubic,
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
  Future<void> _loadLatestThumbnail() async {
    try {
      debugPrint('Starting thumbnail load...');

      // Request permissions
      final PermissionState ps = await PhotoManager.requestPermissionExtend();

      debugPrint(
        'Permission state: $ps, isAuth: ${ps.isAuth}, hasAccess: ${ps.hasAccess}',
      );

      if (!ps.isAuth && !ps.hasAccess) {
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
    _accelSub?.cancel();
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

  Future<void> _onTapToFocus(
    TapUpDetails details,
    BoxConstraints constraints,
  ) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final Offset tapPos = details.localPosition;
    final double x = (tapPos.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final double y = (tapPos.dy / constraints.maxHeight).clamp(0.0, 1.0);
    try {
      await _controller!.setFocusPoint(Offset(x, y));
      await _controller!.setExposurePoint(Offset(x, y));
    } catch (_) {}
    setState(() => _focusPoint = tapPos);
    _focusRingController!.forward(from: 0);
  }

  void _onScaleStart(ScaleStartDetails _) {
    _baseZoom = _currentZoom;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails details) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    // Allow pinching down to 0.5× — _setCameraZoom handles the lens boundary.
    final double newZoom = (_baseZoom * details.scale).clamp(0.5, _maxZoom);
    if ((newZoom - _currentZoom).abs() < 0.01) return;
    await _setCameraZoom(newZoom);
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

  Future<void> _warmUpCamera() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      // Pre-warm camera by accessing its properties
      _controller!.value;
      debugPrint('Camera warmed up');
    } catch (e) {
      debugPrint('Error warming up camera: $e');
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
      switch (_compositionMode) {
        case CompositionMode.ruleOfThirds:
          await _analyzeRuleOfThirds(image);
          break;
        case CompositionMode.none:
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

    // Fast path: use the cached rotation for this orientation (one detection).
    List<Face> faces = const [];
    int qt = _qtCache[turns] ?? 0;
    if (_qtCache.containsKey(turns)) {
      faces = await _faceDetector.processImage(
          _bgraInputImage(plane.bytes, w, h, plane.bytesPerRow, qt));
      if (!mounted) return;
    }

    // Re-probe when uncached, or when the cached rotation stops finding faces
    // (handles a transient wrong rotation getting cached during a turn). Pick
    // the rotation with the MOST faces so a single false positive can't win.
    if (faces.isEmpty) {
      for (final cand in const [0, 1, 3, 2]) {
        final found = await _faceDetector.processImage(
            _bgraInputImage(plane.bytes, w, h, plane.bytesPerRow, cand));
        if (!mounted) return;
        if (found.length > faces.length) {
          faces = found;
          qt = cand;
        }
      }
      if (faces.isNotEmpty) _qtCache[turns] = qt; // cache only a real winner
    }

    // Map ML Kit boxes (in the rotated-upright image space) back to the original
    // portrait buffer space via the inverse of the physical rotation we applied.
    final double bw = w.toDouble();
    final double bh = h.toDouble();
    final dets = <Map<String, dynamic>>[];
    for (final f in faces) {
      final r = f.boundingBox;
      final c1 = _invRot(r.left, r.top, qt * 90, bw, bh);
      final c2 = _invRot(r.right, r.bottom, qt * 90, bw, bh);
      final nx = math.min(c1.$1, c2.$1) / bw;
      final ny = math.min(c1.$2, c2.$2) / bh;
      final nw = (c1.$1 - c2.$1).abs() / bw;
      final nh = (c1.$2 - c2.$2).abs() / bh;
      final cx = (nx + nw / 2 - 0.5) * _previewStretchX + 0.5;
      final sw = nw * _previewStretchX;
      dets.add({
        'x': cx - sw / 2, 'y': ny, 'w': sw, 'h': nh,
        'label': 'face', 'confidence': 1.0,
      });
    }

    _detections = _smoothDetections(dets);
    if (mounted) setState(() {});
  }

  /// Build an ML Kit InputImage from a BGRA buffer, physically rotated by [qt]
  /// quarter-turns clockwise (0/1/2/3) so faces are upright. Output is tightly
  /// packed (bytesPerRow = width*4) with rotation metadata 0.
  InputImage _bgraInputImage(
    Uint8List src, int w, int h, int srcBpr, int qt,
  ) {
    if (qt == 0) {
      // No rotation — pass the buffer straight through (portrait fast path).
      return InputImage.fromBytes(
        bytes: src,
        metadata: InputImageMetadata(
          size: Size(w.toDouble(), h.toDouble()),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.bgra8888,
          bytesPerRow: srcBpr,
        ),
      );
    }

    Uint8List bytes;
    int outW, outH;
    if (qt == 2) {
      outW = w; outH = h;
      bytes = Uint8List(w * h * 4);
      for (var dy = 0; dy < h; dy++) {
        for (var dx = 0; dx < w; dx++) {
          final si = (h - 1 - dy) * srcBpr + (w - 1 - dx) * 4;
          final di = (dy * w + dx) * 4;
          bytes[di] = src[si]; bytes[di+1] = src[si+1];
          bytes[di+2] = src[si+2]; bytes[di+3] = src[si+3];
        }
      }
    } else {
      // qt == 1 (90° CW) or qt == 3 (270° CW): dimensions swap.
      outW = h; outH = w;
      bytes = Uint8List(w * h * 4);
      for (var dy = 0; dy < outH; dy++) {
        for (var dx = 0; dx < outW; dx++) {
          final int sx, sy;
          if (qt == 1) { sx = dy; sy = h - 1 - dx; }
          else         { sx = w - 1 - dy; sy = dx; } // qt == 3
          final si = sy * srcBpr + sx * 4;
          final di = (dy * outW + dx) * 4;
          bytes[di] = src[si]; bytes[di+1] = src[si+1];
          bytes[di+2] = src[si+2]; bytes[di+3] = src[si+3];
        }
      }
    }
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

  /// Map a point from the rotated-upright image space back to original portrait
  /// buffer space, for physical rotation [rot] degrees and buffer dims [bw]×[bh].
  (double, double) _invRot(double px, double py, int rot, double bw, double bh) {
    switch (rot) {
      case 90:  return (py, bh - px);
      case 180: return (bw - px, bh - py);
      case 270: return (bw - py, px);
      default:  return (px, py); // 0
    }
  }

  // Must match the horizontal stretch applied to the preview in _buildPreview
  // (Matrix4.diagonal3Values(1.17, 1.0, 1.0)) so detection boxes line up with
  // faces across the full width, not just the centre.
  static const double _previewStretchX = 1.17;


  // Per-face tracking state for velocity-based lag compensation.
  final List<_Track> _tracks = [];

  // How many frame-deltas to extrapolate forward to cancel detection latency.
  // ML Kit is fast (low latency), so this is modest. Higher = boxes lead more
  // (counters trailing on fast pans but can overshoot). Tune via hot reload.
  static const double _predictFrames = 1.0;
  // Velocity smoothing — reduces noise in the extrapolation.
  static const double _velEma = 0.45;
  // Cap on predicted shift (fraction of screen) so it never wildly overshoots.
  static const double _maxPredict = 0.18;

  /// Matches each detection to a tracked face, estimates its screen velocity,
  /// and extrapolates the box forward to compensate for pipeline latency — so
  /// the box stays locked to the face while the camera pans instead of trailing.
  List<Map<String, dynamic>> _smoothDetections(List<Map<String, dynamic>> fresh) {
    const double matchRadius = 0.20;
    final used = List<bool>.filled(_tracks.length, false);
    final out = <Map<String, dynamic>>[];
    final survivors = <_Track>[];

    for (final d in fresh) {
      final w = d['w'] as double, h = d['h'] as double;
      final cx = (d['x'] as double) + w / 2;
      final cy = (d['y'] as double) + h / 2;

      int best = -1;
      double bestDist = matchRadius;
      for (var i = 0; i < _tracks.length; i++) {
        if (used[i]) continue;
        final t = _tracks[i];
        final dist = math.sqrt((cx - t.cx) * (cx - t.cx) + (cy - t.cy) * (cy - t.cy));
        if (dist < bestDist) { bestDist = dist; best = i; }
      }

      late _Track t;
      if (best >= 0) {
        used[best] = true;
        t = _tracks[best];
        // Instantaneous per-frame velocity, EMA-smoothed to reduce noise.
        t.vx = t.vx * (1 - _velEma) + (cx - t.cx) * _velEma;
        t.vy = t.vy * (1 - _velEma) + (cy - t.cy) * _velEma;
        t.cx = cx; t.cy = cy;
      } else {
        t = _Track(cx, cy); // new face — no velocity yet
      }
      survivors.add(t);

      // Extrapolate forward to where the face should be *now* (cancels lag).
      final px = (t.vx * _predictFrames).clamp(-_maxPredict, _maxPredict);
      final py = (t.vy * _predictFrames).clamp(-_maxPredict, _maxPredict);
      final pcx = cx + px, pcy = cy + py;

      out.add({
        'x': (pcx - w / 2).clamp(0.0, 1.0),
        'y': (pcy - h / 2).clamp(0.0, 1.0),
        'w': w,
        'h': h,
        'label': d['label'],
        'confidence': d['confidence'],
      });
    }

    _tracks
      ..clear()
      ..addAll(survivors);
    return out;
  }

  // Printed once so we can verify frame orientation & format without spam.
  bool _frameDiagPrinted = false;

  Future<void> _analyzeRuleOfThirds(CameraImage image) async {
    final plane = image.planes[0];
    final bpp   = plane.bytesPerPixel ?? 1;

    if (!_frameDiagPrinted) {
      _frameDiagPrinted = true;
      debugPrint('[RoT] frame: ${image.width}x${image.height}  bpp=$bpp  '
          'bytesPerRow=${plane.bytesPerRow}  '
          'isLandscape=${image.width > image.height}');
    }

    // iOS streams BGRA8888 (bpp=4). Android streams YUV420 Y-plane (bpp=1).
    const dstW = 256;
    final dstH = (dstW * image.height ~/ image.width).clamp(1, 512);
    final bytes = bpp == 4
        ? _bgraToGrayscale(plane.bytes, image.width, image.height, plane.bytesPerRow, dstW, dstH)
        : _downsampleY(plane.bytes, image.width, image.height, plane.bytesPerRow, dstW, dstH);

    final raw = await _cameraChannel.invokeMethod<Map>(
      'analyzeRuleOfThirds',
      {'yPlane': bytes, 'width': dstW, 'height': dstH},
    );
    if (!mounted || raw == null) return;

    final aligned = raw['aligned'] as bool? ?? false;
    final haptic  = raw['haptic']  as bool? ?? false;
    final score   = (raw['score']  as num?)?.toDouble() ?? 0.0;
    final segs    = raw['edgeSegments'] as List? ?? const [];
    // Coords arrive already in upright/portrait space — Vision rotates internally
    // via the orientation hint passed to VNImageRequestHandler. No rotation here.

    // Update glow using stable index-based keys ('rot_0', 'rot_1', …) so entries
    // are mutated in place rather than deleted and re-created each frame.
    // This eliminates the per-frame clear → re-add flicker.
    final segCount = segs.length;
    for (var i = 0; i < segCount; i++) {
      final seg = segs[i];
      if (seg is! Map) continue;
      final x1 = (seg['x1'] as num).toDouble();
      final y1 = (seg['y1'] as num).toDouble();
      final x2 = (seg['x2'] as num).toDouble();
      final y2 = (seg['y2'] as num).toDouble();
      final key = 'rot_$i';
      final entry = _glowSegMap[key];
      if (entry != null) {
        entry.x1 = x1; entry.y1 = y1; entry.x2 = x2; entry.y2 = y2;
        entry.intensity = math.min(1.0, entry.intensity + 0.3);
      } else {
        _glowSegMap[key] = _GlowSeg(x1, y1, x2, y2, score.clamp(0.15, 1.0));
      }
    }

    // Fade out indices beyond what was returned this frame, and all when not aligned.
    final maxKey = aligned ? segCount : 0;
    _glowSegMap.removeWhere((k, v) {
      if (!k.startsWith('rot_')) return false;
      final idx = int.tryParse(k.substring(4)) ?? -1;
      if (idx >= maxKey) {
        v.intensity -= 0.2;
        return v.intensity <= 0;
      }
      return false;
    });

    if (haptic) await _haptic('alignmentPing', intensity: score);
    // Parse object detections (if the native analyzer returned any).
    final List<Map<String, dynamic>> dets = [];
    final rawDets = raw['detections'] as List? ?? raw['faces'] as List? ?? raw['animalBoxes'] as List?;
    if (rawDets != null) {
      for (final d in rawDets) {
        if (d is! Map) continue;
        final double x = (d['x'] as num?)?.toDouble() ?? (d['left'] as num?)?.toDouble() ?? 0.0;
        final double y = (d['y'] as num?)?.toDouble() ?? (d['top'] as num?)?.toDouble() ?? 0.0;
        final double w = (d['w'] as num?)?.toDouble() ?? (d['width'] as num?)?.toDouble() ?? 0.0;
        final double h = (d['h'] as num?)?.toDouble() ?? (d['height'] as num?)?.toDouble() ?? 0.0;
        final String label = (d['label'] ?? d['type'] ?? 'obj').toString();
        final double conf = (d['confidence'] as num?)?.toDouble() ?? 1.0;
        dets.add({'x': x, 'y': y, 'w': w, 'h': h, 'label': label, 'confidence': conf});
      }
    }

    // Mark detections near rule-of-thirds intersections when active.
    if (_compositionMode == CompositionMode.ruleOfThirds && dets.isNotEmpty) {
      final List<List<double>> ints = [
        [1.0 / 3.0, 1.0 / 3.0],
        [2.0 / 3.0, 1.0 / 3.0],
        [1.0 / 3.0, 2.0 / 3.0],
        [2.0 / 3.0, 2.0 / 3.0],
      ];
      for (final m in dets) {
        final cx = (m['x'] as double) + (m['w'] as double) / 2.0;
        final cy = (m['y'] as double) + (m['h'] as double) / 2.0;
        double best = double.infinity;
        for (final ip in ints) {
          final dx = cx - ip[0];
          final dy = cy - ip[1];
          final dist = math.sqrt(dx * dx + dy * dy);
          if (dist < best) best = dist;
        }
        // Threshold tuned for 256→screen scale; ~0.12 is a reasonable proximity.
        final bool near = best < 0.12;
        m['near'] = near;
        if (near && (m['confidence'] as double) > 0.4) {
          // optional haptic for prominent object near intersection
          try {
            _haptic('objectPing', intensity: (m['confidence'] as double).clamp(0.3, 1.0));
          } catch (_) {}
        }
      }
    }

    // Update detections used by the overlay painter.
    _detections = dets;

    if (mounted) setState(() {});
  }

  /// Convert a BGRA8888 camera frame to a downsampled grayscale Uint8List.
  /// On iOS, CameraImage planes[0] is BGRA (4 bytes/pixel): B, G, R, A.
  Uint8List _bgraToGrayscale(
    Uint8List src, int srcW, int srcH, int bytesPerRow, int dstW, int dstH,
  ) {
    final out = Uint8List(dstW * dstH);
    for (var y = 0; y < dstH; y++) {
      final srcY = (y * srcH ~/ dstH).clamp(0, srcH - 1);
      final rowOff = srcY * bytesPerRow;
      for (var x = 0; x < dstW; x++) {
        final srcX = (x * srcW ~/ dstW).clamp(0, srcW - 1);
        final off = rowOff + srcX * 4;
        final b = src[off], g = src[off + 1], r = src[off + 2];
        // BT.601 luminance: Y = 0.299R + 0.587G + 0.114B (integer-approximate)
        out[y * dstW + x] = ((77 * r + 150 * g + 29 * b) >> 8).clamp(0, 255);
      }
    }
    return out;
  }

  /// Downsample a single-channel (Y-plane) buffer — used for Android YUV420.
  Uint8List _downsampleY(
    Uint8List src, int srcW, int srcH, int stride, int dstW, int dstH,
  ) {
    final out = Uint8List(dstW * dstH);
    for (var y = 0; y < dstH; y++) {
      final srcY = (y * srcH ~/ dstH).clamp(0, srcH - 1);
      for (var x = 0; x < dstW; x++) {
        final srcX = (x * srcW ~/ dstW).clamp(0, srcW - 1);
        out[y * dstW + x] = src[srcY * stride + srcX];
      }
    }
    return out;
  }


  Future<void> _selectFromGallery() async {
    try {
      // Refresh thumbnail when tapping gallery button
      await _loadLatestThumbnail();
      // Also open gallery picker
      await picker.pickMedia();
    } catch (e) {
      debugPrint('Error picking from gallery: $e');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Live camera preview with tap-to-focus and pinch-to-zoom
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                onTapUp: (d) => _onTapToFocus(d, constraints),
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                child: _buildPreview(),
              ),
            ),
          ),

          // Focus ring — cinema corner-bracket with AF/AE lock label
          if (_focusPoint != null)
            AnimatedBuilder(
              animation: _focusRingController!,
              builder: (context, _) {
                const double size = 72.0;
                const Color gold = Color(0xFFE5C158);
                return Positioned(
                  left: _focusPoint!.dx - size / 2,
                  top: _focusPoint!.dy - size / 2 - 18,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: _focusRingOpacity.value,
                      child: Transform.scale(
                        scale: _focusRingScale.value,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: size,
                              height: size,
                              child: CustomPaint(
                                painter: _FocusBracketPainter(gold: gold),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              'AF · AE LOCK',
                              style: TextStyle(
                                color: gold,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w300,
                                letterSpacing: 2.0,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'φ  1.618',
                              style: TextStyle(
                                color: gold.withValues(alpha: 0.55),
                                fontSize: 7.5,
                                fontWeight: FontWeight.w300,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

          // Composition guide overlay — grid lines + detection boxes.
          // In None mode we still draw detection boxes for testing, so this is
          // always present. Detection bbox coords are full-frame normalised [0,1],
          // so the overlay must fill the whole screen (no insets).
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: CompositionPainter(
                  _compositionMode,
                  glowSegs: _glowSegMap.values.toList(),
                  detections: _detections,
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
                  if (MediaQuery.of(context).orientation == Orientation.portrait) ...[
                    const SizedBox(height: 6),
                    if (_isInitialized) _buildZoomMeter(),
                    const SizedBox(height: 18),
                  ] else
                    const SizedBox(height: 10),
                  // Camera controls row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Gallery button (bottom left)
                      GestureDetector(
                        onTap: _isRecording ? null : _selectFromGallery,
                        child: Container(
                          width: 48,
                          height: 48,
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
                              : _rotated(Icon(
                                  Icons.photo_library_outlined,
                                  color: Colors.white.withValues(alpha: 0.55),
                                  size: 22,
                                )),
                        ),
                      ),

                      // Capture button (center) - tap for photo, hold for video
                      _buildGlassCaptureButton(),

                      // Empty space for symmetry
                      const SizedBox(width: 50),
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
                    final m = e.inMinutes.remainder(60).toString().padLeft(2, '0');
                    final s = e.inSeconds.remainder(60).toString().padLeft(2, '0');
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 7,
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
                                  color: const Color(0xFFFF3B30).withValues(
                                    alpha: 0.65 * pulse,
                                  ),
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

          // Bounce animation from capture button to gallery
          if (_showBounceAnimation && _animatingMedia != null)
            AnimatedBuilder(
              animation: _bounceAnimation!,
              builder: (context, child) {
                final screenWidth = MediaQuery.of(context).size.width;

                // Start position (capture button center bottom)
                final startLeft =
                    (screenWidth / 2) - 35; // Center - half of button size

                // End position (gallery button left bottom)
                const endBottom = 40.0;
                const endLeft = 20.0;

                // Interpolate positions
                final currentLeft =
                    startLeft + (endLeft - startLeft) * _bounceAnimation!.value;
                final currentBottom = endBottom;

                // Scale animation - starts at button size, shrinks to gallery size
                final scale =
                    1.4 -
                    (0.7 * _bounceAnimation!.value); // 70px to 50px equivalent

                // Opacity fade in the beginning
                final opacity = _bounceAnimation!.value < 0.1
                    ? _bounceAnimation!.value * 10
                    : 1.0;

                return Positioned(
                  left: currentLeft,
                  bottom: currentBottom,
                  child: Opacity(
                    opacity: opacity,
                    child: Transform.scale(
                      scale: scale,
                      child: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.5),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            _animatingMedia!,
                            fit: BoxFit.cover,
                          ),
                        ),
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

          // Shutter flash effect (on top of everything)
          if (_showShutterFlash)
            Positioned.fill(child: Container(color: Colors.white)),
        ],
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
              width: 85,
              height: 85,
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
                        width: 70,
                        height: 70,
                        child: _isInitialized && _controller != null
                            ? OverflowBox(
                                alignment: Alignment.center,
                                minWidth: 0,
                                maxWidth: double.infinity,
                                minHeight: 0,
                                maxHeight: double.infinity,
                                child: SizedBox(
                                  // Render the preview at full-screen size so the
                                  // OverflowBox centres the frame and the 70×70 clip
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

  Widget _buildTopSettingsPanel() {
    const Color gold = Color(0xFFE5C158);
    return Container(
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
                child: _rotated(Text(
                  type.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFE5C158),
                    fontSize: 9,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 1.2,
                  ),
                )),
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: _rotated(Text(
              type.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.32),
                fontSize: 9,
                fontWeight: FontWeight.w300,
                letterSpacing: 1.2,
              ),
            )),
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
    const double w = 68.0;   // radius of the semicircle = protrusion from screen edge
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
            final newZoom =
                (_zoomAtDragStart - delta / pxPerUnit).clamp(0.5, _zoomMax);
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

    // First-time initialisation — show spinner.
    if (!_isInitialized) {
      return Container(
        color: const Color(0xFF1a1a1a),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
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
        width: size.height,   // diameter = height → radius = height/2
        height: size.height,
      ),
      -math.pi / 2,   // start at top  (12 o'clock)
      -math.pi,       // sweep 180° CCW → through 9 o'clock to 6 o'clock
    );
    path.close();    // straight line back along the right edge
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
  static const Color _gold  = Color(0xFFE5C158);
  static const List<double> _major = [0.5, 1, 2, 5, 10, 15, 20, 25];

  @override
  void paint(Canvas canvas, Size size) {
    final double cy = size.height / 2;
    final double rx = size.width;   // right edge — tick origin

    final double visibleUnits = (size.height / 2) / pxPerUnit;
    final double lo = (zoom - visibleUnits - 1).floorToDouble().clamp(0.5, maxZoom);
    final double hi = (zoom + visibleUnits + 1).ceilToDouble().clamp(0.5, maxZoom);

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

      final bool isSwitchover = switchoverFactors.any((s) => (v - s).abs() < 0.08);
      final bool isMajor = _major.any((m) => (v - m).abs() < 0.02) || isSwitchover;
      final double tickLen = isSwitchover ? 22.0 : (isMajor ? 16.0 : 7.0);

      final Paint p = isSwitchover
          ? (Paint()
              ..color = _gold.withValues(alpha: 0.75)
              ..strokeWidth = 1.2)
          : (isMajor ? majorPaint : tickPaint);

      // Horizontal tick from right edge going left
      canvas.drawLine(Offset(rx - tickLen, y), Offset(rx, y), p);

      if (isMajor) {
        final String label = v < 1 ? v.toStringAsFixed(1) : v.toInt().toString();
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
        tp.paint(canvas, Offset(rx - tickLen - tp.width - 3, y - tp.height / 2));
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
    tp.paint(canvas, Offset(rx - tickLen(zoom) - tp.width - 6, cy - tp.height / 2));
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
  circular;

  String get label {
    switch (this) {
      case CompositionMode.none:
        return 'None';
      case CompositionMode.ruleOfThirds:
        return 'Rule of Thirds';
      case CompositionMode.goldenSection:
        return 'Golden Section';
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

/// Tracks a single detected face across frames: last centre + smoothed
/// screen-space velocity, used for latency-compensating position prediction.
class _Track {
  double cx, cy;
  double vx = 0, vy = 0;
  _Track(this.cx, this.cy);
}

class CompositionPainter extends CustomPainter {
  final CompositionMode mode;

  /// Lines from the active grid that are currently edge-aligned.
  final List<_GlowSeg> glowSegs;
  final List<Map<String, dynamic>> detections;
  CompositionPainter(this.mode, {List<_GlowSeg>? glowSegs, List<Map<String, dynamic>>? detections})
    : glowSegs = glowSegs ?? const [],
      detections = detections ?? const [];

  static const Color _gold = Color(0xFFFFFFFF);
  static const double _sw = 0.8;

  /// Normal white hairline paint used by all draw methods.
  Paint _gp({StrokeCap cap = StrokeCap.butt}) => Paint()
    ..color = _gold.withValues(alpha: 0.45)
    ..strokeWidth = _sw
    ..style = PaintingStyle.stroke
    ..strokeCap = cap
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  Paint get _p => _gp(cap: StrokeCap.round);

  @override
  void paint(Canvas canvas, Size size) {
    switch (mode) {
      case CompositionMode.none:
        break;
      case CompositionMode.ruleOfThirds:
        _drawRuleOfThirds(canvas, size);
        break;
      case CompositionMode.goldenSection:
        _drawGoldenSection(canvas, size);
        break;
      case CompositionMode.goldenTriangles:
        _drawGoldenTriangles(canvas, size);
        break;
      case CompositionMode.spiralSection:
        _drawSpiralSection(canvas, size);
        break;
      case CompositionMode.fibonacciSpiral:
        _drawGoldenSpiral(canvas, size);
        break;
      case CompositionMode.harmoniousTriangles:
        _drawHarmoniousTriangles(canvas, size);
        break;
      case CompositionMode.cross:
        _drawCross(canvas, size);
        break;
      case CompositionMode.focalMass:
        _drawFocalMass(canvas, size);
        break;
      case CompositionMode.vArrangement:
        _drawVArrangement(canvas, size);
        break;
      case CompositionMode.diagonal:
        _drawDiagonal(canvas, size);
        break;
      case CompositionMode.radial:
        _drawRadial(canvas, size);
        break;
      case CompositionMode.lArrangement:
        _drawLArrangement(canvas, size);
        break;
      case CompositionMode.compoundCurve:
        _drawCompoundCurve(canvas, size);
        break;
      case CompositionMode.pyramid:
        _drawPyramid(canvas, size);
        break;
      case CompositionMode.circular:
        _drawCircular(canvas, size);
        break;
    }

    // ── Detection bounding boxes ────────────────────────────────────────────────
    // Draw bounding boxes around detected faces/animals for testing purposes.
    if (detections.isNotEmpty) {
      final bboxPaint = Paint()
        ..color = const Color(0xFFE5C158).withValues(alpha: 0.70)
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke;

      for (final det in detections) {
        final x = (det['x'] as num?)?.toDouble() ?? 0.0;
        final y = (det['y'] as num?)?.toDouble() ?? 0.0;
        final w = (det['w'] as num?)?.toDouble() ?? 0.0;
        final h = (det['h'] as num?)?.toDouble() ?? 0.0;
        final label = (det['label'] ?? 'obj').toString();
        final conf = (det['confidence'] as num?)?.toDouble() ?? 1.0;

        // Draw bbox rectangle
        final rect = Rect.fromLTWH(x * size.width, y * size.height, w * size.width, h * size.height);
        canvas.drawRect(rect, bboxPaint);

        // Draw label with confidence
        final labelText = '$label (${(conf * 100).toStringAsFixed(0)}%)';
        final tp = TextPainter(
          text: TextSpan(
            text: labelText,
            style: const TextStyle(
              color: Color(0xFFE5C158),
              fontSize: 10,
              fontWeight: FontWeight.w300,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        tp.layout();
        tp.paint(canvas, Offset(rect.left + 4, rect.top - 14));
      }
    }

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

    // Draw detected objects (faces/animals) as highlighted rounded rects.
    if (detections.isNotEmpty) {
      for (final d in detections) {
        try {
          final double x = (d['x'] as num).toDouble();
          final double y = (d['y'] as num).toDouble();
          final double w = (d['w'] as num).toDouble();
          final double h = (d['h'] as num).toDouble();
          final bool near = (d['near'] as bool?) ?? false;
          final double conf = (d['confidence'] as num?)?.toDouble() ?? 1.0;

          final Rect rect = Rect.fromLTWH(x * size.width, y * size.height, w * size.width, h * size.height);
          final rrect = RRect.fromRectAndRadius(rect.inflate(2.0), const Radius.circular(8));

          final Paint outline = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = near ? 3.0 : 1.4
            ..color = const Color(0xFFE5C158).withValues(alpha: near ? 0.95 : 0.55)
            ..isAntiAlias = true;

          canvas.drawRRect(rrect, outline);

          if (near) {
            final Paint glow = Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 8.0
              ..color = const Color(0xFFE5C158).withValues(alpha: (0.55 * conf).clamp(0.0,1.0))
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0)
              ..isAntiAlias = true;
            canvas.drawRRect(rrect, glow);
          }
        } catch (_) {}
      }
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
    // Assuming _p is your Paint object from the class
    final p = _p;
    const double phi = 1.6180339887;

    Rect rect;
    int dir;

    // 1. Calculate the maximum Golden Rectangle that fits the screen
    if (s.width > s.height) {
      // Landscape: Fit horizontally, or constraint by height
      double w = s.width;
      double h = w / phi;
      if (h > s.height) {
        h = s.height;
        w = h * phi;
      }
      // Center it perfectly
      rect = Rect.fromLTWH((s.width - w) / 2, (s.height - h) / 2, w, h);
      dir = 0; // Landscape starts by cutting the Right square
    } else {
      // Portrait: Fit vertically, or constraint by width
      double h = s.height;
      double w = h / phi;
      if (w > s.width) {
        w = s.width;
        h = w * phi;
      }
      rect = Rect.fromLTWH((s.width - w) / 2, (s.height - h) / 2, w, h);
      dir = 1; // Portrait starts by cutting the Bottom square
    }

    final path = Path();
    bool isFirst = true;

    // 2. Loop to cut squares and draw continuous quarter arcs
    // 12 iterations gets us smoothly down to the sub-pixel "eye" of the spiral
    for (int i = 0; i < 12; i++) {
      // The square size is always the shortest side of the current golden rect
      double sqSize = math.min(rect.width, rect.height);

      Offset center;
      double startAngle;
      // We always sweep exactly 90 degrees clockwise
      const double sweepAngle = math.pi / 2;

      if (dir == 0) {
        // Cut Right Square, anchor center at Top-Left of that square
        center = Offset(rect.right - sqSize, rect.top);
        startAngle = 0;
        rect = Rect.fromLTRB(
          rect.left,
          rect.top,
          rect.right - sqSize,
          rect.bottom,
        );
      } else if (dir == 1) {
        // Cut Bottom Square, anchor center at Top-Right of that square
        center = Offset(rect.right, rect.bottom - sqSize);
        startAngle = math.pi / 2;
        rect = Rect.fromLTRB(
          rect.left,
          rect.top,
          rect.right,
          rect.bottom - sqSize,
        );
      } else if (dir == 2) {
        // Cut Left Square, anchor center at Bottom-Right of that square
        center = Offset(rect.left + sqSize, rect.bottom);
        startAngle = math.pi;
        rect = Rect.fromLTRB(
          rect.left + sqSize,
          rect.top,
          rect.right,
          rect.bottom,
        );
      } else {
        // Cut Top Square, anchor center at Bottom-Left of that square
        center = Offset(rect.left, rect.top + sqSize);
        startAngle = -math.pi / 2;
        rect = Rect.fromLTRB(
          rect.left,
          rect.top + sqSize,
          rect.right,
          rect.bottom,
        );
      }

      // Draw the quarter circle for this specific square
      final arcRect = Rect.fromCircle(center: center, radius: sqSize);

      // Setting forceMoveTo to `isFirst` ensures the whole path is one unbroken line
      path.arcTo(arcRect, startAngle, sweepAngle, isFirst);
      isFirst = false;

      // Cycle direction clockwise
      dir = (dir + 1) % 4;
    }

    canvas.drawPath(path, p);
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

  @override
  bool shouldRepaint(CompositionPainter old) =>
      old.mode != mode || old.glowSegs != glowSegs || old.detections != detections;
}
