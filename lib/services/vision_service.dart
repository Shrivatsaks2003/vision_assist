import 'dart:io';

import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../vision_assist_config.dart';

class BarcodeScanResult {
  const BarcodeScanResult({
    required this.code,
    this.detectedPrice,
  });

  final String code;
  final String? detectedPrice;
}

class VisionService {
  VisionService()
      : _imageLabeler = ImageLabeler(
            options: ImageLabelerOptions(confidenceThreshold: 0.7)),
        _barcodeScanner = BarcodeScanner(),
        _objectDetector = ObjectDetector(
          options: ObjectDetectorOptions(
            mode: DetectionMode.single,
            classifyObjects: true,
            multipleObjects: true,
          ),
        );

  final ImageLabeler _imageLabeler;
  final BarcodeScanner _barcodeScanner;
  final ObjectDetector _objectDetector;

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
    final detectedObjects = await _objectDetector.processImage(inputImage);
    final primaryObjects = _collectDetectedObjects(detectedObjects);

    if (primaryObjects.isNotEmpty) {
      return _formatObjectSummary(primaryObjects);
    }

    final labels = await _imageLabeler.processImage(inputImage);
    final fallbackObjects = _collectFallbackLabels(labels);
    return _formatObjectSummary(fallbackObjects);
  }

  Future<BarcodeScanResult?> scanBarcodeAndPrice(String imagePath) async {
    final inputImage = InputImage.fromFile(File(imagePath));
    final barcodes = await _barcodeScanner.processImage(inputImage);

    final barcodeValue = barcodes
        .map((barcode) =>
            barcode.displayValue?.trim() ?? barcode.rawValue?.trim() ?? '')
        .firstWhere(
          (value) => value.isNotEmpty,
          orElse: () => '',
        );

    if (barcodeValue.isEmpty) {
      return null;
    }

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(inputImage);
      return BarcodeScanResult(
        code: barcodeValue,
        detectedPrice: _extractPriceFromText(result.text),
      );
    } finally {
      await recognizer.close();
    }
  }

  Future<void> dispose() async {
    await _imageLabeler.close();
    await _barcodeScanner.close();
    await _objectDetector.close();
  }

  Future<RecognizedText> _processImage({
    required InputImage inputImage,
    required TextRecognitionScript primaryScript,
  }) async {
    Future<RecognizedText?> processWithScript(
        TextRecognitionScript script) async {
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

  String? _extractPriceFromText(String raw) {
    final normalized = raw.replaceAll('\n', ' ');

    final prioritizedPatterns = <RegExp>[
      RegExp(
        r'(?:mrp|price)\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*(\d{1,5}(?:[.,]\d{1,2})?)',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:rs\.?|inr|₹)\s*(\d{1,5}(?:[.,]\d{1,2})?)',
        caseSensitive: false,
      ),
    ];

    for (final pattern in prioritizedPatterns) {
      final match = pattern.firstMatch(normalized);
      if (match != null) {
        final amount = match.group(1)?.replaceAll(',', '.');
        if (amount != null && amount.isNotEmpty) {
          return '$amount rupees';
        }
      }
    }

    return null;
  }

  List<String> _collectDetectedObjects(List<DetectedObject> objects) {
    final scoredItems = <({String label, double score})>[];

    for (final object in objects) {
      for (final label in object.labels) {
        final best = _normalizeObjectLabel(label.text);
        if (best == null || label.confidence < 0.6) continue;
        scoredItems.add((label: best, score: label.confidence));
      }
    }

    scoredItems.sort((a, b) => b.score.compareTo(a.score));
    return _takeUniqueTopLabels(scoredItems, limit: 4);
  }

  List<String> _collectFallbackLabels(List<ImageLabel> labels) {
    final scoredItems = <({String label, double score})>[];

    for (final label in labels) {
      final best = _normalizeObjectLabel(label.label);
      if (best == null || label.confidence < 0.72) continue;
      scoredItems.add((label: best, score: label.confidence));
    }

    scoredItems.sort((a, b) => b.score.compareTo(a.score));
    return _takeUniqueTopLabels(scoredItems, limit: 3);
  }

  List<String> _takeUniqueTopLabels(
    List<({String label, double score})> scoredItems, {
    required int limit,
  }) {
    final labelTexts = <String>[];

    for (final item in scoredItems) {
      if (!labelTexts.contains(item.label)) {
        labelTexts.add(item.label);
      }
      if (labelTexts.length >= limit) {
        break;
      }
    }

    return labelTexts;
  }

  String? _normalizeObjectLabel(String rawLabel) {
    var best = rawLabel.trim().toLowerCase();

    if (best.isEmpty) return null;

    // Heuristics for common ML Kit base model misclassifications.
    if (best == 'musical instrument' || best == 'piano') {
      best = 'laptop or keyboard';
    } else if (best == 'fluid' || best == 'liquid') {
      best = 'bottle';
    } else if (best == 'drink') {
      best = 'bottle or cup';
    } else if (best == 'packaged goods') {
      best = 'packet or box';
    } else if (best == 'home goods') {
      best = 'household item';
    }

    const rejectedLabels = {
      'product',
      'goods',
      'material',
      'pattern',
      'font',
      'rectangle',
    };

    if (rejectedLabels.contains(best)) {
      return null;
    }

    return best;
  }

  String _formatObjectSummary(List<String> labelTexts) {
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
