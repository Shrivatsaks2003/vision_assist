import 'dart:io';
import 'dart:ui';

import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:image/image.dart' as img;

import '../vision_assist_config.dart';

class VisionService {
  static const double _defaultObjectConfidenceThreshold = 0.6;
  static const double _defaultImageLabelConfidenceThreshold = 0.72;
  static const double _eyewearConfidenceThreshold = 0.45;
  static const String _ocrLanguages = 'eng+kan+hin';

  VisionService()
      : _imageLabeler = ImageLabeler(
            options: ImageLabelerOptions(confidenceThreshold: 0.7)),
        _objectDetector = ObjectDetector(
          options: ObjectDetectorOptions(
            mode: DetectionMode.single,
            classifyObjects: true,
            multipleObjects: true,
          ),
        );

  final ImageLabeler _imageLabeler;
  final ObjectDetector _objectDetector;

  Future<List<String>> scanReadableChunks(
    String imagePath, {
    Rect? normalizedCrop,
  }) async {
    final text = await _extractTextOffline(
      imagePath,
      normalizedCrop: normalizedCrop,
      args: const {
        'psm': '6',
        'preserve_interword_spaces': '1',
      },
    );

    if (text.trim().isEmpty) {
      return const [];
    }

    return _buildChunks(text);
  }

  Future<String> scanReadableText(
    String imagePath, {
    Rect? normalizedCrop,
  }) async {
    final text = await _extractTextOffline(
      imagePath,
      normalizedCrop: normalizedCrop,
      args: const {
        'psm': '6',
        'preserve_interword_spaces': '1',
      },
    );

    final chunks = _buildChunks(text);
    return chunks.join('. ').trim();
  }

  Future<String?> detectCurrency(String imagePath) async {
    final text = await _extractTextOffline(
      imagePath,
      args: const {
        'psm': '6',
      },
    );
    return _detectCurrencyFromText(text);
  }

  Future<String> detectObjects(String imagePath) async {
    final inputImage = InputImage.fromFile(File(imagePath));
    final detectedObjects = await _objectDetector.processImage(inputImage);
    final labels = await _imageLabeler.processImage(inputImage);
    final mergedObjects = _mergeDetectedObjects(
      _collectDetectedObjects(detectedObjects),
      _collectFallbackLabels(labels),
    );
    return _formatObjectSummary(mergedObjects);
  }

  Future<String?> detectPriceFromImage(String imagePath) async {
    final text = await _extractTextOffline(
      imagePath,
      args: const {
        'psm': '11',
        'preserve_interword_spaces': '1',
      },
    );
    return _extractPriceFromText(text);
  }

  Future<void> dispose() async {
    await _imageLabeler.close();
    await _objectDetector.close();
  }

