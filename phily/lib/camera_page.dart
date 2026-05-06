import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'dart:io';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage>
    with SingleTickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isInitialized = false;
  bool _isRecording = false;
  File? _lastCapturedMedia;
  String? _error;

  // Animation for bounce effect
  AnimationController? _bounceController;
  Animation<double>? _bounceAnimation;
  File? _animatingMedia;
  bool _showBounceAnimation = false;

  final picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _initializeCamera();

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
        ResolutionPreset.high,
        enableAudio: true,
      );

      await _controller!.initialize();

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

  @override
  void dispose() {
    _controller?.dispose();
    _bounceController?.dispose();
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

    try {
      final image = await _controller!.takePicture();
      final file = File(image.path);

      // Save to gallery
      await ImageGallerySaver.saveFile(file.path);

      setState(() {
        _lastCapturedMedia = file;
      });

      // Trigger bounce animation
      _triggerBounceAnimation(file);
    } catch (e) {
      debugPrint('Error taking photo: $e');
    }
  }

  Future<void> _startVideoRecording() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isRecording)
      return;

    try {
      await _controller!.startVideoRecording();
      setState(() {
        _isRecording = true;
      });
    } catch (e) {
      debugPrint('Error starting video: $e');
    }
  }

  Future<void> _stopVideoRecording() async {
    if (_controller == null || !_isRecording) return;

    try {
      final video = await _controller!.stopVideoRecording();
      final file = File(video.path);

      // Save to gallery
      await ImageGallerySaver.saveFile(file.path);

      setState(() {
        _isRecording = false;
        _lastCapturedMedia = file;
      });

      // Trigger bounce animation
      _triggerBounceAnimation(file);
    } catch (e) {
      debugPrint('Error stopping video: $e');
      setState(() {
        _isRecording = false;
      });
    }
  }

  Future<void> _selectFromGallery() async {
    try {
      final pickedFile = await picker.pickMedia();

      if (pickedFile != null) {
        setState(() {
          _lastCapturedMedia = File(pickedFile.path);
        });
      }
    } catch (e) {
      debugPrint('Error picking from gallery: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Live camera preview
          Positioned.fill(child: _buildPreview()),

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
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
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
                      child: _lastCapturedMedia != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.file(
                                _lastCapturedMedia!,
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
                  GestureDetector(
                    onTap: _isInitialized && !_isRecording
                        ? _capturePhoto
                        : null,
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
                        border: Border.all(color: Colors.white, width: 4),
                      ),
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRecording ? Colors.red : Colors.white,
                        ),
                        child: _isRecording
                            ? Container(
                                margin: const EdgeInsets.all(18),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),

                  // Empty space for symmetry
                  const SizedBox(width: 50),
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

    // Show live camera preview
    return CameraPreview(_controller!);
  }
}
