import 'dart:io';

import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../vision_assist_config.dart';

class VisionService {
  VisionService()
      : _imageLabeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.45));

  final ImageLabeler _imageLabeler;

  Future<List<String>> scanReadableChunks(String imagePath) async {
    final inputImage = InputImage.fromFile(File(imagePath));
    final result = await _processImage(
      inputImage: inputImage,
      primaryScript: TextRecognitionScript.latin,
    );

    if (result.text.trim().isEmpty) {
      return const [];
    }

    return _buildChunks(result.text);
  }

  Future<String?> detectCurrency(String imagePath) async {
    final inputImage = InputImage.fromFile(File(imagePath));
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(inputImage);
      return _detectCurrencyFromText(result.text);
    } finally {
      await recognizer.close();
    }
  }

  Future<String> detectObjects(String imagePath) async {
    final inputImage = InputImage.fromFile(File(imagePath));
    final labels = await _imageLabeler.processImage(inputImage);
    return _formatObjectSummary(labels);
  }

  Future<void> dispose() => _imageLabeler.close();

  Future<RecognizedText> _processImage({
    required InputImage inputImage,
    required TextRecognitionScript primaryScript,
  }) async {
    Future<RecognizedText?> processWithScript(TextRecognitionScript script) async {
      TextRecognizer? recognizer;
      try {
        recognizer = TextRecognizer(script: script);
        return await recognizer.processImage(inputImage);
      } catch (_) {
        return null;
      } finally {
        await recognizer?.close();
      }
    }

    final primaryResult = await processWithScript(primaryScript);
    if (primaryResult != null) return primaryResult;
    throw Exception('OCR failed for latin recognizer');
  }

  String _fixSpacedLetters(String line) {
    final tokens = line.split(' ');
    final result = <String>[];
    final buffer = StringBuffer();

    for (final token in tokens) {
      if (token.length == 1 && RegExp(r'[A-Za-z0-9]').hasMatch(token)) {
        buffer.write(token);
      } else {
        if (buffer.isNotEmpty) {
          result.add(buffer.toString());
          buffer.clear();
        }
        if (token.isNotEmpty) result.add(token);
      }
    }
    if (buffer.isNotEmpty) result.add(buffer.toString());
    return result.join(' ');
  }

  String _normalizeOcrLine(String line) {
    var cleaned = line.trim();
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');
    cleaned = cleaned.replaceAll('|', 'I');
    cleaned = cleaned.replaceAll(RegExp(r'[~`]+'), '');
    cleaned = cleaned.replaceAll(RegExp(r'[_]{2,}'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'([.,!?;:]){2,}'), r'$1');
    cleaned = cleaned.replaceAll(RegExp(r'\s+([.,!?;:])'), r'$1');
    cleaned = cleaned.replaceAll(RegExp(r'([([{])\s+'), r'$1');
    cleaned = cleaned.replaceAll(RegExp(r'\s+([)\]}])'), r'$1');
    return cleaned.trim();
  }

  bool _isUsefulLine(String line) {
    if (line.isEmpty) return false;

    final letters = RegExp(r'[A-Za-z\u0900-\u097F]').allMatches(line).length;
    if (letters == 0) return false;

    final noise = RegExp(r'[^A-Za-z0-9\u0900-\u097F\s.,!?;:()₹/-]')
        .allMatches(line)
        .length;
    return noise <= (line.length / 3);
  }

  List<String> _buildChunks(String raw) {
    const chunkSize = 3;

    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map(_fixSpacedLetters)
        .map(_normalizeOcrLine)
        .where(_isUsefulLine)
        .toList();

    final chunks = <String>[];
    for (var i = 0; i < lines.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, lines.length);
      chunks.add(lines.sublist(i, end).join('. '));
    }
    return chunks;
  }

  String? _detectCurrencyFromText(String raw) {
    final normalized = raw.toLowerCase().replaceAll('\n', ' ');

    const orderedPatterns = <MapEntry<String, List<String>>>[
      MapEntry('500 rupees', ['₹500', 'rs 500', '500 rupees', '500']),
      MapEntry('200 rupees', ['₹200', 'rs 200', '200 rupees', '200']),
      MapEntry('100 rupees', ['₹100', 'rs 100', '100 rupees', '100']),
      MapEntry('50 rupees', ['₹50', 'rs 50', '50 rupees', '50']),
      MapEntry('20 rupees', ['₹20', 'rs 20', '20 rupees', '20']),
      MapEntry('10 rupees', ['₹10', 'rs 10', '10 rupees', '10']),
    ];

    for (final denomination in orderedPatterns) {
      for (final pattern in denomination.value) {
        final escaped = RegExp.escape(pattern.toLowerCase());
        final expression = RegExp('(^|[^0-9])$escaped([^0-9]|\$)');
        if (expression.hasMatch(normalized)) {
          return denomination.key;
        }
      }
    }

    return null;
  }

  String _formatObjectSummary(List<ImageLabel> labels) {
    final labelTexts = <String>[];

    for (final label in labels) {
      var best = label.label.trim().toLowerCase();

      // Heuristics for common ML Kit base model misclassifications
      if (best == 'musical instrument' || best == 'piano') {
        best = 'laptop or keyboard';
      } else if (best == 'fluid' || best == 'liquid') {
        best = 'bottle';
      } else if (best == 'drink') {
        best = 'bottle or cup';
      }

      if (best.isNotEmpty && !labelTexts.contains(best)) {
        labelTexts.add(best);
      }
    }

    if (labelTexts.isEmpty) {
      return noObjectsStatus;
    }
    if (labelTexts.length == 1) {
      return '$objectsDetectedPrefix: ${labelTexts.first}.';
    }
    if (labelTexts.length == 2) {
      return '$objectsDetectedPrefix: ${labelTexts[0]} and ${labelTexts[1]}.';
    }

    final firstItems = labelTexts.take(labelTexts.length - 1).join(', ');
    return '$objectsDetectedPrefix: $firstItems, and ${labelTexts.last}.';
  }
}