  Future<String> _extractTextOffline(
    String imagePath, {
    Rect? normalizedCrop,
    Map<String, String> args = const {},
  }) async {
    final processedPath = await _buildOcrInputPath(
      imagePath,
      normalizedCrop: normalizedCrop,
    );

    try {
      final text = await FlutterTesseractOcr.extractText(
        processedPath,
        language: _ocrLanguages,
        args: args,
      );

      final normalized = text.trim();
      if (normalized.isNotEmpty) {
        return normalized;
      }

      return FlutterTesseractOcr.extractText(
        processedPath,
        language: 'eng',
        args: args,
      );
    } finally {
      if (processedPath != imagePath) {
        final file = File(processedPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
  }

  Future<String> _buildOcrInputPath(
    String imagePath, {
    Rect? normalizedCrop,
  }) async {
    if (normalizedCrop == null) return imagePath;

    final sourceFile = File(imagePath);
    final originalBytes = await sourceFile.readAsBytes();
    final decoded = img.decodeImage(originalBytes);
    if (decoded == null) return imagePath;

    final cropRect = _safeCropRect(
      normalizedCrop,
      decoded.width,
      decoded.height,
    );

    final cropped = img.copyCrop(
      decoded,
      x: cropRect.left.round(),
      y: cropRect.top.round(),
      width: cropRect.width.round(),
      height: cropRect.height.round(),
    );

    final tempFile = File(
      '${Directory.systemTemp.path}/vision_assist_crop_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await tempFile.writeAsBytes(img.encodeJpg(cropped, quality: 95));
    return tempFile.path;
  }

  Rect _safeCropRect(Rect normalizedCrop, int imageWidth, int imageHeight) {
    // Keep side/top crops tight, but preserve the lower edge so the last line
    // is not clipped.
    final tightened = Rect.fromLTRB(
      (normalizedCrop.left + 0.005).clamp(0.0, 1.0),
      (normalizedCrop.top + 0.010).clamp(0.0, 1.0),
      (normalizedCrop.right - 0.005).clamp(0.0, 1.0),
      normalizedCrop.bottom.clamp(0.0, 1.0),
    );

    final left = (tightened.left * imageWidth).clamp(0.0, imageWidth - 1.0);
    final top = (tightened.top * imageHeight).clamp(0.0, imageHeight - 1.0);
    final right =
        ((tightened.left + tightened.width) * imageWidth).clamp(left + 1.0, imageWidth.toDouble());
    final bottom =
        ((tightened.top + tightened.height) * imageHeight).clamp(top + 1.0, imageHeight.toDouble());

    return Rect.fromLTRB(left, top, right, bottom);
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

    final letters =
        RegExp(r'[A-Za-z\u0900-\u097F\u0C80-\u0CFF]').allMatches(line).length;
    if (letters == 0) return false;

    final noise = RegExp(r'[^A-Za-z0-9\u0900-\u097F\u0C80-\u0CFF\s.,!?;:()₹/-]')
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
    final lines = raw
        .split('\n')
        .map(_normalizePriceOcrLine)
        .where((line) => line.isNotEmpty)
        .toList();

    final candidates = <({String amount, int score})>[];

    for (final line in lines) {
      candidates.addAll(_extractPriceCandidates(line));
    }

    if (candidates.isEmpty) {
      final flattened = _normalizePriceOcrLine(raw.replaceAll('\n', ' '));
      candidates.addAll(_extractPriceCandidates(flattened));
    }

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) => b.score.compareTo(a.score));
    return '${candidates.first.amount} rupees';
  }

  String _normalizePriceOcrLine(String line) {
    var cleaned = _normalizeOcrLine(_fixSpacedLetters(line));
    cleaned = cleaned.replaceAll(
      RegExp(r'\brs\s*[/\\]\s*', caseSensitive: false),
      'Rs ',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'\brs\s*\.?\s*', caseSensitive: false),
      'Rs ',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'\binr\s*', caseSensitive: false),
      'INR ',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');
    return cleaned.trim();
  }

  List<({String amount, int score})> _extractPriceCandidates(String line) {
    final candidates = <({String amount, int score})>[];
    final lower = line.toLowerCase();

    final patterns = <({RegExp pattern, int scoreBoost})>[
      (
        pattern: RegExp(
          r'(?:max\s+retail\s+price|m\.?r\.?p\.?)\s*(?:incl(?:usive)?\.?\s*of\s*all\s*taxes?)?\s*[:=\-]?\s*(?:rs|inr|₹)?\s*(\d{1,5}(?:[.,]\d{1,2})?)',
          caseSensitive: false,
        ),
        scoreBoost: 100,
      ),
      (
        pattern: RegExp(
          r'(?:price|amount)\s*[:=\-]?\s*(?:rs|inr|₹)\s*(\d{1,5}(?:[.,]\d{1,2})?)',
          caseSensitive: false,
        ),
        scoreBoost: 75,
      ),
      (
        pattern: RegExp(
          r'(?:rs|inr|₹)\s*(\d{1,5}(?:[.,]\d{1,2})?)',
          caseSensitive: false,
        ),
        scoreBoost: 45,
      ),
    ];

    for (final entry in patterns) {
      for (final match in entry.pattern.allMatches(line)) {
        final amount = _sanitizePriceAmount(match.group(1));
        if (amount == null) continue;

        var score = entry.scoreBoost;
        if (lower.contains('mrp') || lower.contains('max retail price')) {
          score += 30;
        }
        if (lower.contains('inclusive of all taxes') ||
            lower.contains('incl of all taxes')) {
          score += 10;
        }
        if (line.contains('₹') || lower.contains('rs ') || lower.contains('inr ')) {
          score += 10;
        }

        candidates.add((amount: amount, score: score));
      }
    }

    return candidates;
  }

  String? _sanitizePriceAmount(String? rawAmount) {
    if (rawAmount == null) return null;

    var amount = rawAmount.trim();
    if (amount.isEmpty) return null;

    amount = amount.replaceAll(',', '.');
    amount = amount.replaceAll(RegExp(r'[^0-9.]'), '');
    if (amount.isEmpty) return null;

    if ('.'.allMatches(amount).length > 1) {
      final firstDot = amount.indexOf('.');
      amount =
          '${amount.substring(0, firstDot + 1)}${amount.substring(firstDot + 1).replaceAll('.', '')}';
    }

    final value = double.tryParse(amount);
    if (value == null || value <= 0 || value > 100000) {
      return null;
    }

    if (amount.endsWith('.0') || amount.endsWith('.00')) {
      amount = value.toStringAsFixed(0);
    }

    return amount;
  }

  List<String> _collectDetectedObjects(List<DetectedObject> objects) {
    final scoredItems = <({String label, double score})>[];

    for (final object in objects) {
      for (final label in object.labels) {
        final best = _normalizeObjectLabel(label.text);
        if (best == null ||
            label.confidence < _minimumConfidenceForLabel(
              label: best,
              defaultThreshold: _defaultObjectConfidenceThreshold,
            )) {
          continue;
        }
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
      if (best == null ||
          label.confidence < _minimumConfidenceForLabel(
            label: best,
            defaultThreshold: _defaultImageLabelConfidenceThreshold,
          )) {
        continue;
      }
      scoredItems.add((label: best, score: label.confidence));
    }

    scoredItems.sort((a, b) => b.score.compareTo(a.score));
    return _takeUniqueTopLabels(scoredItems, limit: 3);
  }

  List<String> _mergeDetectedObjects(
    List<String> primaryObjects,
    List<String> fallbackObjects,
  ) {
    final merged = <String>[];

    for (final label in [...primaryObjects, ...fallbackObjects]) {
      if (!merged.contains(label)) {
        merged.add(label);
      }
      if (merged.length >= 4) {
        break;
      }
    }

    return merged;
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
    } else if (_isEyewearLabel(best)) {
      best = 'glasses';
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

  double _minimumConfidenceForLabel({
    required String label,
    required double defaultThreshold,
  }) {
    if (_isEyewearLabel(label)) {
      return _eyewearConfidenceThreshold;
    }
    return defaultThreshold;
  }

  bool _isEyewearLabel(String label) {
    return label.contains('glasses') ||
        label.contains('eyeglasses') ||
        label.contains('spectacles') ||
        label.contains('sunglasses') ||
        label.contains('goggles') ||
        label.contains('eyewear');
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
