import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:string_similarity/string_similarity.dart';

import 'services/emergency_service.dart';
import 'services/vision_service.dart';
import 'services/navigation_service.dart';
import 'vision_assist_config.dart';

// ─────────────────────────────────────────────
//  App entry point
// ─────────────────────────────────────────────

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    cameras = [];
    debugPrint('Error fetching cameras: $e');
  }
  runApp(const VisionAssistApp());
}

// ─────────────────────────────────────────────
//  Root widget
// ─────────────────────────────────────────────

class VisionAssistApp extends StatelessWidget {
  const VisionAssistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vision Assist',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          secondary: Color(0xFF03DAC6),
        ),
      ),
      home: const ReadingScreen(),
    );
  }
}

// ─────────────────────────────────────────────
//  Main screen
// ─────────────────────────────────────────────

class ReadingScreen extends StatefulWidget {
  const ReadingScreen({super.key});

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen>
    with SingleTickerProviderStateMixin {
  // Camera
  late CameraController _cameraController;
  late Future<void> _cameraFuture;

  // Speech & TTS
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final VisionService _visionService = VisionService();
  final EmergencyService _emergencyService = EmergencyService();

  // State flags
  bool _isListening = false;
  bool _isProcessing = false;
  bool _isSelectingReadArea = false;
  bool _isNavigationMode = false;
  bool _sttAvailable = false;
  String _statusText = 'Initialising…';
  String _lastWords = '';
  final NavigationService _navigationService = NavigationService();

  // Chunked reading state
  List<String> _textChunks = []; // all sentences/paragraphs from last scan
  int _chunkIndex = 0; // current position
  Rect _selectionRect = const Rect.fromLTWH(0.14, 0.22, 0.72, 0.22);

  // Debounce
  DateTime _lastCommandTime = DateTime(2000);
  static const _debounceDuration = Duration(seconds: 2);

  // Restarter timer (STT stops after ~30 s of silence on Android)
  Timer? _restartTimer;

  // Glow animation
  late AnimationController _glowController;
  late Animation<double> _glowAnim;

  // ── Init ──────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initGlow();
    _initCamera();
    _initTts().then((_) => _initStt());
  }

