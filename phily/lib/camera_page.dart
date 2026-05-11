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
  String?
  _compositionGuide; // null, 'Fibonacci', 'Golden', 'Triangle', 'Diagonal'

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
    // Pre-warm the camera after short delay
    Future.delayed(const Duration(seconds: 1), () {
      _warmUpCamera();
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
    super.dispose();
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
          // Live camera preview
          Positioned.fill(child: _buildPreview()),

          // Shutter flash effect
          if (_showShutterFlash)
            Positioned.fill(child: Container(color: Colors.white)),

          // Top settings panel
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopSettingsPanel(),
          ),

          // Bottom controls overlay
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.only(
                left: 20,
                right: 20,
                bottom: 40,
                top: 20,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.7),
                    Colors.black.withValues(alpha: 0.3),
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Composition guide buttons
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildCompositionButton('Fibonacci'),
                        const SizedBox(width: 12),
                        _buildCompositionButton('Golden'),
                        const SizedBox(width: 12),
                        _buildCompositionButton('Triangle'),
                        const SizedBox(width: 12),
                        _buildCompositionButton('Diagonal'),
                      ],
                    ),
                  ),
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
            Colors.black.withValues(alpha: 0.6),
            Colors.black.withValues(alpha: 0.3),
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
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: icon != null
            ? Icon(icon, color: Colors.white, size: 20)
            : Text(
                label!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }

  Widget _buildCompositionButton(String type) {
    final isSelected = _compositionGuide == type;
    return GestureDetector(
      onTap: () {
        setState(() {
          // Toggle: if already selected, turn off; otherwise select this one
          _compositionGuide = isSelected ? null : type;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected
              ? Colors.white.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.1),
          border: isSelected
              ? Border.all(color: Colors.white, width: 1.5)
              : null,
        ),
        child: Text(
          type,
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
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
