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

  final picker = ImagePicker();

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

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Camera initialization failed: $e';
      });
      debugPrint('Camera error: $e');
    }
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
    final double newZoom = (_baseZoom * details.scale).clamp(
      _minZoom,
      _maxZoom,
    );
    if ((newZoom - _currentZoom).abs() < 0.01) return;
    _currentZoom = newZoom;
    try {
      await _controller!.setZoomLevel(_currentZoom);
    } catch (_) {}
    setState(() {});
  }

  void _triggerBounceAnimation(File capturedFile) {
    setState(() {
      _animatingMedia = capturedFile;
      _showBounceAnimation = true;
    });
    _bounceController!.forward();
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
      // Capture photo (now feels instant because UI already responded)
      final image = await _controller!.takePicture();
      final file = File(image.path);

      // Trigger bounce animation
      _triggerBounceAnimation(file);

      // Save to gallery in background (don't await)
      _saveMediaInBackground(file.path);
    } catch (e) {
      debugPrint('Error taking photo: $e');
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
      // Start recording in background (now feels instant)
      await _controller!.startVideoRecording();
    } catch (e) {
      debugPrint('Error starting video: $e');
      // Revert state if recording failed
      setState(() {
        _isRecording = false;
      });
      _glowController!.stop();
      _glowController!.reset();
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
      // Stop recording (UI already responded, so this feels instant)
      final video = await _controller!.stopVideoRecording();
      final file = File(video.path);

      // Trigger bounce animation
      _triggerBounceAnimation(file);

      // Save to gallery in background (don't await)
      _saveMediaInBackground(file.path);
    } catch (e) {
      debugPrint('Error stopping video: $e');

      // Animation already stopped above, just reset controller
      _glowController!.reset();
    }
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

          // Focus ring — animated pulse then fade
          if (_focusPoint != null)
            AnimatedBuilder(
              animation: _focusRingController!,
              builder: (context, _) {
                const double size = 68.0;
                return Positioned(
                  left: _focusPoint!.dx - size / 2,
                  top: _focusPoint!.dy - size / 2,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: _focusRingOpacity.value,
                      child: Transform.scale(
                        scale: _focusRingScale.value,
                        child: Container(
                          width: size,
                          height: size,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: const Color(0xFFD4AF37),
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

          // Composition guide overlay — inset to the live camera preview area,
          // below the top settings panel and above the bottom controls.
          if (_compositionMode != CompositionMode.none)
            Positioned(
              // Top panel: safe-area top + 12 top-padding + content (~32px) + 16 bottom-padding
              top: MediaQuery.of(context).padding.top + 60,
              // Bottom controls: 34 safe-area + 10 top-padding + 45 belt + 12 gap + 85 capture button
              bottom: 186,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: CompositionPainter(_compositionMode),
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

          // Zoom level indicator
          if (_currentZoom > _minZoom + 0.05)
            Positioned(
              top: 0,
              bottom: 0,
              right: 14,
              child: Align(
                alignment: Alignment.center,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_currentZoom.toStringAsFixed(1)}×',
                      style: const TextStyle(
                        color: Color(0xFFD4AF37),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
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
                bottom: 34,
                top: 10,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.88),
                    Colors.black.withValues(alpha: 0.45),
                  ],
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
                  const SizedBox(height: 8),
                  // Zoom quick-select pills
                  if (_isInitialized)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final double z in [0.5, 1.0, 2.0, 3.0])
                          if (z >= _minZoom && z <= _maxZoom) _buildZoomPill(z),
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
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: _latestThumbnail != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.memory(
                                    _latestThumbnail!,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : const Icon(
                                  Icons.photo_library,
                                  color: Colors.white,
                                  size: 24,
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

          // Recording indicator
          if (_isRecording)
            Positioned(
              top: 60,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, color: Colors.white, size: 12),
                      SizedBox(width: 8),
                      Text(
                        'REC',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
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

                  // Magnifying glass effect in the center
                  Center(
                    child: ClipOval(
                      child: Container(
                        width: 70,
                        height: 70,
                        child: BackdropFilter(
                          filter: ImageFilter.matrix(
                            Matrix4.identity().scaled(1.5, 1.5, 1.0).storage,
                          ),
                          child: Container(color: Colors.transparent),
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
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 12,
        bottom: 16,
        left: 16,
        right: 16,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.80),
            Colors.black.withValues(alpha: 0.45),
          ],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Flash control
          _buildSettingButton(
            icon: _flashMode == FlashMode.off
                ? Icons.flash_off
                : _flashMode == FlashMode.auto
                ? Icons.flash_auto
                : Icons.flash_on,
            iconColor: _flashMode == FlashMode.off
                ? Colors.white
                : Colors.yellow,
            onTap: _toggleFlash,
          ),

          // Divider
          Container(
            height: 20,
            width: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.white.withValues(alpha: 0.3),
                  Colors.transparent,
                ],
              ),
            ),
          ),

          // Format control
          _buildSettingButton(label: _imageFormat, onTap: _toggleImageFormat),

          // Divider
          Container(
            height: 20,
            width: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.white.withValues(alpha: 0.3),
                  Colors.transparent,
                ],
              ),
            ),
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
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: icon != null
            ? Icon(icon, color: iconColor ?? Colors.white, size: 20)
            : Text(
                label!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.8,
                ),
              ),
      ),
    );
  }

  Widget _buildCompositionButton(String type, {bool isSelected = false}) {
    return isSelected
        ? ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: const Color(0xFFD4AF37).withValues(alpha: 0.15),
                  border: Border.all(
                    color: const Color(0xFFD4AF37).withValues(alpha: 0.75),
                    width: 1.5,
                  ),
                ),
                child: Text(
                  type,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              type,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.50),
                fontSize: 10,
                fontWeight: FontWeight.w300,
                letterSpacing: 0.2,
              ),
            ),
          );
  }

  Widget _buildZoomPill(double zoom) {
    final bool isSelected = (_currentZoom - zoom).abs() < 0.15;
    return GestureDetector(
      onTap: () async {
        if (_controller == null || !_controller!.value.isInitialized) return;
        final double z = zoom.clamp(_minZoom, _maxZoom);
        try {
          await _controller!.setZoomLevel(z);
          setState(() => _currentZoom = z);
        } catch (_) {}
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? Colors.white.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.18),
            width: 1,
          ),
        ),
        child: Text(
          '${zoom < 1 ? zoom : zoom.toInt()}×',
          style: TextStyle(
            color: isSelected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.45),
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            letterSpacing: 0.3,
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
// Composition mode enum
// ─────────────────────────────────────────────────────────────────────────────

enum CompositionMode {
  none,
  ruleOfThirds,
  goldenSection,
  goldenTriangles,
  spiralSection,
  goldenSpiral,
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
      case CompositionMode.goldenSpiral:
        return 'Golden Spiral';
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

class CompositionPainter extends CustomPainter {
  final CompositionMode mode;
  const CompositionPainter(this.mode);

  static const Color _gold = Color(0xFFD4AF37);
  static const double _sw = 1.2;

  Paint get _p => Paint()
    ..color = _gold.withValues(alpha: 0.70)
    ..strokeWidth = _sw
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

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
      case CompositionMode.goldenSpiral:
        _drawGoldenSpiral(canvas, size);
        break;
      case CompositionMode.fibonacciSpiral:
        _drawFibonacciSpiral(canvas, size);
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
  }

  // ── Rule of Thirds ──────────────────────────────────────────────────────────
  // Two equally spaced verticals + two equally spaced horizontals → 9 equal cells.
  // StrokeCap.butt ensures lines stay strictly within the frame boundaries.
  void _drawRuleOfThirds(Canvas canvas, Size s) {
    final p = Paint()
      ..color = _gold.withValues(alpha: 0.70)
      ..strokeWidth = _sw
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

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
    final p = Paint()
      ..color = _gold.withValues(alpha: 0.70)
      ..strokeWidth = _sw
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

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
    final p = Paint()
      ..color = _gold.withValues(alpha: 0.70)
      ..strokeWidth = _sw
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

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
    final p = Paint()
      ..color = _gold.withValues(alpha: 0.70)
      ..strokeWidth = _sw
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

    const double phi = 1.6180339887;

    // Outer frame border
    canvas.drawRect(Rect.fromLTWH(0, 0, s.width, s.height), p);

    double x = 0, y = 0, w = s.width, h = s.height;

    // Direction cycle — each step cuts one side off the current rectangle,
    // keeping the smaller phi-scaled piece for the next iteration.
    // 0: cut bottom (horizontal) → keep top
    // 1: cut left  (vertical)   → keep right
    // 2: cut top   (horizontal) → keep bottom
    // 3: cut right (vertical)   → keep left
    for (int i = 0; i < 6; i++) {
      switch (i % 4) {
        case 0:
          final double cutH = h / phi;
          canvas.drawLine(Offset(x, y + cutH), Offset(x + w, y + cutH), p);
          h = cutH;
          break;
        case 1:
          final double cutW = w / phi;
          canvas.drawLine(
            Offset(x + w - cutW, y),
            Offset(x + w - cutW, y + h),
            p,
          );
          x = x + w - cutW;
          w = cutW;
          break;
        case 2:
          final double cutH = h / phi;
          canvas.drawLine(
            Offset(x, y + h - cutH),
            Offset(x + w, y + h - cutH),
            p,
          );
          y = y + h - cutH;
          h = cutH;
          break;
        case 3:
          final double cutW = w / phi;
          canvas.drawLine(Offset(x + cutW, y), Offset(x + cutW, y + h), p);
          w = cutW;
          break;
      }
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

  // ── Fibonacci Spiral (parametric) ──────────────────────────────────────────
  void _drawFibonacciSpiral(Canvas canvas, Size s) {
    final p = _p;
    const double phi = 1.6180339887;
    final double cx = s.width * 0.382;
    final double cy = s.height * 0.618;
    const double endTheta = 2.5 * math.pi;
    final double maxR = s.width * 0.70;
    final double a = maxR / math.pow(phi, 2 * endTheta / math.pi);
    const double startTheta = -3.5 * math.pi;
    final path = Path();
    const int steps = 600;
    for (int i = 0; i <= steps; i++) {
      final double theta = startTheta + (endTheta - startTheta) * i / steps;
      final double r = a * math.pow(phi, 2 * theta / math.pi).toDouble();
      final double x = cx + r * math.cos(theta);
      final double y = cy + r * math.sin(theta);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, p);
    // Origin dot
    canvas.drawCircle(
      Offset(cx, cy),
      2.5,
      Paint()
        ..color = _gold.withValues(alpha: 0.70)
        ..style = PaintingStyle.fill,
    );
  }

  // ── Harmonious Triangles ────────────────────────────────────────────────────
  // Both diagonals, each with its two perpendiculars from the opposite corners.
  // TL→BR set (Golden Triangles) + TR→BL set (its mirror) = 6 lines, 8 triangles.
  void _drawHarmoniousTriangles(Canvas canvas, Size s) {
    final p = Paint()
      ..color = _gold.withValues(alpha: 0.70)
      ..strokeWidth = _sw
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

    final double w = s.width;
    final double h = s.height;
    final double d2 = w * w + h * h;

    // ── Set 1: TL→BR diagonal + perps from TR and BL ─────────────────────────
    canvas.drawLine(Offset(0, 0), Offset(w, h), p);

    final double t1TR = (w * w) / d2; // perp from TR onto TL→BR
    canvas.drawLine(Offset(w, 0), Offset(t1TR * w, t1TR * h), p);

    final double t1BL = (h * h) / d2; // perp from BL onto TL→BR
    canvas.drawLine(Offset(0, h), Offset(t1BL * w, t1BL * h), p);

    // ── Set 2: TR→BL diagonal + perps from TL and BR ─────────────────────────
    canvas.drawLine(Offset(w, 0), Offset(0, h), p);

    final double t2TL = (w * w) / d2; // perp from TL onto TR→BL
    canvas.drawLine(Offset(0, 0), Offset(w - t2TL * w, t2TL * h), p);

    final double t2BR = (h * h) / d2; // perp from BR onto TR→BL
    canvas.drawLine(Offset(w, h), Offset(w - t2BR * w, t2BR * h), p);
  }

  // ── Cross ───────────────────────────────────────────────────────────────────
  void _drawCross(Canvas canvas, Size s) {
    final p = _p;
    canvas.drawLine(Offset(s.width / 2, 0), Offset(s.width / 2, s.height), p);
    canvas.drawLine(Offset(0, s.height / 2), Offset(s.width, s.height / 2), p);
  }

  // ── Focal Mass ──────────────────────────────────────────────────────────────
  // Scattered dot cluster in the upper-center (like reference image)
  void _drawFocalMass(Canvas canvas, Size s) {
    final dotP = Paint()
      ..color = _gold.withValues(alpha: 0.70)
      ..style = PaintingStyle.fill;
    // Cluster centered at ~50% x, 40% y
    final double cx = s.width * 0.50;
    final double cy = s.height * 0.40;
    final rng = math.Random(42); // deterministic seed
    for (int i = 0; i < 45; i++) {
      // Gaussian-ish spread using two uniform samples
      final double u1 = rng.nextDouble();
      final double u2 = rng.nextDouble();
      final double mag = math.sqrt(-2 * math.log(u1 + 0.0001)) * 30;
      final double angle = 2 * math.pi * u2;
      // Squash horizontally to look more like scattered flock
      final double dx =
          math.cos(angle) * mag * 1.6 + (rng.nextDouble() - 0.5) * 20;
      final double dy =
          math.sin(angle) * mag * 0.8 + (rng.nextDouble() - 0.5) * 10;
      final double radius = rng.nextDouble() * 1.8 + 0.6;
      canvas.drawCircle(Offset(cx + dx, cy + dy), radius, dotP);
    }
  }

  // ── V Arrangement ───────────────────────────────────────────────────────────
  // V shape opening upward, vertex at bottom-center
  void _drawVArrangement(Canvas canvas, Size s) {
    final p = _p;
    final double vx = s.width * 0.5;
    final double vy = s.height * 0.75;
    canvas.drawLine(Offset(vx, vy), Offset(s.width * 0.1, s.height * 0.15), p);
    canvas.drawLine(Offset(vx, vy), Offset(s.width * 0.9, s.height * 0.15), p);
    // Inner diagonal lines matching reference
    canvas.drawLine(
      Offset(s.width * 0.25, s.height * 0.55),
      Offset(s.width * 0.9, s.height * 0.85),
      p,
    );
  }

  // ── Diagonal ────────────────────────────────────────────────────────────────
  // Two strong diagonals plus two parallel helpers — like the reference
  void _drawDiagonal(Canvas canvas, Size s) {
    final p = _p;
    // Main bold diagonal top-left to bottom-right
    canvas.drawLine(Offset(0, 0), Offset(s.width, s.height), p);
    // Parallel helper lines
    final double offset = s.width * 0.15;
    canvas.drawLine(
      Offset(offset, 0),
      Offset(s.width, s.height - offset * (s.height / s.width)),
      p,
    );
    canvas.drawLine(
      Offset(0, offset * (s.height / s.width)),
      Offset(s.width - offset, s.height),
      p,
    );
  }

  // ── Radial ──────────────────────────────────────────────────────────────────
  // Lines radiating from center like a star
  void _drawRadial(Canvas canvas, Size s) {
    final p = _p;
    final Offset center = Offset(s.width / 2, s.height / 2);
    final int count = 8;
    for (int i = 0; i < count; i++) {
      final double angle = i * math.pi / count;
      final double cos = math.cos(angle);
      final double sin = math.sin(angle);
      // Extend to screen edge in both directions
      final double tMax = _rayLength(s, center, cos, sin);
      canvas.drawLine(
        Offset(center.dx - cos * tMax, center.dy - sin * tMax),
        Offset(center.dx + cos * tMax, center.dy + sin * tMax),
        p,
      );
    }
  }

  double _rayLength(Size s, Offset o, double cos, double sin) {
    double t = double.infinity;
    if (cos.abs() > 1e-6) {
      t = math.min(t, (cos > 0 ? s.width - o.dx : o.dx) / cos.abs());
    }
    if (sin.abs() > 1e-6) {
      t = math.min(t, (sin > 0 ? s.height - o.dy : o.dy) / sin.abs());
    }
    return t;
  }

  // ── L Arrangement ───────────────────────────────────────────────────────────
  void _drawLArrangement(Canvas canvas, Size s) {
    final p = _p;
    // Vertical bar on the right ~70%
    final double vx = s.width * 0.68;
    canvas.drawLine(
      Offset(vx, s.height * 0.18),
      Offset(vx, s.height * 0.80),
      p,
    );
    // Horizontal bar at the bottom of the vertical
    canvas.drawLine(
      Offset(vx, s.height * 0.80),
      Offset(s.width * 0.20, s.height * 0.80),
      p,
    );
  }

  // ── Compound Curve ──────────────────────────────────────────────────────────
  // S-curve through center using two cubic bezier segments
  void _drawCompoundCurve(Canvas canvas, Size s) {
    final p = _p;
    final path = Path();
    // Start top-center, S-curve to bottom-center
    path.moveTo(s.width * 0.5, 0);
    path.cubicTo(
      s.width * 0.1,
      s.height * 0.25,
      s.width * 0.9,
      s.height * 0.60,
      s.width * 0.5,
      s.height * 0.85,
    );
    path.cubicTo(
      s.width * 0.3,
      s.height * 0.95,
      s.width * 0.5,
      s.height,
      s.width * 0.5,
      s.height,
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
  bool shouldRepaint(CompositionPainter old) => old.mode != mode;
}
