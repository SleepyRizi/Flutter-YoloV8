// Copyright 2023 The Flutter team. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';  // make sure you have this import at the top of your file


import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image_lib;
import 'postProc.dart';
// import 'recognition.dart';
import 'image_utils.dart';
import 'package:tflite_flutter/tflite_flutter.dart';


/// All the command codes that can be sent and received between [Detector] and
/// [_DetectorServer].
enum _Codes {
  init,
  busy,
  ready,
  detect,
  result,
}

/// A command sent between [Detector] and [_DetectorServer].
class _Command {
  const _Command(this.code, {this.args});

  final _Codes code;
  final List<Object>? args;
}

class Detector {
  static const String _modelPath = 'assets/model/best_float32.tflite';
  // static const String _labelPath = 'assets/models/labelmap.txt';

  Detector._(this._isolate, this._interpreter);

  final Isolate _isolate;
  late final Interpreter _interpreter;
  // late final List<String> _labels;

  // To be used by detector (from UI) to send message to our Service ReceivePort
  late final SendPort _sendPort;

  bool _isReady = false;

  // // Similarly, StreamControllers are stored in a queue so they can be handled
  // // asynchronously and serially.
  final StreamController<Map<String, dynamic>> resultsStream =
  StreamController<Map<String, dynamic>>();

  /// Open the database at [path] and launch the server on a background isolate..
  static Future<Detector> start() async {
    final ReceivePort receivePort = ReceivePort();
    // sendPort - To be used by service Isolate to send message to our ReceiverPort
    final Isolate isolate =
    await Isolate.spawn(_DetectorServer._run, receivePort.sendPort);

    final Detector result = Detector._(
        isolate,
        await _loadModel()
      // await _loadLabels(),
    );
    receivePort.listen((message) {
      result._handleCommand(message as _Command);
    });
    return result;
  }

  static Future<Interpreter> _loadModel() async {
    final interpreterOptions = InterpreterOptions();

    // Use XNNPACK Delegate
    if (Platform.isAndroid) {
      interpreterOptions.addDelegate(XNNPackDelegate());
    }
    if (Platform.isIOS) {
      interpreterOptions.addDelegate(GpuDelegate());
    }

    return Interpreter.fromAsset(
      _modelPath,
      options: interpreterOptions..threads = 4,
    );
  }



  /// Starts CameraImage processing
  void processFrame(File imageFile) {
    if (_isReady) {
      _sendPort.send(_Command(_Codes.detect, args: [imageFile]));
    }
  }


  /// Handler invoked when a message is received from the port communicating
  /// with the database server.
  void _handleCommand(_Command command) {
    switch (command.code) {
      case _Codes.init:
        _sendPort = command.args?[0] as SendPort;

        RootIsolateToken rootIsolateToken = RootIsolateToken.instance!;
        _sendPort.send(_Command(_Codes.init, args: [
          rootIsolateToken,
          _interpreter.address,
          // _labels,
        ]));
      case _Codes.ready:
        _isReady = true;
      case _Codes.busy:
        _isReady = false;
      case _Codes.result:
        _isReady = true;
        resultsStream.add(command.args?[0] as Map<String, dynamic>);
      default:
        debugPrint('Detector unrecognized command: ${command.code}');
    }
  }

  /// Kills the background isolate and its detector server.
  void stop() {
    _isolate.kill();
  }
}

/// The portion of the [Detector] that runs on the background isolate.
///
/// This is where we use the new feature Background Isolate Channels, which
/// allows us to use plugins from background isolates.
class _DetectorServer {
  /// Input size of image (height = width = 300)
  static const int mlModelInputSize = 128;

  /// Result confidence threshold
  static const double confidence = 0.5;
  Interpreter? _interpreter;
  // List<String>? _labels;

  _DetectorServer(this._sendPort);

  final SendPort _sendPort;



  /// The main entrypoint for the background isolate sent to [Isolate.spawn].
  static void _run(SendPort sendPort) {
    ReceivePort receivePort = ReceivePort();
    final _DetectorServer server = _DetectorServer(sendPort);
    receivePort.listen((message) async {
      final _Command command = message as _Command;
      await server._handleCommand(command);
    });
    // receivePort.sendPort - used by UI isolate to send commands to the service receiverPort
    sendPort.send(_Command(_Codes.init, args: [receivePort.sendPort]));
  }

  /// Handle the [command] received from the [ReceivePort].
  Future<void> _handleCommand(_Command command) async {
    switch (command.code) {
      case _Codes.init:

        RootIsolateToken rootIsolateToken =
        command.args?[0] as RootIsolateToken;

        BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
        _interpreter = Interpreter.fromAddress(command.args?[1] as int);
        // _labels = command.args?[2] as List<String>;
        _sendPort.send(const _Command(_Codes.ready));
      case _Codes.detect:
        _sendPort.send(const _Command(_Codes.busy));
        // _convertCameraImage(command.args?[0] as CameraImage);
        _convertFileImage(command.args?[0] as File);
      default:
        debugPrint('_DetectorService unrecognized command ${command.code}');
    }
  }

