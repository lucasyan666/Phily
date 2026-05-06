import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {

  File? image;
  bool _isPicking = false;

  final picker = ImagePicker();

  Future<void> pickImage(ImageSource source) async {
    if (_isPicking) return;

    setState(() {
      _isPicking = true;
    });

    try {
      final pickedFile = await picker.pickImage(source: source);

      if (pickedFile != null) {
        setState(() {
          image = File(pickedFile.path);
        });
      }
    } catch (error) {
      // ignore duplicate request and other recoverable plugin errors
      debugPrint('Failed to pick image: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isPicking = false;
        });
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Full-screen camera preview/image area
          Positioned.fill(
            child: image != null
                ? Image.file(
                    image!,
                    fit: BoxFit.cover,
                  )
                : Container(
                    color: const Color(0xFF1a1a1a),
                    child: const Center(
                      child: Icon(
                        Icons.camera_alt,
                        size: 80,
                        color: Colors.white38,
                      ),
                    ),
                  ),
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
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Gallery button (bottom left) - shows last photo
                  GestureDetector(
                    onTap: _isPicking ? null : () => pickImage(ImageSource.gallery),
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.white,
                          width: 2,
                        ),
                      ),
                      child: image != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.file(
                                image!,
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

                  // Capture button (center)
                  GestureDetector(
                    onTap: _isPicking ? null : () => pickImage(ImageSource.camera),
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white,
                          width: 4,
                        ),
                      ),
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),

                  // Empty space for symmetry
                  const SizedBox(width: 50),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}