  void _initGlow() {
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 8, end: 28).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
  }

  void _initCamera() {
    if (cameras.isNotEmpty) {
      _cameraController = CameraController(
        cameras[0],
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup:
            Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21,
      );
      _cameraFuture = _cameraController.initialize().then((_) async {
        await _cameraController.setFlashMode(FlashMode.auto);
        try {
          await _cameraController.setFocusMode(FocusMode.auto);
        } catch (_) {}
        try {
          await _cameraController.setExposureMode(ExposureMode.auto);
        } catch (_) {}
      });
    } else {
      _cameraFuture = Future.error('No camera found');
    }
  }

  Future<void> _initTts() async {
    await _tts.setLanguage(ttsLocale);
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _initStt() async {
    _sttAvailable = await _stt.initialize(
      onError: (e) => debugPrint('STT error: $e'),
      onStatus: (s) {
        debugPrint('STT status: $s');
        // Auto-restart when STT finishes naturally
        if (s == 'done' && _isListening) {
          _scheduleRestart();
        }
      },
    );
    if (_sttAvailable) {
      await _startListening();
      await _speakText(startedMessage);
    } else {
      _setStatus('Microphone not available');
    }
  }

  // ── STT control ───────────────────────────

  Future<void> _startListening() async {
    if (!_sttAvailable || _stt.isListening) return;
    setState(() {
      _isListening = true;
      _setStatus('Listening…');
    });
    await _stt.listen(
      localeId: sttLocale,
      onResult: _onSpeechResult,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
      ),
    );
  }

  void _scheduleRestart() {
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 500), () {
      if (_isListening && mounted) _startListening();
    });
  }

  Future<void> _stopListening() async {
    _restartTimer?.cancel();
    await _stt.stop();
    setState(() {
      _isListening = false;
      _setStatus('Paused');
    });
  }

  // ── Command parsing ────────────────────────

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!result.finalResult) return;

    final words = result.recognizedWords.trim().toLowerCase();
    setState(() => _lastWords = words);

    final now = DateTime.now();
    if (now.difference(_lastCommandTime) < _debounceDuration) return;

    final intent = _getBestIntent(words);

    if (intent == CommandIntent.callEmergency) {
      _lastCommandTime = now;
      _handleEmergencyCallCommand();
    } else if (intent == CommandIntent.emergency) {
      _lastCommandTime = now;
      _handleSOSCommand();
    } else if (intent == CommandIntent.time) {
      _lastCommandTime = now;
      _handleTimeCommand();
    } else if (intent == CommandIntent.date) {
      _lastCommandTime = now;
      _handleDateCommand();
    } else if (intent == CommandIntent.day) {
      _lastCommandTime = now;
      _handleDayCommand();
    } else if (intent == CommandIntent.navOn) {
      _lastCommandTime = now;
      _handleNavigationToggle(true);
    } else if (intent == CommandIntent.navOff) {
      _lastCommandTime = now;
      _handleNavigationToggle(false);
    } else if (intent == CommandIntent.readArea) {
      _lastCommandTime = now;
      _handleReadAreaCommand();
    } else if (intent == CommandIntent.readSelected) {
      _lastCommandTime = now;
      _handleReadSelectedCommand();
    } else if (intent == CommandIntent.detectPrice) {
      _lastCommandTime = now;
      _handlePriceCommand();
    } else if (intent == CommandIntent.detectObjects) {
      _lastCommandTime = now;
      _handleObjectCommand();
    } else if (intent == CommandIntent.detectCurrency) {
      _lastCommandTime = now;
      _handleCurrencyCommand();
    } else if (intent == CommandIntent.read) {
      _lastCommandTime = now;
      _handleReadCommand();
    } else if (intent == CommandIntent.next) {
      _lastCommandTime = now;
      _handleNextCommand();
    } else if (intent == CommandIntent.flashOn) {
      _lastCommandTime = now;
      _handleFlashCommand(true);
    } else if (intent == CommandIntent.flashOff) {
      _lastCommandTime = now;
      _handleFlashCommand(false);
    } else if (intent == CommandIntent.stop) {
      _lastCommandTime = now;
      _handleStopCommand();
    }
  }

  CommandIntent _getBestIntent(String input) {
    if (input.isEmpty) return CommandIntent.none;

    CommandIntent bestIntent = CommandIntent.none;
    double bestScore = 0;

    for (final entry in commandRegistry.entries) {
      for (final variation in entry.value) {
        // Check for exact containment first (high priority)
        if (input.contains(variation)) {
          return entry.key;
        }
        
        // Use string_similarity for fuzzy matching
        final score = input.similarityTo(variation);
        if (score > bestScore) {
          bestScore = score;
          bestIntent = entry.key;
        }
      }
    }

    // Threshold for fuzzy matching (65% similarity)
    if (bestScore > 0.65) {
      return bestIntent;
    }

    return CommandIntent.none;
  }

  Future<void> _handleTimeCommand() async {
    final now = DateTime.now();
    final timeString = DateFormat('h:mm a').format(now);
    final spoken = 'The current time is $timeString.';
    _setStatus(spoken);
    await _speakText(spoken);
  }

  Future<void> _handleDateCommand() async {
    final now = DateTime.now();
    final dateString = DateFormat('MMMM d, y').format(now);
    final spoken = 'Today\'s date is $dateString.';
    _setStatus(spoken);
    await _speakText(spoken);
  }

  Future<void> _handleDayCommand() async {
    final now = DateTime.now();
    final dayString = DateFormat('EEEE').format(now);
    final spoken = 'Today is $dayString.';
    _setStatus(spoken);
    await _speakText(spoken);
  }

  Future<void> _handleNavigationToggle(bool on) async {
    if (_isNavigationMode == on) return;

    setState(() {
      _isNavigationMode = on;
      _setStatus(on ? navStartedStatus : navStoppedStatus);
    });

    await _speakText(on ? navStartedStatus : navStoppedStatus);

    if (on) {
      unawaited(_runNavigationLoop());
    }
  }

  Future<void> _runNavigationLoop() async {
    String lastGuidance = "";
    DateTime lastHeartbeat = DateTime.now();

    while (_isNavigationMode && mounted) {
      if (_isProcessing) {
        await Future.delayed(const Duration(milliseconds: 800));
        continue;
      }

      try {
        await _cameraFuture;
        final image = await _cameraController.takePicture();

        if (!_isNavigationMode || !mounted) {
          final file = File(image.path);
          if (await file.exists()) await file.delete();
          return;
        }

        final objects = await _visionService.detectObjectsRaw(image.path);
        final previewSize = _cameraController.value.previewSize;

        if (previewSize != null) {
          final size = Size(previewSize.height, previewSize.width);
          final guidance =
              _navigationService.analyzeEnvironmentNormalized(objects, size);

          final isClearPath = guidance.contains("Clear path");
          final now = DateTime.now();
          final shouldSpeak = guidance != lastGuidance ||
              (isClearPath &&
                  now.difference(lastHeartbeat) > const Duration(seconds: 10));

          if (_isNavigationMode && mounted && shouldSpeak) {
            _setStatus(guidance);
            await _speakText(guidance);
            lastGuidance = guidance;
            if (isClearPath) lastHeartbeat = now;
          }
        }

        final file = File(image.path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('Navigation loop error: $e');
      }

      await Future.delayed(const Duration(milliseconds: 2000));
    }
  }

  Future<void> _handleReadCommand() async {
    if (_isProcessing) return;
    _textChunks = []; // clear previous scan
    _chunkIndex = 0;
    await _captureAndRead();
  }

  Future<void> _handleReadAreaCommand() async {
    if (_isProcessing) return;
    _textChunks = [];
    _chunkIndex = 0;
    setState(() {
      _isSelectingReadArea = true;
      _setStatus(
        'Read area mode on. Move the box, then say "$readSelectedCmd".',
      );
    });
    await _speakText(
      'Read area mode on. Move the box, then say $readSelectedCmd.',
    );
  }

  Future<void> _handleReadSelectedCommand() async {
    if (_isProcessing || !_isSelectingReadArea) return;
    await _captureAndReadArea();
  }

  Future<void> _handleSOSCommand() async {
    if (_isProcessing) return;

    final prefs = await SharedPreferences.getInstance();
    final number = prefs.getString(emergencyContactKey);

    if (number == null || number.trim().isEmpty) {
      _setStatus(sosConfigStatus);
      await _speakText(sosConfigStatus);
      return;
    }

    setState(() {
      _isProcessing = true;
      _setStatus(sosStatus);
    });

    try {
      await _speakText(sosStatus);
      final success = await _emergencyService.triggerSOS();
      if (success) {
        _setStatus('Emergency alert prepared.');
      } else {
        _setStatus('Failed to prepare emergency alert.');
        await _speakText('Failed to prepare emergency alert.');
      }
    } catch (e) {
      debugPrint('SOS error: $e');
      _setStatus('Error during emergency alert.');
      await _speakText('An error occurred during emergency alert.');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleCurrencyCommand() async {
    if (_isProcessing) return;
    await _detectCurrency();
  }

  Future<void> _handlePriceCommand() async {
    if (_isProcessing) return;
    await _detectPrice();
  }

  Future<void> _handleObjectCommand() async {
    if (_isProcessing) return;
    await _detectObjects();
  }

  Future<void> _handleEmergencyCallCommand() async {
    if (_isProcessing) return;

    final prefs = await SharedPreferences.getInstance();
    final number = prefs.getString(emergencyContactKey);

    if (number == null || number.trim().isEmpty) {
      _setStatus(sosConfigStatus);
      await _speakText(sosConfigStatus);
      return;
    }

    setState(() {
      _isProcessing = true;
      _setStatus(emergencyCallStatus);
    });

    try {
      await _speakText(emergencyCallStatus);
      final success = await _emergencyService.callEmergencyContact();
      if (success) {
        _setStatus('Opening emergency call.');
      } else {
        _setStatus('Failed to start emergency call.');
        await _speakText('Failed to start emergency call.');
      }
    } catch (e) {
      debugPrint('Emergency call error: $e');
      _setStatus('Error during emergency call.');
      await _speakText('An error occurred during emergency calling.');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleNextCommand() async {
    if (_isProcessing) return;
    if (_textChunks.isEmpty) {
      // Nothing scanned yet — do a fresh scan
      await _captureAndRead();
      return;
    }
    if (_chunkIndex >= _textChunks.length) {
      await _speakText('End of text. Say read to scan again.');
      return;
    }
    await _speakChunk();
  }

  Future<void> _handleStopCommand() async {
    await _tts.stop();
    setState(() {
      _isSelectingReadArea = false;
      _isNavigationMode = false;
      _setStatus('Stopped.');
    });
  }

  Future<void> _handleFlashCommand(bool on) async {
    try {
      await _cameraController
          .setFlashMode(on ? FlashMode.torch : FlashMode.off);
      final feedback = on ? flashOnFeedback : flashOffFeedback;
      _setStatus(feedback);
      await _speakText(feedback);
    } catch (e) {
      debugPrint('Flash error: $e');
    }
  }

  Future<void> _speakText(String text) async {
    final wasListening = _isListening;
    if (wasListening) {
      await _stopListening();
    }

    try {
      await _setTtsLanguageForText(text);
      await _tts.stop();
      await _tts.speak(text);
    } finally {
      if (wasListening && mounted) {
        await _startListening();
      }
    }
  }

  // ── OCR pipeline ──────────────────────────

  Future<void> _captureAndRead() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _isSelectingReadArea = false;
      _setStatus(scanStatus);
    });

    try {
      await _speakText(scanStatus);
      await _cameraFuture;

      final image = await _cameraController.takePicture();
      _textChunks = await _visionService.scanReadableChunks(image.path);

      if (_textChunks.isEmpty) {
        _textChunks = [];
        _chunkIndex = 0;
        _setStatus(noTextStatus);
        await _speakText(noTextStatus);
      } else {
        _chunkIndex = 0;
        await _speakChunk();
      }
    } catch (e) {
      debugPrint('OCR error: $e');
      _setStatus('Error during scan.');
      await _speakText('An error occurred while scanning.');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _captureAndReadArea() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _setStatus('Reading selected area');
    });

    try {
      await _speakText('Reading selected area');
      await _cameraFuture;

      final image = await _cameraController.takePicture();
      final selectedText = await _visionService.scanReadableText(
        image.path,
        normalizedCrop: _selectionRectForCapturedImage(),
      );

      if (selectedText.trim().isEmpty) {
        _setStatus(noTextStatus);
        await _speakText(noTextStatus);
      } else {
        _setStatus(selectedText);
        await _speakText(selectedText);
      }
    } catch (e) {
      debugPrint('Area OCR error: $e');
      _setStatus('Error during selected area scan.');
      await _speakText('An error occurred while reading the selected area.');
    } finally {
      setState(() {
        _isProcessing = false;
        _isSelectingReadArea = false;
      });
    }
  }

  Future<void> _detectObjects() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _isSelectingReadArea = false;
      _setStatus(objectScanningStatus);
    });

    try {
      await _speakText(objectScanningStatus);
      await _cameraFuture;

      final image = await _cameraController.takePicture();
      final spoken = await _visionService.detectObjects(image.path);

      _setStatus(spoken);
      await _speakText(spoken);
    } catch (e) {
      debugPrint('Object detection error: $e');
      _setStatus('Error during object detection.');
      await _speakText('An error occurred while detecting objects.');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _detectCurrency() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _isSelectingReadArea = false;
      _setStatus(currencyScanningStatus);
    });

    try {
      await _speakText(currencyScanningStatus);
      await _cameraFuture;

      final image = await _cameraController.takePicture();
      final detectedCurrency = await _visionService.detectCurrency(image.path);
      if (detectedCurrency == null) {
        _setStatus(noCurrencyStatus);
        await _speakText(noCurrencyStatus);
      } else {
        final spoken = '$currencyDetectedPrefix: $detectedCurrency';
        _setStatus(spoken);
        await _speakText(spoken);
      }
    } catch (e) {
      debugPrint('Currency detection error: $e');
      _setStatus('Error during currency detection.');
      await _speakText('An error occurred while detecting currency.');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _detectPrice() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _isSelectingReadArea = false;
      _setStatus(priceScanningStatus);
    });

    try {
      await _speakText(priceScanningStatus);
      await _cameraFuture;

      final image = await _cameraController.takePicture();
      final detectedPrice = await _visionService.detectPriceFromImage(image.path);
      final spoken = detectedPrice == null
          ? noPriceStatus
          : '$priceDetectedPrefix: $detectedPrice.';
      _setStatus(spoken);
      await _speakText(spoken);
    } catch (e) {
      debugPrint('Price detection error: $e');
      _setStatus('Error during price detection.');
      await _speakText('An error occurred while detecting price.');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  /// Reads the current chunk aloud and advances the pointer.
  Future<void> _speakChunk() async {
    if (_chunkIndex >= _textChunks.length) return;
    final chunk = _textChunks[_chunkIndex];
    _chunkIndex++;
    final remaining = _textChunks.length - _chunkIndex;
    final suffix = remaining > 0 ? '. Say next for more.' : '';
    setState(() => _setStatus(chunk));
    await _speakText(chunk + suffix);
  }

  // ── Helpers ───────────────────────────────

  void _setStatus(String s) => _statusText = s;

  Future<void> _setTtsLanguageForText(String text) async {
    final targetLocale = _preferredTtsLocale(text);

    try {
      await _tts.setLanguage(targetLocale);
    } catch (_) {
      if (targetLocale != ttsLocale) {
        await _tts.setLanguage(ttsLocale);
      }
    }
  }

  String _preferredTtsLocale(String text) {
    for (final rune in text.runes) {
      if (_isKannadaRune(rune)) return kannadaTtsLocale;
      if (_isHindiRune(rune)) return hindiTtsLocale;
      if (_isLatinRune(rune)) return ttsLocale;
    }
    return ttsLocale;
  }

  bool _isKannadaRune(int rune) => rune >= 0x0C80 && rune <= 0x0CFF;

  bool _isHindiRune(int rune) => rune >= 0x0900 && rune <= 0x097F;

  bool _isLatinRune(int rune) =>
      (rune >= 0x0041 && rune <= 0x005A) ||
      (rune >= 0x0061 && rune <= 0x007A);

  Rect _selectionRectForCapturedImage() {
    final screenSize = MediaQuery.of(context).size;
    final previewSize = _cameraController.value.previewSize;

    if (previewSize == null) return _selectionRect;

    final previewContentSize = Size(
      previewSize.height,
      previewSize.width,
    );
    final scale = math.max(
      screenSize.width / previewContentSize.width,
      screenSize.height / previewContentSize.height,
    );
    final displayedWidth = previewContentSize.width * scale;
    final displayedHeight = previewContentSize.height * scale;
    final overflowX = (displayedWidth - screenSize.width) / 2;
    final overflowY = (displayedHeight - screenSize.height) / 2;

    final screenRect = Rect.fromLTWH(
      _selectionRect.left * screenSize.width,
      _selectionRect.top * screenSize.height,
      _selectionRect.width * screenSize.width,
      _selectionRect.height * screenSize.height,
    );

    final left =
        ((screenRect.left + overflowX) / displayedWidth).clamp(0.0, 1.0);
    final top =
        ((screenRect.top + overflowY) / displayedHeight).clamp(0.0, 1.0);
    final right =
        ((screenRect.right + overflowX) / displayedWidth).clamp(0.0, 1.0);
    final bottom =
        ((screenRect.bottom + overflowY) / displayedHeight).clamp(0.0, 1.0);

    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _moveSelectionBox(DragUpdateDetails details, Size size) {
    final dx = details.delta.dx / size.width;
    final dy = details.delta.dy / size.height;
    final newLeft = (_selectionRect.left + dx)
        .clamp(0.0, 1.0 - _selectionRect.width);
    final newTop =
        (_selectionRect.top + dy).clamp(0.0, 1.0 - _selectionRect.height);

    setState(() {
      _selectionRect = Rect.fromLTWH(
        newLeft,
        newTop,
        _selectionRect.width,
        _selectionRect.height,
      );
    });
  }

  void _resizeSelectionBox(DragUpdateDetails details, Size size) {
    const minWidth = 0.22;
    const minHeight = 0.10;

    final widthDelta = details.delta.dx / size.width;
    final heightDelta = details.delta.dy / size.height;
    final newWidth = (_selectionRect.width + widthDelta)
        .clamp(minWidth, 1.0 - _selectionRect.left);
    final newHeight = (_selectionRect.height + heightDelta)
        .clamp(minHeight, 1.0 - _selectionRect.top);

    setState(() {
      _selectionRect = Rect.fromLTWH(
        _selectionRect.left,
        _selectionRect.top,
        newWidth,
        newHeight,
      );
    });
  }

  Future<void> _showSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final currentNumber = prefs.getString(emergencyContactKey) ?? '';
    final controller = TextEditingController(text: currentNumber);

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) {
        final navigator = Navigator.of(context);
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E28),
          title: const Text('Settings', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Emergency Contact Number:',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '+1234567890',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Voice commands: say "emergency" to prepare an SOS message or "call emergency" to start a phone call.',
                style: TextStyle(
                  color: Colors.white54,
                  height: 1.4,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                await prefs.setString(
                  emergencyContactKey,
                  controller.text.trim(),
                );
                navigator.pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  // ── Dispose ───────────────────────────────

  @override
  void dispose() {
    _glowController.dispose();
    _restartTimer?.cancel();
    _stt.stop();
    _tts.stop();
    unawaited(_visionService.dispose());
    if (cameras.isNotEmpty) _cameraController.dispose();
    super.dispose();
  }

  // ── UI ────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          // ── Camera preview (full-screen background) ──
          FutureBuilder<void>(
            future: _cameraFuture,
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.done &&
                  !snap.hasError &&
                  cameras.isNotEmpty) {
                return SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: _cameraController.value.previewSize!.height,
                      height: _cameraController.value.previewSize!.width,
                      child: CameraPreview(_cameraController),
                    ),
                  ),
                );
              }
              return Container(color: const Color(0xFF0A0A0F));
            },
          ),

          // ── Subtle gradient — only top/bottom UI bars, camera stays clear ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 130,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.70),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 300,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.92),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          if (_isSelectingReadArea)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: _isProcessing,
                child: _buildSelectionOverlay(size),
              ),
            ),

          // ── Top bar ──
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Vision Assist',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFF6C63FF).withValues(alpha: 0.20),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: const Color(0xFF6C63FF),
                            width: 1.2,
                          ),
                        ),
                        child: const Text(
                          'EN / HI / KN',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.settings, color: Colors.white),
                        onPressed: _showSettingsDialog,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ── Status card + mic button ──
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Status text card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color:
                              const Color(0xFF6C63FF).withValues(alpha: 0.35),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            _isProcessing
                                ? _statusText
                                : _isListening
                                    ? (_lastWords.isEmpty
                                        ? 'Listening…'
                                        : '"$_lastWords"')
                                    : _statusText,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.white70,
                              height: 1.4,
                            ),
                          ),
                          if (_isProcessing) ...[
                            const SizedBox(height: 10),
                            const SizedBox(
                              height: 3,
                              child: LinearProgressIndicator(
                                backgroundColor: Colors.white10,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    Color(0xFF6C63FF)),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Glowing mic button
                    AnimatedBuilder(
                      animation: _glowAnim,
                      builder: (ctx, child) {
                        return GestureDetector(
                          onTap:
                              _isListening ? _stopListening : _startListening,
                          child: Container(
                            width: size.width * 0.30,
                            height: size.width * 0.30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isListening
                                  ? const Color(0xFF6C63FF)
                                  : Colors.white12,
                              boxShadow: _isListening
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF6C63FF)
                                            .withValues(alpha: 0.6),
                                        blurRadius: _glowAnim.value,
                                        spreadRadius: _glowAnim.value * 0.4,
                                      ),
                                    ]
                                  : [],
                            ),
                            child: Icon(
                              _isListening ? Icons.mic : Icons.mic_off,
                              size: size.width * 0.13,
                              color: Colors.white,
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 12),

                    Text(
                      _isListening
                          ? 'Tap to pause • Say "navigation mode on", "$timeCmd", "$dateCmd", "$dayCmd", "$readCmd", or "$objectCmd"'
                          : 'Tap to resume listening',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionOverlay(Size size) {
    final rect = Rect.fromLTWH(
      _selectionRect.left * size.width,
      _selectionRect.top * size.height,
      _selectionRect.width * size.width,
      _selectionRect.height * size.height,
    );

    return Stack(
      children: [
        Positioned.fromRect(
          rect: rect,
          child: GestureDetector(
            onPanUpdate: (details) => _moveSelectionBox(details, size),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFF03DAC6),
                  width: 2,
                ),
                color: Colors.transparent,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: -14,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF03DAC6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Read Area',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Drag to move',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: -10,
                    bottom: -10,
                    child: GestureDetector(
                      onPanUpdate: (details) => _resizeSelectionBox(details, size),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: const Color(0xFF03DAC6),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black, width: 1.2),
                        ),
                        child: const Icon(
                          Icons.open_in_full,
                          size: 15,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
