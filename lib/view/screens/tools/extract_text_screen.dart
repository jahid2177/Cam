import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

class ExtractTextScreen extends StatefulWidget {
  const ExtractTextScreen({super.key});
  @override State<ExtractTextScreen> createState() => _ExtractTextScreenState();
}
class _ExtractTextScreenState extends State<ExtractTextScreen> {
  final _picker = ImagePicker();
  final _controller = TextEditingController();
  bool _busy = false;
  File? _image;
  Future<void> _pick(ImageSource source) async {
    final x = await _picker.pickImage(source: source, imageQuality: 100);
    if (x == null) return;
    setState(() { _busy = true; _image = File(x.path); });
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(x.path));
      if (mounted) setState(() => _controller.text = result.text);
    } finally {
      await recognizer.close();
      if (mounted) setState(() => _busy = false);
    }
  }
  @override void dispose(){ _controller.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Extract Text')),
    body: Padding(padding: const EdgeInsets.all(16), child: Column(children:[
      if (_image != null) ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.file(_image!, height: 180, fit: BoxFit.contain)),
      const SizedBox(height: 12),
      Row(children:[Expanded(child: FilledButton.icon(onPressed:_busy?null:()=>_pick(ImageSource.camera),icon:const Icon(Icons.camera_alt),label:const Text('Camera'))),const SizedBox(width:10),Expanded(child:OutlinedButton.icon(onPressed:_busy?null:()=>_pick(ImageSource.gallery),icon:const Icon(Icons.photo_library),label:const Text('Gallery')))]),
      const SizedBox(height: 16),
      if(_busy) const LinearProgressIndicator(),
      Expanded(child: TextField(controller:_controller, expands:true, maxLines:null, minLines:null, decoration:const InputDecoration(border:OutlineInputBorder(), hintText:'Recognized text will appear here'))),
    ])),
  );
}
