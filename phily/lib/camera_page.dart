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
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 300,
              height: 300,
              child: image != null 
                  ? 
                  
                  //image selected, show it
                  Image.file(image!, fit: BoxFit.cover) 
                  : 
                  
                  //no image selected, show camera icon
                  const Icon(Icons.camera_alt, size: 50),
            ),
            Center(
              child: const Text('No image selected'),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                //camera button
                ElevatedButton(
                  onPressed: () => pickImage(ImageSource.camera), 
                  child: const Text('Take Photo'),
                ),

                //gallery button
                ElevatedButton(
                  onPressed: () => pickImage(ImageSource.gallery), 
                  child: const Text('Select from Gallery'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}