  // void _convertCameraImage(CameraImage cameraImage) {
  //   var preConversionTime = DateTime.now().millisecondsSinceEpoch;
  //
  //   convertCameraImageToImage(cameraImage).then((image) {
  //     if (image != null) {
  //       if (Platform.isAndroid) {
  //         image = image_lib.copyRotate(image, angle: 90);
  //       }
  //
  //       final results = analyseImage(image, preConversionTime);
  //       _sendPort.send(_Command(_Codes.result, args: [results]));
  //     }
  //   });
  // }

  void _convertFileImage(File fileImage) async {
    Uint8List imageBytes = await fileImage.readAsBytes();  // Changed the type here
    image_lib.Image? image = image_lib.decodeImage(imageBytes);
    if (image != null) {
      final results = analyseImage(image, DateTime.now().millisecondsSinceEpoch);
      _sendPort.send(_Command(_Codes.result, args: [results]));
    }
  }



  Map<String, dynamic> analyseImage(
      image_lib.Image? image, int preConversionTime) {

    double iou_threshold = 0.45;
    double conf_threshold = 0.1;
    double class_threshold = 0.5;

    var conversionElapsedTime =
        DateTime.now().millisecondsSinceEpoch - preConversionTime;

    var preProcessStart = DateTime.now().millisecondsSinceEpoch;

    /// Pre-process the image
    /// Resizing image for model [640, 640]
    final imageInput = image_lib.copyResize(
      image!,
      width: 640,
      height: 640,
    );

    // Creating matrix representation, [640, 640, 3]
    final imageMatrix = List.generate(
      imageInput.height,
          (y) => List.generate(
        imageInput.width,
            (x) {
          final pixel = imageInput.getPixel(x, y);
          return [pixel.rNormalized, pixel.gNormalized, pixel.bNormalized];
        },
      ),
    );

    var preProcessElapsedTime =
        DateTime.now().millisecondsSinceEpoch - preProcessStart;

    var inferenceTimeStart = DateTime.now().millisecondsSinceEpoch;
    print('imageMatrix ${imageMatrix.shape}');
    print('interpreter ${_interpreter!.getInputTensor(0)}');
    final output = _runInference(imageMatrix);
    // Get Conf from output


    List<List<double>> boxes = filledBox(output[0]!.cast<List<List<double>>>(), iou_threshold,
        class_threshold, imageMatrix.shape[1], imageMatrix.shape[2],conf_threshold);
    boxes = restoreSize(boxes, imageMatrix.shape[1], imageMatrix.shape[2], image.width!.round(), image.height!.round());
    List<Map<dynamic,dynamic>>  results = out(boxes);

    List<Rect> rect = [];
    List<String> detectedClasses = [];  // Added this list to store detected classes
    List<double> confidences = [];  // Added this list to store confidences


    for (int i = 0; i < results.length; i++) {

      double x1 = results[i]['box'][0];
      double y1 = results[i]['box'][1];
      double x2 = results[i]['box'][2];
      double y2 = results[i]['box'][3];
      rect.add(Rect.fromLTRB(x1, y1, x2, y2));


    if (results[i]['class_id'] != null) {
    detectedClasses.add(results[i]['class_id']);
    print("Class ID: ${results[i]['class_id']}");  // Assuming 'class_id' is the key for class values
    } else {
    // Handle the missing 'class_id' or its null value here
    print("Missing 'class_id' it has a null value for index $i.");
    }

      if (results[i]['conf'] != null) {
        confidences.add(results[i]['conf']);  // Assuming 'conf' is the key for confidence values
        print("Confidence: ${results[i]['conf']}");  // Assuming 'conf' is the key for confidence values
      } else {
        // Handle the missing 'class_id' or its null value here
        print("Missing 'conf' it has a null value for index $i.");
      }
    }


    var inferenceElapsedTime =
        DateTime.now().millisecondsSinceEpoch - inferenceTimeStart;

    var totalElapsedTime =
        DateTime.now().millisecondsSinceEpoch - preConversionTime;
    print('Convertsion time${conversionElapsedTime.toString()}');
    print('Pre-processing time:${preProcessElapsedTime.toString()}');
    print('Inference time:${inferenceElapsedTime.toString()}');
    print('Total prediction time:${totalElapsedTime.toString()}');
    return {
      "rect": rect,
      "classes": detectedClasses,  // Added this line to return detected classes
      "confidences": confidences,  // Added this line to return confidences
      "stats": <String, String>{
        'Conversion time:': conversionElapsedTime.toString(),
        'Pre-processing time:': preProcessElapsedTime.toString(),
        'Inference time:': inferenceElapsedTime.toString(),
        'Total prediction time:': totalElapsedTime.toString(),
        'Frame': '${image.width} X ${image.height}',
      },
    };
  }


  Map<int, List> _runInference(List<List<List<num>>> imageMatrix,) {
    final input = [imageMatrix];
    final output = {0: List.filled(1 * 58 * 8400, 0).reshape([1, 58, 8400])};

    _interpreter!.runForMultipleInputs([input], output);


    return output;
  }


}