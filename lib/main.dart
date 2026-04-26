import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/emergency_service.dart';
import 'services/vision_service.dart';
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
  bool _sttAvailable = false;
  String _statusText = 'Initialising…';
  String _lastWords = '';

  // Chunked reading state
  List<String> _textChunks = []; // all sentences/paragraphs from last scan
  int _chunkIndex = 0; // current position

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
        ResolutionPreset.high,
        enableAudio: false,
      );
      _cameraFuture = _cameraController.initialize().then((_) {
        _cameraController.setFlashMode(FlashMode.auto);
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

    final isNext = words.contains('next');
    final isFlashOn = words.contains(flashOnCmd) ||
        words.contains('torch on') ||
        words.contains('light on');
    final isFlashOff = words.contains(flashOffCmd) ||
        words.contains('torch off') ||
        words.contains('light off');

    final isCurrencyDetection = words.contains(currencyCmd) ||
        words.contains('currency detect') ||
        words.contains('detect note') ||
        words.contains('detect money');
    final isObjectDetection = words.contains(objectCmd) ||
        words.contains('detect object') ||
        words.contains('what is around me') ||
        words.contains('what is in front of me') ||
        words.contains('objects around me');
    final isBarcodeScan = words.contains(barcodeCmd) ||
        words.contains('scan barcode') ||
        words.contains('scan price') ||
        words.contains('check price') ||
        words.contains('barcode');
    final isEmergencyCall = words.contains(emergencyCallCmd) ||
        (words.contains('call') &&
            (words.contains('emergency') ||
                words.contains('help') ||
                words.contains('sos')));
    final isSOS = words.contains(sosCmd) ||
        words.contains('help') ||
        words.contains('sos') ||
        words.contains('save me') ||
        words.contains('emergency');

    if (isEmergencyCall) {
      _lastCommandTime = now;
      _handleEmergencyCallCommand();
    } else if (isSOS) {
      _lastCommandTime = now;
      _handleSOSCommand();
    } else if (isBarcodeScan) {
      _lastCommandTime = now;
      _handleBarcodeCommand();
    } else if (isObjectDetection) {
      _lastCommandTime = now;
      _handleObjectCommand();
    } else if (isCurrencyDetection) {
      _lastCommandTime = now;
      _handleCurrencyCommand();
    } else if (words.contains(readCmd)) {
      _lastCommandTime = now;
      _handleReadCommand();
    } else if (isNext) {
      _lastCommandTime = now;
      _handleNextCommand();
    } else if (isFlashOn) {
      _lastCommandTime = now;
      _handleFlashCommand(true);
    } else if (isFlashOff) {
      _lastCommandTime = now;
      _handleFlashCommand(false);
    } else if (words.contains(stopCmd)) {
      _lastCommandTime = now;
      _handleStopCommand();
    }
  }

  Future<void> _handleReadCommand() async {
    if (_isProcessing) return;
    _textChunks = []; // clear previous scan
    _chunkIndex = 0;
    await _captureAndRead();
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

  Future<void> _handleBarcodeCommand() async {
    if (_isProcessing) return;
    await _scanBarcodeAndPrice();
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
    _setStatus('Stopped.');
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

  Future<void> _detectObjects() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
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

  Future<void> _scanBarcodeAndPrice() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _setStatus(barcodeScanningStatus);
    });

    try {
      await _speakText(barcodeScanningStatus);
      await _cameraFuture;

      final image = await _cameraController.takePicture();
      final result = await _visionService.scanBarcodeAndPrice(image.path);
      if (result == null) {
        _setStatus(noBarcodeStatus);
        await _speakText(noBarcodeStatus);
      } else {
        final spoken = result.detectedPrice == null
            ? '$barcodeDetectedPrefix: ${result.code}. Price not found on the package.'
            : '$barcodeDetectedPrefix: ${result.code}. $priceDetectedPrefix: ${result.detectedPrice}.';
        _setStatus(spoken);
        await _speakText(spoken);
      }
    } catch (e) {
      debugPrint('Barcode scan error: $e');
      _setStatus('Error during barcode scan.');
      await _speakText('An error occurred while scanning the barcode.');
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
                          'English',
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
                          ? 'Tap to pause • Say "$readCmd", "$objectCmd", "$currencyCmd", "$barcodeCmd", or "$stopCmd"'
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
}
