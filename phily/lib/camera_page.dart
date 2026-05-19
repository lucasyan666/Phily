import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:photo_manager/photo_manager.dart';
import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';

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
  double _targetZoom = 1.0;
  bool _isAnimatingZoom = false;
  CameraDescription? _ultraWideCamera;
  bool _isUsingUltraWide = false;

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
  bool _isAnalyzingFrame = false;
  DateTime _lastFrameAnalysis = DateTime.fromMillisecondsSinceEpoch(0);

  final picker = ImagePicker();

  /// Platform channel used to query AVCaptureDeviceDiscoverySession
  /// for the built-in ultra-wide camera uniqueID on iOS.
  static const MethodChannel _cameraChannel = MethodChannel('phily/camera');

  @override
  void initState() {
    super.initState();
    _initializeCamera();
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

      // Resolve the ultra-wide camera via native AVFoundation API.
      _ultraWideCamera = await _resolveUltraWideCamera();

      _controller = CameraController(
        _cameras![0],
        _resolution,
        enableAudio: true,
      );

      await _controller!.initialize();
      await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await _controller!.setFlashMode(_flashMode);
      _minZoom = await _controller!.getMinZoomLevel();
      _maxZoom = await _controller!.getMaxZoomLevel();
      _currentZoom = _minZoom;
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
      final String? uid =
          await _cameraChannel.invokeMethod<String>('getUltraWideCameraId');
      if (uid != null) {
        final match = _cameras!.where((c) => c.name == uid).firstOrNull;
        if (match != null) {
          debugPrint('_resolveUltraWide: matched "${match.name}" via native channel');
          return match;
        }
        debugPrint('_resolveUltraWide: uid "$uid" not found in camera list');
      } else {
        debugPrint('_resolveUltraWide: channel returned null (no ultra-wide on device)');
      }
    } catch (e) {
      debugPrint('_resolveUltraWide: channel error — $e');
    }

    // Fallback: first additional back camera.
    final fallback = _cameras!
        .where(
          (c) => c.lensDirection == CameraLensDirection.back && c != _cameras![0],
        )
        .firstOrNull;
    if (fallback != null) {
      debugPrint('_resolveUltraWide: fallback to "${fallback.name}"');
    }
    return fallback;
  }

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
      // Save to gallery
      await ImageGallerySaver.saveFile(filePath);

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
      setState(() { _isRecording = false; });
      _glowController!.stop();
      _glowController!.reset();
      await _startImageStream();
    }
  }

  Future<void> _stopVideoRecording() async {
    if (_controller == null || !_isRecording) return;

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

  /// Called for every frame from the camera image stream.
  /// Throttled to ~8 fps. Passes a downsampled Y-plane to native Vision
  /// for edge-grid alignment analysis and drives the glow animation.
  Future<void> _onCameraFrame(CameraImage image) async {
    if (_compositionMode == CompositionMode.none) return;
    final now = DateTime.now();
    if (now.difference(_lastFrameAnalysis).inMilliseconds < 125) return;
    if (_isAnalyzingFrame) return;
    _isAnalyzingFrame = true;
    _lastFrameAnalysis = now;
    try {
      final plane = image.planes[0];
      final dstW = 128;
      final dstH = (128 * image.height / image.width).round();
      final bytes = _downsampleY(
        plane.bytes, image.width, image.height, plane.bytesPerRow, dstW, dstH,
      );
      final raw = await _cameraChannel.invokeMethod<dynamic>(
        'analyzeFrame',
        {
          'yPlane': bytes,
          'width': dstW,
          'height': dstH,
          'mode': _compositionMode.name,
        },
      );
      if (!mounted) return;

      final List<dynamic> segs = raw is List ? raw : const [];
      final Set<String> freshKeys = {};
      bool newAlignment = false;

      for (final seg in segs) {
        if (seg is! Map) continue;
        final x1 = (seg['x1'] as num).toDouble();
        final y1 = (seg['y1'] as num).toDouble();
        final x2 = (seg['x2'] as num).toDouble();
        final y2 = (seg['y2'] as num).toDouble();
        // Key with 3dp precision — stable across frames for the same grid line.
        final key = '${x1.toStringAsFixed(3)},${y1.toStringAsFixed(3)}'
            ',${x2.toStringAsFixed(3)},${y2.toStringAsFixed(3)}';
        freshKeys.add(key);
        if (!_glowSegMap.containsKey(key)) {
          _glowSegMap[key] = _GlowSeg(x1, y1, x2, y2, intensity: 0.40);
          newAlignment = true;
        } else {
          _glowSegMap[key]!.intensity =
              (_glowSegMap[key]!.intensity + 0.40).clamp(0.0, 1.0);
        }
      }

      // Fade out lines that were not detected this frame.
      final toRemove = <String>[];
      for (final entry in _glowSegMap.entries) {
        if (!freshKeys.contains(entry.key)) {
          entry.value.intensity -= 0.18;
          if (entry.value.intensity <= 0) toRemove.add(entry.key);
        }
      }
      for (final k in toRemove) _glowSegMap.remove(k);

      // Haptic only when a brand-new line first aligns.
      if (newAlignment) HapticFeedback.heavyImpact();

      setState(() {});
    } catch (e) {
      debugPrint('_onCameraFrame: $e');
    } finally {
      _isAnalyzingFrame = false;
    }
  }

  /// Nearest-neighbour downsampling of the Y (luminance) plane.
  Uint8List _downsampleY(
    Uint8List src, int srcW, int srcH, int bytesPerRow, int dstW, int dstH,
  ) {
    final out = Uint8List(dstW * dstH);
    for (int y = 0; y < dstH; y++) {
      final srcY = (y * srcH / dstH).round().clamp(0, srcH - 1);
      for (int x = 0; x < dstW; x++) {
        final srcX = (x * srcW / dstW).round().clamp(0, srcW - 1);
        out[y * dstW + x] = src[srcY * bytesPerRow + srcX];
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

          // Composition guide overlay — per-segment glow on aligned lines.
          if (_compositionMode != CompositionMode.none)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              bottom: 186,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: CompositionPainter(
                    _compositionMode,
                    glowSegs: _glowSegMap.values.toList(),
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
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  padding: const EdgeInsets.only(
                    left: 20,
                    right: 20,
                    bottom: 34,
                    top: 10,
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
                                      (index - _currentCompositionIndex).abs() *
                                          0.4
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
                      const SizedBox(height: 8),
                      // Zoom quick-select pills
                      if (_isInitialized)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildZoomPill(0.5),
                            for (final double z in [1.0, 2.0, 5.0])
                              if (z <= _maxZoom) _buildZoomPill(z),
                          ],
                        ),
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
                                  : Icon(
                                      Icons.photo_library_outlined,
                                      color: Colors.white.withValues(
                                        alpha: 0.55,
                                      ),
                                      size: 22,
                                    ),
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
            ),
          ),

          // Recording indicator — minimal red dot + monospace label
          if (_isRecording)
            Positioned(
              top: MediaQuery.of(context).padding.top + 70,
              left: 0,
              right: 0,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF3B30),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'REC',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 3.0,
                      ),
                    ),
                  ],
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
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
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
              _buildSettingButton(
                label: _imageFormat,
                onTap: _toggleImageFormat,
              ),

              // Divider
              Container(
                height: 22,
                width: 0.5,
                color: Colors.white.withValues(alpha: 0.15),
              ),

              // Resolution control
              _buildSettingButton(
                label: _resolution == ResolutionPreset.veryHigh
                    ? '24MP'
                    : '48MP',
                onTap: _toggleResolution,
              ),
            ],
          ),
        ),
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
        child: icon != null
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
    );
  }

  Widget _buildCompositionButton(String type, {bool isSelected = false}) {
    const Color gold = Color(0xFFE5C158);
    return isSelected
        ? ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
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
                child: Text(
                  type.toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFFE5C158),
                    fontSize: 10,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              type.toUpperCase(),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.32),
                fontSize: 10,
                fontWeight: FontWeight.w300,
                letterSpacing: 1.2,
              ),
            ),
          );
  }

  Future<void> _switchToUltraWide() async {
    if (_ultraWideCamera == null || _isUsingUltraWide) return;
    setState(() {
      _isInitialized = false;
    });
    await _controller?.dispose();
    _controller = CameraController(
      _ultraWideCamera!,
      _resolution,
      enableAudio: true,
    );
    await _controller!.initialize();
    await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
    await _controller!.setFlashMode(_flashMode);
    _minZoom = await _controller!.getMinZoomLevel();
    _maxZoom = await _controller!.getMaxZoomLevel();
    _currentZoom = _minZoom;
    _isUsingUltraWide = true;
    if (mounted)
      setState(() {
        _isInitialized = true;
      });
  }

  Future<void> _switchToMainCamera() async {
    if (!_isUsingUltraWide) return;
    setState(() {
      _isInitialized = false;
    });
    await _controller?.dispose();
    _controller = CameraController(
      _cameras![0],
      _resolution,
      enableAudio: true,
    );
    await _controller!.initialize();
    await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
    await _controller!.setFlashMode(_flashMode);
    _minZoom = await _controller!.getMinZoomLevel();
    _maxZoom = await _controller!.getMaxZoomLevel();
    _currentZoom = _minZoom;
    _isUsingUltraWide = false;
    if (mounted)
      setState(() {
        _isInitialized = true;
      });
  }

  /// Safely sets the camera zoom level.
  ///
  /// The iOS camera plugin enforces that [setZoomLevel] is called within
  /// [[_minZoom], [_maxZoom]] (typically [1.0, N] for the main lens). Passing
  /// a sub-1.0 value causes a fatal out-of-bounds assertion. This wrapper
  /// intercepts those requests and physically switches to the ultra-wide
  /// camera controller instead, which represents 0.5× on supported devices.
  Future<void> _setCameraZoom(double value) async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    if (value < 1.0) {
      // Fast path: current controller already covers this zoom level.
      // This happens when cameras[0] is itself a virtual device with minZoom ≤ 0.5,
      // OR after switching to a virtual ultra-wide camera (minZoom ≤ 0.5).
      if (value >= _minZoom) {
        final double clamped = value.clamp(_minZoom, _maxZoom);
        try {
          await _controller!.setZoomLevel(clamped);
          if (mounted) setState(() => _currentZoom = clamped);
        } catch (e) {
          debugPrint('_setCameraZoom: setZoomLevel($clamped) failed – $e');
        }
        return;
      }

      // Switch to the ultra-wide camera (physical or virtual).
      if (_ultraWideCamera != null && !_isUsingUltraWide) {
        await _switchToUltraWide();
        // After switching, _minZoom is updated. If the new camera is a virtual
        // device (minZoom ≤ 0.5), call setZoomLevel to land on the exact value.
        if (_minZoom <= value) {
          final double clamped = value.clamp(_minZoom, _maxZoom);
          try {
            await _controller!.setZoomLevel(clamped);
          } catch (e) {
            debugPrint(
              '_setCameraZoom: setZoomLevel($clamped) on ultra-wide failed – $e',
            );
          }
        }
      }
      // Track the logical zoom so the 0.5× pill highlights correctly.
      if (mounted) setState(() => _currentZoom = value);
      return;
    }

    // Returning from ultra-wide to main lens for ≥1× values.
    if (_isUsingUltraWide) {
      await _switchToMainCamera();
    }

    // Clamp strictly within the controller's reported range before calling
    // the plugin — avoids any residual assertion if minZoom > 1.0.
    final double clamped = value.clamp(_minZoom, _maxZoom);
    try {
      await _controller!.setZoomLevel(clamped);
      if (mounted) setState(() => _currentZoom = clamped);
    } catch (e) {
      debugPrint('_setCameraZoom: setZoomLevel($clamped) failed – $e');
    }
  }

  Future<void> _animateZoom(double target) async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    // Sub-1.0 requires a physical lens switch — delegate entirely and return.
    if (target < 1.0) {
      await _setCameraZoom(target);
      return;
    }

    // Returning from ultra-wide: switch back to main before animating.
    if (_isUsingUltraWide) {
      await _switchToMainCamera();
    }

    final double dest = target.clamp(_minZoom, _maxZoom);
    if (_isAnimatingZoom) {
      _targetZoom = dest;
      return;
    }
    _isAnimatingZoom = true;
    _targetZoom = dest;
    const int steps = 30;
    const Duration stepDuration = Duration(milliseconds: 12);
    for (int i = 0; i < steps; i++) {
      if (!mounted) break;
      // If we just switched from ultra-wide, _currentZoom may be <1.0;
      // snap to _minZoom so we never pass a sub-range value to setZoomLevel.
      final double from = _currentZoom < _minZoom ? _minZoom : _currentZoom;
      final double to = _targetZoom;
      final double next = (from + (to - from) * 0.25).clamp(_minZoom, _maxZoom);
      if ((next - to).abs() < 0.005) {
        _currentZoom = to;
        try {
          await _controller!.setZoomLevel(to);
        } catch (_) {}
        if (mounted) setState(() {});
        break;
      }
      _currentZoom = next;
      try {
        await _controller!.setZoomLevel(next);
      } catch (_) {}
      if (mounted) setState(() {});
      await Future.delayed(stepDuration);
    }
    _isAnimatingZoom = false;
  }

  Widget _buildZoomPill(double zoom) {
    final bool isSelected = (_currentZoom - zoom).abs() < 0.15;
    const Color gold = Color(0xFFE5C158);
    return GestureDetector(
      onTap: () => _animateZoom(zoom),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? gold.withValues(alpha: 0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? gold.withValues(alpha: 0.65)
                : Colors.white.withValues(alpha: 0.16),
            width: 1.0,
          ),
        ),
        child: Text(
          '${zoom < 1 ? zoom : zoom.toInt()}×',
          style: TextStyle(
            color: isSelected ? gold : Colors.white.withValues(alpha: 0.38),
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w500 : FontWeight.w300,
            letterSpacing: 0.5,
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

    if (!_isInitialized || _controller == null) {
      return Container(
        color: const Color(0xFF1a1a1a),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    // Show live camera preview with slight horizontal stretch
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
  final double x1, y1, x2, y2;
  double intensity;
  _GlowSeg(this.x1, this.y1, this.x2, this.y2, {this.intensity = 0.0});
}

class CompositionPainter extends CustomPainter {
  final CompositionMode mode;
  /// Lines from the active grid that are currently edge-aligned.
  final List<_GlowSeg> glowSegs;
  CompositionPainter(this.mode, {List<_GlowSeg>? glowSegs})
      : glowSegs = glowSegs ?? const [];

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
        glowPaint.color = const Color(0xFFE5C158)
            .withValues(alpha: (0.65 * seg.intensity).clamp(0.0, 1.0));
        canvas.drawLine(
          Offset(seg.x1 * size.width, seg.y1 * size.height),
          Offset(seg.x2 * size.width, seg.y2 * size.height),
          glowPaint,
        );
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
    final double armUp    = s.height * 0.10;
    final double armDown  = s.height * 0.30;

    // Horizontal crossbar: symmetric, does not reach screen edges.
    final double armLeft  = s.width  * 0.18;
    final double armRight = s.width  * 0.18;

    // Vertical line
    canvas.drawLine(Offset(cx, cy - armUp), Offset(cx, cy + armDown), p);
    // Horizontal crossbar
    canvas.drawLine(Offset(cx - armLeft, cy), Offset(cx + armRight, cy), p);
  }

  // ── Focal Mass ──────────────────────────────────────────────────────────────
  // Scattered dot cluster in the upper-center (like reference image)
  void _drawFocalMass(Canvas canvas, Size s) {
    // Focal center — upper-center of frame.
    final double cx = s.width * 0.50;
    final double cy = s.height * 0.38;

    // Vertical spread: tight horizontally, wide vertically.
    // Dots scatter downward/upward from the core, thinning sharply with distance.
    const double scatterX = 26.0;   // tight horizontal half-width
    const double scatterY = 88.0;   // wide vertical half-height
    const int    count    = 200;    // total dots (increased for denser mass)

    final rng = math.Random(7); // deterministic — same pattern every frame
    final dotPaint = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < count; i++) {
      // Box-Muller → standard normal samples.
      final double u1 = rng.nextDouble().clamp(1e-9, 1.0);
      final double u2 = rng.nextDouble();
      final double n1 = math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
      final double n2 = math.sqrt(-2.0 * math.log(u1)) * math.sin(2 * math.pi * u2);

      final double dx = n1 * scatterX;
      final double dy = n2 * scatterY;

      // Anisotropic normalised distance (0 = core, 1 = edge of scatter zone).
      final double distNorm = math.sqrt(
        math.pow(dx / scatterX, 2) + math.pow(dy / scatterY, 2),
      ).clamp(0.0, 1.0);

      // Steeper Gaussian falloff (k=7) so density drops quickly away from core.
      final double coreInfluence = math.exp(-distNorm * distNorm * 7.0);

      // Dot radius: 0.8px at edge → 2.4px at core.
      final double radius = 0.8 + 1.6 * coreInfluence;

      // Opacity: 0.10 at edge → 0.70 at core.
      final double alpha = 0.10 + 0.60 * coreInfluence;

      // Core zone: tiny filled squares for a sharp geometric look.
      final bool isSquare = distNorm < 0.30 && rng.nextDouble() > 0.4;

      dotPaint.color = _gold.withValues(alpha: alpha);
      final Offset pos = Offset(cx + dx, cy + dy);

      if (isSquare) {
        canvas.drawRect(
          Rect.fromCenter(center: pos, width: radius * 2, height: radius * 2),
          dotPaint,
        );
      } else {
        canvas.drawCircle(pos, radius, dotPaint);
      }

      // Micro-halo on scatter-zone markers — offset satellite dot.
      if (distNorm > 0.25 && distNorm < 0.80 && rng.nextDouble() > 0.55) {
        final double haloDx = (rng.nextDouble() - 0.5) * 3;
        final double haloDy = (rng.nextDouble() - 0.5) * 6;
        dotPaint.color = _gold.withValues(alpha: alpha * 0.30);
        canvas.drawCircle(
          Offset(cx + dx + haloDx, cy + dy + haloDy),
          0.6,
          dotPaint,
        );
      }
    }

    // ── Dense core pass — extra 90 tightly packed dots in the core zone only.
    // Distributed with a much smaller sigma so they cluster visibly at the
    // focal centre on top of the outer scatter field.
    const double coreScatterX = 10.0;
    const double coreScatterY = 14.0;
    const int    coreCount    = 90;
    final rngCore = math.Random(31); // separate seed keeps pattern stable
    for (int i = 0; i < coreCount; i++) {
      final double u1 = rngCore.nextDouble().clamp(1e-9, 1.0);
      final double u2 = rngCore.nextDouble();
      final double n1 = math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
      final double n2 = math.sqrt(-2.0 * math.log(u1)) * math.sin(2 * math.pi * u2);
      final double dx = n1 * coreScatterX;
      final double dy = n2 * coreScatterY;
      final double distNorm = math.sqrt(
        math.pow(dx / coreScatterX, 2) + math.pow(dy / coreScatterY, 2),
      ).clamp(0.0, 1.0);
      final double influence = math.exp(-distNorm * distNorm * 5.0);
      final double radius    = 0.7 + 1.8 * influence;
      final double alpha     = 0.30 + 0.50 * influence;
      dotPaint.color = _gold.withValues(alpha: alpha);
      final Offset pos = Offset(cx + dx, cy + dy);
      // Mix of squares and circles for a crisp geometric core texture.
      if (rngCore.nextDouble() > 0.5) {
        canvas.drawRect(
          Rect.fromCenter(center: pos, width: radius * 2, height: radius * 2),
          dotPaint,
        );
      } else {
        canvas.drawCircle(pos, radius, dotPaint);
      }
    }
  }

  // ── V Arrangement ───────────────────────────────────────────────────────────
  // V shape opening upward, vertex at bottom-center
  void _drawVArrangement(Canvas canvas, Size s) {
    final p = _p;

    // Vertex at lower-center; arms rise symmetrically to the upper corners
    // of a contained region — fully visible, no clipping at edges.
    final double vx = s.width * 0.50;   // horizontal center
    final double vy = s.height * 0.78;  // vertex near bottom

    // Arm endpoints — symmetric, inset from frame edges.
    final double topY = s.height * 0.12;
    final double topLeftX  = s.width * 0.08;
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

    final double cx  = s.width  * 0.50;
    final double cy  = s.height * 0.50;
    final double bow = s.width  * 0.28; // horizontal amplitude of each arc

    // Segment 1: top-edge mid → frame center
    path.moveTo(cx, 0);
    path.cubicTo(
      cx + bow, s.height * 0.20,  // CP1 — bows right
      cx + bow, s.height * 0.40,  // CP2 — stays right before center
      cx,       cy,                // end at frame center
    );

    // Segment 2: frame center → bottom-edge mid (mirrors segment 1)
    path.cubicTo(
      cx - bow, s.height * 0.60,  // CP1 — bows left
      cx - bow, s.height * 0.80,  // CP2 — stays left before bottom
      cx,       s.height,          // end at bottom-edge mid
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
      old.mode != mode || old.glowSegs != glowSegs;
}
