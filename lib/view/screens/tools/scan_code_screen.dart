import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanCodeScreen extends StatefulWidget { const ScanCodeScreen({super.key}); @override State<ScanCodeScreen> createState()=>_ScanCodeScreenState(); }
class _ScanCodeScreenState extends State<ScanCodeScreen>{
  final MobileScannerController _scanner=MobileScannerController(torchEnabled:false);
  String? _value;
  @override void dispose(){_scanner.dispose();super.dispose();}
  void _detected(BarcodeCapture capture){ if(_value!=null||capture.barcodes.isEmpty)return; final v=capture.barcodes.first.rawValue; if(v!=null&&v.isNotEmpty){setState(()=>_value=v);_scanner.stop();}}
  @override Widget build(BuildContext context)=>Scaffold(backgroundColor:Colors.black,appBar:AppBar(backgroundColor:Colors.black,foregroundColor:Colors.white,title:const Text('Scan Code'),actions:[IconButton(onPressed:()=>_scanner.toggleTorch(),icon:const Icon(Icons.flash_on))]),body:Stack(children:[Positioned.fill(child:MobileScanner(controller:_scanner,onDetect:_detected)),Center(child:Container(width:260,height:260,decoration:BoxDecoration(border:Border.all(color:const Color(0xff19b7a4),width:3),borderRadius:BorderRadius.circular(24)))),if(_value!=null)Align(alignment:Alignment.bottomCenter,child:SafeArea(child:Container(margin:const EdgeInsets.all(20),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(18)),child:Column(mainAxisSize:MainAxisSize.min,children:[SelectableText(_value!,style:const TextStyle(color:Colors.black)),const SizedBox(height:10),Row(children:[Expanded(child:OutlinedButton.icon(onPressed:()=>Clipboard.setData(ClipboardData(text:_value!)),icon:const Icon(Icons.copy),label:const Text('Copy'))),const SizedBox(width:10),Expanded(child:FilledButton(onPressed:(){setState(()=>_value=null);_scanner.start();},child:const Text('Scan again')))])]))))]));
}
