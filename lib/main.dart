import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert'; // Import for json decoding
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => NoteProvider()),
        ChangeNotifierProvider(create: (_) => RecordingProvider()),
      ],
      child: const VoiceNotesApp(),
    ),
  );
}

// --- State Management ---

class ThemeProvider with ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.light;
  ThemeMode get themeMode => _themeMode;

  ThemeProvider() {
    _loadTheme();
  }

  void _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('isDarkMode') ?? false;
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', mode == ThemeMode.dark);
    notifyListeners();
  }
}

class NoteProvider with ChangeNotifier {
  // Original
  String _rawTranscript = 'Record a new note from the Home screen.';
  String _cleanedTranscript = 'Your cleaned note will appear here.';
  String _polishedTranscript = 'Your polished note will appear here.';

  // --- NEW: Translated Texts ---
  String _rawTranscriptTranslated = '';
  String _cleanedTranscriptTranslated = '';
  String _polishedTranscriptTranslated = '';

  String get rawTranscript => _rawTranscript;
  String get cleanedTranscript => _cleanedTranscript;
  String get polishedTranscript => _polishedTranscript;

  // --- NEW: Getters for Translated Texts ---
  String get rawTranscriptTranslated => _rawTranscriptTranslated;
  String get cleanedTranscriptTranslated => _cleanedTranscriptTranslated;
  String get polishedTranscriptTranslated => _polishedTranscriptTranslated;

  // --- NEW: Re-polishing state ---
  bool _isPolishing = false;
  bool get isPolishing => _isPolishing;

  void setPolishing(bool value) {
    _isPolishing = value;
    notifyListeners();
  }

  /// Updates the polished note AND clears the polishing flag in a single notification
  /// to prevent a double-rebuild race that caused the UI to appear "stuck".
  void updatePolishedNoteAndFinish(String newNote) {
    _polishedTranscript = newNote;
    _isPolishing = false;
    notifyListeners();
  }

  void updatePolishedNote(String newNote) {
    _polishedTranscript = newNote;
    notifyListeners();
  }

  void updateRawTranscript(String value) {
    _rawTranscript = value;
    notifyListeners();
  }

  void updateCleanedTranscript(String value) {
    _cleanedTranscript = value;
    notifyListeners();
  }

  void updateTranscripts(Map<String, String> transcripts) {
    // Update original transcripts
    _rawTranscript = transcripts['rawTranscript'] ?? 'No raw transcript available.';
    _cleanedTranscript = transcripts['cleanedTranscript'] ?? 'No cleaned transcript available.';
    _polishedTranscript = transcripts['polishedNote'] ?? 'No polished note available.';

    // --- NEW: Update translated transcripts IF they exist in the map ---
    _rawTranscriptTranslated = transcripts['raw_translated'] ?? '';
    _cleanedTranscriptTranslated = transcripts['cleaned_translated'] ?? '';
    _polishedTranscriptTranslated = transcripts['polished_translated'] ?? '';

    notifyListeners();
  }
}

class RecordingProvider with ChangeNotifier {
  AudioRecorder? _recorder;
  StreamSubscription? _recorderSubscription;
  Timer? _durationTimer;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  bool _isSessionActive = false;
  bool get isSessionActive => _isSessionActive;

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  bool _isPaused = false;
  bool get isPaused => _isPaused;

  String? _audioPath;
  String? get audioPath => _audioPath;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  double _decibelLevel = -120.0;
  double get decibelLevel => _decibelLevel;

  RecordingProvider() {
    _initRecorder();
  }

  Future<void> _initRecorder() async {
    print("DEBUG: Initializing recorder permissions...");
    final status = await ph.Permission.microphone.request();
    if (status != ph.PermissionStatus.granted) {
      print("DEBUG: Microphone permission NOT granted");
      return;
    }
    
    // Test if we can create one
    _recorder = AudioRecorder();
    _isInitialized = true;
    print("DEBUG: Recorder initialized");
    notifyListeners();
  }

  void _startTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _duration += const Duration(milliseconds: 100);
      notifyListeners();
    });
  }

  void _startDecibelSubscription() {
    _recorderSubscription?.cancel();
    if (_recorder == null) return;
    
    _recorderSubscription = _recorder!.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((amp) {
      _decibelLevel = amp.current;
      notifyListeners();
    });
  }

  Future<void> startRecording() async {
    print("DEBUG: starting session...");
    if (!_isInitialized) {
      await _initRecorder();
      if (!_isInitialized) return;
    }

    try {
      // 1. Force cleanup of old instance to fix "Stream already listened to"
      await _recorderSubscription?.cancel();
      await _recorder?.dispose();
      _recorder = AudioRecorder(); // FRESH INSTANCE

      if (await ph.Permission.microphone.isGranted) {
        Directory tempDir = await getTemporaryDirectory();
        _audioPath = '${tempDir.path}/voice_note_${DateTime.now().millisecondsSinceEpoch}.m4a';

        print("DEBUG: Starting recording to $_audioPath");
        
        final config = RecordConfig(
          encoder: AudioEncoder.aacLc,  // AAC = ~10x smaller than WAV
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 64000, // 64kbps is plenty for voice
        );

        await _recorder!.start(config, path: _audioPath!);
        
        _isRecording = true;
        _isSessionActive = true;
        _isPaused = false;
        _duration = Duration.zero;
        
        _startTimer();
        _startDecibelSubscription();
        
        print("DEBUG: Recorder started successfully");
        notifyListeners();
      } else {
        print("DEBUG: No permission");
      }
    } catch (e) {
      print("DEBUG: Error starting recorder: $e");
      _isRecording = false;
      _isSessionActive = false;
      notifyListeners();
    }
  }

  Future<void> pauseRecording() async {
    try {
      if (_recorder != null && await _recorder!.isRecording()) {
        await _recorder!.pause();
        _isPaused = true;
        _isRecording = false;
        _durationTimer?.cancel();
        notifyListeners();
      }
    } catch (e) {
      print("DEBUG: Error pausing: $e");
    }
  }

  Future<void> resumeRecording() async {
    try {
      if (_recorder != null && await _recorder!.isPaused()) {
        await _recorder!.resume();
        _isPaused = false;
        _isRecording = true;
        _startTimer();
        notifyListeners();
      }
    } catch (e) {
      print("DEBUG: Error resuming: $e");
    }
  }

  Future<String?> stopRecording() async {
    print("DEBUG: stopRecording signal...");
    try {
      _durationTimer?.cancel();
      await _recorderSubscription?.cancel();
      _recorderSubscription = null;

      String? path;
      if (_recorder != null) {
        if (await _recorder!.isRecording() || await _recorder!.isPaused()) {
          path = await _recorder!.stop();
        }
        await _recorder!.dispose();
        _recorder = null;
      }
      
      _isRecording = false;
      _isSessionActive = false;
      _isPaused = false;
      _duration = Duration.zero;
      _decibelLevel = -120.0;
      
      print("DEBUG: Final Stop. Path: $path");
      notifyListeners();
      return path;
    } catch (e) {
      print("DEBUG: Error stopping: $e");
      _isRecording = false;
      _isSessionActive = false;
      return null;
    }
  }

  Future<void> cancelRecording() async {
    print("DEBUG: cancelRecording...");
    try {
      _durationTimer?.cancel();
      await _recorderSubscription?.cancel();
      _recorderSubscription = null;

      if (_recorder != null) {
        await _recorder!.stop();
        await _recorder!.dispose();
        _recorder = null;
      }
      
      _isRecording = false;
      _isSessionActive = false;
      _isPaused = false;
      _audioPath = null;
      _duration = Duration.zero;
      _decibelLevel = -120.0;
      notifyListeners();
    } catch (e) {
      print("DEBUG: Error canceling: $e");
    }
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _recorderSubscription?.cancel();
    _recorder?.dispose();
    super.dispose();
  }
}

// --- Main Application Widget ---
class VoiceNotesApp extends StatelessWidget {
  const VoiceNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Notes App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: Colors.red,
        scaffoldBackgroundColor: Colors.grey.shade100,
        appBarTheme: AppBarTheme(
          elevation: 0,
          backgroundColor: Colors.grey.shade100,
          foregroundColor: Colors.black,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.red,
      ),
      themeMode: Provider.of<ThemeProvider>(context).themeMode,
      home: const MainScreen(),
    );
  }
}

// --- Screens ---

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  void _onNoteProcessed() {
    setState(() {
      _selectedIndex = 1;
    });
  }

  void _navigateToSettings() {
    setState(() {
      _selectedIndex = 2;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> widgetOptions = <Widget>[
      HomePage(onNoteProcessed: _onNoteProcessed, onNavigateToSettings: _navigateToSettings),
      const NotePage(),
      const SettingsPage(),
    ];

    return Scaffold(
      body: Center(
        child: widgetOptions.elementAt(_selectedIndex),
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.note_alt_outlined),
            label: 'Notes',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.red,
        onTap: _onItemTapped,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final VoidCallback onNoteProcessed;
  final VoidCallback onNavigateToSettings;
  const HomePage({super.key, required this.onNoteProcessed, required this.onNavigateToSettings});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  String _selectedMicrophone = 'Built-in';
  List<String> _availableMicrophones = ['Built-in'];

  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _textAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _textAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _loadAvailableMicrophones();
  }

  Future<void> _pickAndUploadAudio() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'm4a', 'aac', 'ogg'],
    );
    if (result != null && result.files.single.path != null) {
      String path = result.files.single.path!;
      if (mounted) {
        final noteProvider = Provider.of<NoteProvider>(context, listen: false);
        final transcripts = await Navigator.push<Map<String, String>>(
          context,
          MaterialPageRoute(builder: (context) => TranscribePage(audioPath: path)),
        );
        if (transcripts != null) {
          noteProvider.updateTranscripts(transcripts);
          widget.onNoteProcessed();
        }
      }
    }
  }

  Future<void> _loadAvailableMicrophones() async {
    // Note: This is a simplified implementation. In a real app, you would use
    // platform-specific code to get actual microphone devices
    setState(() {
      _availableMicrophones = [
        'Built-in',
        'Bluetooth Headset',
        'USB Microphone',
        'External Mic',
      ];
    });
  }

  void _showMicrophoneSelector() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select Microphone',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ..._availableMicrophones
                  .map((mic) => ListTile(
                        title: Text(mic),
                        leading: Radio<String>(
                          value: mic,
                          groupValue: _selectedMicrophone,
                          onChanged: (String? value) {
                            if (value != null) {
                              setState(() {
                                _selectedMicrophone = value;
                              });
                              Navigator.pop(context);
                            }
                          },
                          activeColor: Colors.red,
                        ),
                        onTap: () {
                          setState(() {
                            _selectedMicrophone = mic;
                          });
                          Navigator.pop(context);
                        },
                      ))
                  .toList(),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _stopAndProcessRecording(RecordingProvider recorder) async {
    if (!recorder.isInitialized || !recorder.isSessionActive) return;

    final duration = recorder.duration;
    _animationController.reverse();
    await recorder.stopRecording();

    if (duration.inMilliseconds < 1000) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording too short. Please record for at least 1 second.')),
        );
      }
      return;
    }

    if (recorder.audioPath != null && mounted) {
      final noteProvider = Provider.of<NoteProvider>(context, listen: false);
      final transcripts = await Navigator.push<Map<String, String>>(
        context,
        MaterialPageRoute(builder: (context) => TranscribePage(audioPath: recorder.audioPath!)),
      );
      if (transcripts != null) {
        noteProvider.updateTranscripts(transcripts);
        widget.onNoteProcessed();
      }
    }
  }

  Future<void> _checkAndStart(RecordingProvider recorder) async {
    if (!recorder.isInitialized) return;
    // Direct cloud architecture: no server health check needed.
    _animationController.forward();
    await recorder.startRecording();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkMode = theme.brightness == Brightness.dark;

    return Consumer<RecordingProvider>(
      builder: (context, recorder, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('New Note'),
            centerTitle: true,
          ),
          body: Stack(
            children: [
              if (!recorder.isSessionActive) const ParticleBackground(),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDarkMode ? [Colors.grey[900]!, Colors.grey[850]!] : [Colors.grey.shade100, Colors.white],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      _buildMicrophoneSelector('Microphone', _selectedMicrophone),
                      const Spacer(),
                      Text(
                        _formatDuration(recorder.duration),
                        style: TextStyle(fontSize: 60, fontWeight: FontWeight.w200, color: theme.colorScheme.onSurface),
                      ),
                      SizedBox(
                        height: 150,
                        child: recorder.isSessionActive
                            ? AudioWaveformVisualizer(
                                decibelLevel: recorder.decibelLevel,
                                isPaused: recorder.isPaused,
                              )
                            : Center(
                                child: AnimatedBuilder(
                                  animation: _textAnimation,
                                  builder: (context, child) {
                                    return Opacity(
                                      opacity: _textAnimation.value,
                                      child: Text(
                                        "Ready to Record",
                                        style: TextStyle(color: Colors.grey.shade500, fontSize: 18),
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),
                      const Spacer(),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (child, animation) {
                          return ScaleTransition(scale: animation, child: child);
                        },
                        child: recorder.isSessionActive
                            ? Row(
                                key: const ValueKey('active_controls'),
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  GestureDetector(
                                    onTap: () => _stopAndProcessRecording(recorder),
                                    child: Container(
                                      padding: const EdgeInsets.all(25),
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.red,
                                      ),
                                      child: const Icon(Icons.stop, color: Colors.white, size: 40),
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  if (recorder.isPaused)
                                    IconButton(
                                      icon: const Icon(Icons.play_arrow),
                                      iconSize: 40,
                                      onPressed: recorder.resumeRecording,
                                      color: theme.colorScheme.onSurface,
                                    )
                                  else
                                    IconButton(
                                      icon: const Icon(Icons.pause),
                                      iconSize: 40,
                                      onPressed: recorder.pauseRecording,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                ],
                              )
                            : GestureDetector(
                                key: const ValueKey('idle_button'),
                                onTap: () => _checkAndStart(recorder),
                                child: Container(
                                  padding: const EdgeInsets.all(25),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.red,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.red.withOpacity(_pulseAnimation.value * 0.6),
                                        spreadRadius: 5 + 15 * _pulseAnimation.value,
                                        blurRadius: 10 + 30 * _pulseAnimation.value,
                                      )
                                    ],
                                  ),
                                  child: const Icon(Icons.mic, color: Colors.white, size: 40),
                                ),
                              ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: recorder.isSessionActive
                              ? TextButton(
                                  key: const ValueKey('cancel_button'),
                                  onPressed: recorder.cancelRecording,
                                  child: const Text('Cancel', style: TextStyle(fontSize: 16)),
                                  style: TextButton.styleFrom(
                                    foregroundColor: theme.textTheme.bodyLarge?.color,
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  ),
                                )
                              : TextButton.icon(
                                  key: const ValueKey('upload_button'),
                                  onPressed: _pickAndUploadAudio,
                                  icon: const Icon(Icons.upload_file),
                                  label: const Text('Upload .wav file'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: theme.textTheme.bodyLarge?.color,
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMicrophoneSelector(String title, String value) {
    return ListTile(
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(color: Colors.grey)),
          const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
        ],
      ),
      onTap: _showMicrophoneSelector,
    );
  }
}

class ParticleBackground extends StatefulWidget {
  const ParticleBackground({super.key});

  @override
  State<ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<ParticleBackground> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<Particle> _particles = [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _controller.addListener(_updateParticles);
    _generateParticles();
  }

  void _generateParticles() {
    final random = math.Random();
    _particles = List.generate(
        50,
        (_) => Particle(
              x: random.nextDouble(),
              y: random.nextDouble(),
              vx: (random.nextDouble() - 0.5) * 0.002,
              vy: (random.nextDouble() - 0.5) * 0.002,
              size: random.nextDouble() * 4 + 2,
              color: Colors.red.withOpacity(random.nextDouble() * 0.3 + 0.1),
            ));
  }

  void _updateParticles() {
    setState(() {
      for (var particle in _particles) {
        particle.x += particle.vx;
        particle.y += particle.vy;
        if (particle.x < 0 || particle.x > 1) particle.vx = -particle.vx;
        if (particle.y < 0 || particle.y > 1) particle.vy = -particle.vy;
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: ParticlePainter(particles: _particles),
      size: Size.infinite,
    );
  }
}

class Particle {
  double x;
  double y;
  double vx;
  double vy;
  double size;
  Color color;

  Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.color,
  });
}

class ParticlePainter extends CustomPainter {
  final List<Particle> particles;

  ParticlePainter({required this.particles});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var particle in particles) {
      paint.color = particle.color;
      canvas.drawCircle(
        Offset(particle.x * size.width, particle.y * size.height),
        particle.size,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class AudioWaveformVisualizer extends StatefulWidget {
  final double decibelLevel;
  final bool isPaused;
  const AudioWaveformVisualizer({
    super.key,
    required this.decibelLevel,
    this.isPaused = false,
  });

  @override
  State<AudioWaveformVisualizer> createState() => _AudioWaveformVisualizerState();
}

class _AudioWaveformVisualizerState extends State<AudioWaveformVisualizer> {
  List<double> _waveforms = [];
  final int _maxWaveforms = 100;
  Timer? _scrollTimer;

  double _lastDecibel = 0.0;
  bool _hasNewData = false;

  @override
  void initState() {
    super.initState();
    _waveforms = List.generate(_maxWaveforms, (_) => 0.0, growable: true);
    _startScrolling();
  }

  @override
  void didUpdateWidget(covariant AudioWaveformVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.decibelLevel != oldWidget.decibelLevel) {
      final double normalized = (widget.decibelLevel.clamp(-120.0, 0.0) + 120) / 120;

      _lastDecibel = normalized;
      _hasNewData = true;
    }
  }

  void _startScrolling() {
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 75), (timer) {
      if (widget.isPaused) {
        return;
      }
      if (mounted) {
        setState(() {
          if (_hasNewData) {
            _waveforms.add(_lastDecibel);
            _hasNewData = false;
          } else {
            _waveforms.add(0.0);
          }

          if (_waveforms.length > _maxWaveforms) {
            _waveforms.removeAt(0);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: WaveformPainter(
        waveforms: _waveforms,
      ),
      size: const Size(double.infinity, 100),
    );
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> waveforms;

  WaveformPainter({required this.waveforms});

  @override
  void paint(Canvas canvas, Size size) {
    if (waveforms.length < 2) return;

    final paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, -size.height / 2),
        Offset(0, size.height / 2),
        [Colors.red.shade400, Colors.red.shade700],
      )
      ..style = PaintingStyle.fill;

    final path = Path();
    final barWidth = size.width / (waveforms.length - 1);

    path.moveTo(0, size.height / 2);

    for (int i = 0; i < waveforms.length - 1; i++) {
      final waveform = waveforms[i];
      final nextWaveform = waveforms[i + 1];

      final barHeight = (waveform * size.height * 0.8).clamp(2.0, size.height);
      final nextBarHeight = (nextWaveform * size.height * 0.8).clamp(2.0, size.height);

      final x1 = i * barWidth;
      final y1 = size.height / 2 - barHeight / 2;

      final x2 = (i + 1) * barWidth;
      final y2 = size.height / 2 - nextBarHeight / 2;

      final midX = (x1 + x2) / 2;
      final midY = (y1 + y2) / 2;

      path.quadraticBezierTo(x1, y1, midX, midY);
    }

    final lastX = size.width;
    final lastY = size.height / 2 - (waveforms.last * size.height * 0.8).clamp(2.0, size.height) / 2;
    path.lineTo(lastX, lastY);
    path.lineTo(lastX, size.height / 2);

    for (int i = waveforms.length - 2; i >= 0; i--) {
      final waveform = waveforms[i];
      final nextWaveform = waveforms[i + 1];

      final barHeight = (waveform * size.height * 0.8).clamp(2.0, size.height);
      final nextBarHeight = (nextWaveform * size.height * 0.8).clamp(2.0, size.height);

      final x1 = i * barWidth;
      final y1 = size.height / 2 + barHeight / 2;

      final x2 = (i + 1) * barWidth;
      final y2 = size.height / 2 + nextBarHeight / 2;

      final midX = (x1 + x2) / 2;
      final midY = (y1 + y2) / 2;

      path.quadraticBezierTo(x2, y2, midX, midY);
    }

    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class NotePage extends StatefulWidget {
  const NotePage({super.key});

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _showTranslated = false;
  bool _isEditing = false; // Toggle between view (Markdown/Text) and edit (TextField)

  // --- Controllers for editable transcript fields ---
  final TextEditingController _rawController = TextEditingController();
  final TextEditingController _cleanedController = TextEditingController();
  final TextEditingController _polishedController = TextEditingController();

  // Track last-synced values to avoid cursor-jump on every rebuild
  String _lastRaw = '';
  String _lastCleaned = '';
  String _lastPolished = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = Provider.of<NoteProvider>(context, listen: false);
    _syncControllers(provider);
  }

  void _syncControllers(NoteProvider provider) {
    final raw = _showTranslated ? provider.rawTranscriptTranslated : provider.rawTranscript;
    final cleaned = _showTranslated ? provider.cleanedTranscriptTranslated : provider.cleanedTranscript;
    final polished = _showTranslated ? provider.polishedTranscriptTranslated : provider.polishedTranscript;

    if (raw != _lastRaw) {
      _lastRaw = raw;
      _rawController.text = raw;
    }
    if (cleaned != _lastCleaned) {
      _lastCleaned = cleaned;
      _cleanedController.text = cleaned;
    }
    if (polished != _lastPolished) {
      _lastPolished = polished;
      _polishedController.text = polished;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _rawController.dispose();
    _cleanedController.dispose();
    _polishedController.dispose();
    super.dispose();
  }

  // --- MODIFIED: The entire build method for the new UI ---
  @override
  Widget build(BuildContext context) {
    return Consumer<NoteProvider>(
      builder: (context, noteProvider, child) {
        // Sync controllers every time provider rebuilds
        _syncControllers(noteProvider);
        final bool hasTranslation = noteProvider.rawTranscriptTranslated.isNotEmpty;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Note'),
            centerTitle: true,
            actions: [
              // --- Try Again with Another Model ---
              IconButton(
                icon: const Icon(Icons.auto_awesome),
                tooltip: 'Try Again with Another Model',
                onPressed: noteProvider.isPolishing
                    ? null
                    : () => _showTryAgainSheet(context, noteProvider),
              ),
              if (hasTranslation)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Row(
                    children: [
                      Text(_showTranslated ? "Trans" : "Orig"),
                      Switch(
                        value: _showTranslated,
                        onChanged: (value) {
                          setState(() {
                            _showTranslated = value;
                          });
                        },
                        activeColor: Colors.red,
                      ),
                    ],
                  ),
                ),
            ],
            bottom: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Raw Transcript'),
                Tab(text: 'Cleaned'),
                Tab(text: 'Polished Note'),
              ],
              indicatorColor: Colors.red,
              labelColor: Colors.red,
              unselectedLabelColor: Colors.grey,
            ),
          ),
          body: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      // Tab 0: Raw Transcript
                      _isEditing
                          ? _buildEditableCard(context, _rawController, onChanged: (v) { _lastRaw = v; noteProvider.updateRawTranscript(v); })
                          : _buildReadCard(context, _rawController.text, isMarkdown: false),
                      // Tab 1: Cleaned
                      _isEditing
                          ? _buildEditableCard(context, _cleanedController, onChanged: (v) { _lastCleaned = v; noteProvider.updateCleanedTranscript(v); })
                          : _buildReadCard(context, _cleanedController.text, isMarkdown: false),
                      // Tab 2: Polished Note (Markdown rendered)
                      _isEditing
                          ? _buildEditableCard(context, _polishedController, onChanged: (v) { _lastPolished = v; noteProvider.updatePolishedNote(v); })
                          : _buildReadCard(context, _polishedController.text, isMarkdown: true),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // --- Bottom Action Bar: Copy + Edit/Save ---
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            final tab = _tabController.index;
                            String text = tab == 0
                                ? noteProvider.rawTranscript
                                : tab == 1
                                    ? noteProvider.cleanedTranscript
                                    : noteProvider.polishedTranscript;
                            
                            // Strip markdown and formatting symbols from Polished Note
                            if (tab == 2) {
                              text = text.replaceAll(RegExp(r'[*#_`/\\]'), '');
                              text = text.replaceAll(RegExp(r'^\s*-\s*', multiLine: true), '');
                            }

                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied!')),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                            minimumSize: const Size(0, 50),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _isEditing
                            ? ElevatedButton.icon(
                                onPressed: () => setState(() => _isEditing = false),
                                icon: const Icon(Icons.check, size: 18),
                                label: const Text('Save'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                                  minimumSize: const Size(0, 50),
                                ),
                              )
                            : ElevatedButton.icon(
                                onPressed: () => setState(() => _isEditing = true),
                                icon: const Icon(Icons.edit, size: 18),
                                label: const Text('Edit'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                                  minimumSize: const Size(0, 50),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- Try Again with Groq Brain Model ---
  void _showTryAgainSheet(BuildContext context, NoteProvider provider) {
    String _sheetModel = 'llama-3.3-70b-versatile';
    SharedPreferences.getInstance().then((prefs) {
      _sheetModel = prefs.getString('groq_llm_model') ?? 'llama-3.3-70b-versatile';
    });

    final List<String> models = [
      'llama-3.3-70b-versatile',
      'llama-3.1-8b-instant',
      'meta-llama/llama-4-scout-17b-16e-instruct',
      'qwen/qwen3-32b',
      'mixtral-8x7b-32768',
      'gemma2-9b-it',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Try Again with Groq Brain Model',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: models.contains(_sheetModel) ? _sheetModel : models.first,
                    decoration: InputDecoration(
                      labelText: 'Select Brain Model',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    items: models
                        .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                        .toList(),
                    onChanged: (v) => setSheetState(() => _sheetModel = v!),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.send),
                      label: const Text('Re-polish with this Brain'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red, foregroundColor: Colors.white),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _rePolishWithModel(context, provider, _sheetModel);
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _rePolishWithModel(BuildContext context, NoteProvider provider, String model) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('groq_api_key') ?? '';
    if (apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please set your Groq API Key in Settings first.'), backgroundColor: Colors.orange),
        );
      }
      return;
    }
    provider.setPolishing(true);
    try {
      // Direct Groq call — no Pi backend needed.
      final service = TranscriptionService();
      final newNote = await service.rePolishDirect(provider.rawTranscript, apiKey, model);
      provider.updatePolishedNote(newNote);
      _lastPolished = '';
      if (mounted) {
        setState(() { _showTranslated = false; _isEditing = false; });
        _tabController.animateTo(2);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('\u2728 Re-polished with $model!'), backgroundColor: Colors.blue),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      provider.setPolishing(false);
    }
  }



  Widget _buildCopyButton(BuildContext context, String label, String text, {bool isMarkdown = false}) {
    return ElevatedButton.icon(
      onPressed: () {
        final textToCopy = isMarkdown ? text.replaceAll(RegExp(r'(#+\s?|\*\*|-\s?)'), '') : text;
        Clipboard.setData(ClipboardData(text: textToCopy));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transcript copied!')),
        );
      },
      icon: const Icon(Icons.copy),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        minimumSize: const Size(double.infinity, 50),
      ),
    );
  }

  /// Read-only card: shows MarkdownBody (for polished) or plain Text.
  Widget _buildReadCard(BuildContext context, String text, {required bool isMarkdown}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: SingleChildScrollView(
        child: isMarkdown
            ? MarkdownBody(
                data: text.isEmpty ? '_No content yet_' : text,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: const TextStyle(fontSize: 16, height: 1.5),
                ),
              )
            : Text(
                text.isEmpty ? 'No content yet.' : text,
                style: const TextStyle(fontSize: 16, height: 1.5),
              ),
      ),
    );
  }

  Widget _buildEditableCard(BuildContext context, TextEditingController controller,
      {required void Function(String) onChanged}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        maxLines: null,
        expands: true,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(fontSize: 16, height: 1.5),
        decoration: const InputDecoration(
          border: InputBorder.none,
          hintText: 'Type here to edit...',
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  // Legacy read-only card (kept for reference, no longer used)
  Widget _buildTranscriptCard(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: SingleChildScrollView(
        child: Text(text, style: const TextStyle(fontSize: 16, height: 1.5)),
      ),
    );
  }

  Widget _buildPolishedCard(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: SingleChildScrollView(
        child: MarkdownBody(
          data: text,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: const TextStyle(fontSize: 16, height: 1.5),
          ),
        ),
      ),
    );
  }
}

enum ProcessingStep { uploading, processing, completed }

class TranscribePage extends StatefulWidget {
  final String audioPath;
  const TranscribePage({super.key, required this.audioPath});

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  bool _isProcessing = true;
  String _errorMessage = '';
  ProcessingStep _currentStep = ProcessingStep.uploading;

  String _selectedModel = 'llama-3.3-70b-versatile';
  final List<String> _supportedModels = [
    'llama-3.3-70b-versatile',
    'llama-3.1-8b-instant',
    'meta-llama/llama-4-scout-17b-16e-instruct',
    'qwen/qwen3-32b',
    'mixtral-8x7b-32768',
    'gemma2-9b-it',
  ];

  @override
  void initState() {
    super.initState();
    _startProcessing();
  }

  Future<void> _startProcessing() async {
    if (!mounted) return;
    setState(() {
      _isProcessing = true;
      _errorMessage = '';
      _currentStep = ProcessingStep.uploading;
    });

    try {
      final service = TranscriptionService();

      // Stage 1: Whisper STT — shown as "Uploading"
      final rawTranscript = await service.transcribe(widget.audioPath);

      // Stage 2: LLM Polish — shown as "Processing"
      if (!mounted) return;
      setState(() => _currentStep = ProcessingStep.processing);
      final results = await service.polish(rawTranscript);

      // Stage 3: Done — shown as "Downloading" briefly
      if (!mounted) return;
      setState(() => _currentStep = ProcessingStep.completed);
      await Future.delayed(const Duration(milliseconds: 600));

      if (mounted) Navigator.of(context).pop(results);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isProcessing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Processing'),
          centerTitle: true,
          automaticallyImplyLeading: !_isProcessing,
        ),
        body: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Center(
            child: _isProcessing
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const AiBrainAnimation(),
                      const SizedBox(height: 24),
                      ProcessingStepper(currentStep: _currentStep),
                      const SizedBox(height: 24),
                      const Text(
                        'Your voice note is being processed. This might take a few moments.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 60),
                      const SizedBox(height: 20),
                      const Text('Processing Failed', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      Text(_errorMessage.contains('QUOTA_EXHAUSTED') 
                        ? 'Quota Exhasted for this AI model. Please switch the model.' 
                        : _errorMessage, 
                        textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                      const SizedBox(height: 20),
                      ListTile(
                        title: const Text('Model Selection'),
                        subtitle: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedModel,
                            isExpanded: true,
                            items: _supportedModels.map((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              );
                            }).toList(),
                            onChanged: (String? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _selectedModel = newValue;
                                });
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Go Back')),
                          ElevatedButton(
                            onPressed: _startProcessing,
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                            child: const Text('Retry'),
                          ),
                        ],
                      )
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class ProcessingStepper extends StatelessWidget {
  final ProcessingStep currentStep;
  final double transcriptionProgress;
  final String transcriptionLabel;
  
  const ProcessingStepper({
    super.key, 
    required this.currentStep,
    this.transcriptionProgress = 0.0,
    this.transcriptionLabel = '',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildStep(context, 'Uploading', ProcessingStep.uploading),
            _buildConnector(ProcessingStep.processing),
            _buildStep(context, 'Processing', ProcessingStep.processing),
            _buildConnector(ProcessingStep.completed),
            _buildStep(context, 'Downloading', ProcessingStep.completed),
          ],
        ),
        if (transcriptionLabel.isNotEmpty && currentStep == ProcessingStep.processing) ...[
          const SizedBox(height: 24),
          Text(
            transcriptionLabel, 
            style: const TextStyle(color: Colors.grey, fontSize: 16, fontWeight: FontWeight.bold)
          ),
        ],
      ],
    );
  }

  bool _isStepActive(ProcessingStep step) {
    // A step is active if it's the current one or has been completed.
    return currentStep.index >= step.index;
  }

  Widget _buildStep(BuildContext context, String title, ProcessingStep step) {
    final isActive = _isStepActive(step);
    final isCurrent = currentStep == step;
    final isCompleted = currentStep.index > step.index;

    Color circleColor = isActive ? Colors.green : Colors.grey.shade400;
    Widget child = const SizedBox();

    if (isCompleted) {
      child = const Icon(Icons.check, color: Colors.white, size: 16);
    } else if (isCurrent) {
      // Determine color: Amber if busy/waiting, Green if processing
      final bool isWaiting = transcriptionLabel.toLowerCase().contains('busy');
      final Color indicatorColor = isWaiting ? Colors.amber : Colors.green.shade700;
      
      // Show a determinate progress indicator for the current step
      child = Padding(
        padding: const EdgeInsets.all(4.0),
        child: CircularProgressIndicator(
          value: (step == ProcessingStep.processing && !isWaiting) ? transcriptionProgress : null,
          strokeWidth: 3, 
          valueColor: AlwaysStoppedAnimation<Color>(indicatorColor),
          backgroundColor: Colors.transparent,
        ),
      );
    }

    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: circleColor,
          ),
          child: child,
        ),
        const SizedBox(height: 8),
        Text(
          title,
          style: TextStyle(
            color: isActive
                ? (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black)
                : Colors.grey,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildConnector(ProcessingStep step) {
    // The connector should be active if the step it leads to is active.
    final isActive = _isStepActive(step);
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: 2,
        color: isActive ? Colors.green : Colors.grey.shade400,
        margin: const EdgeInsets.only(bottom: 28), // Aligns with the middle of the circle
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {

  // --- GROQ STATE VARIABLES ---
  String _groqApiKey = '';
  String _selectedSttModel = 'whisper-large-v3';
  String _selectedLlmModel = 'llama-3.3-70b-versatile';

  final List<String> _groqSttModels = [
    'whisper-large-v3-turbo',
    'whisper-large-v3',
  ];

  final List<String> _groqLlmModels = [
    'llama-3.3-70b-versatile',
    'llama-3.1-8b-instant',
    'meta-llama/llama-4-scout-17b-16e-instruct',
    'qwen/qwen3-32b',
    'mixtral-8x7b-32768',
    'gemma2-9b-it',
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _groqApiKey = prefs.getString('groq_api_key') ?? '';
        _selectedSttModel = prefs.getString('groq_stt_model') ?? 'whisper-large-v3';
        _selectedLlmModel = prefs.getString('groq_llm_model') ?? 'llama-3.3-70b-versatile';
        if (!_groqSttModels.contains(_selectedSttModel)) _selectedSttModel = _groqSttModels.first;
        if (!_groqLlmModels.contains(_selectedLlmModel)) _selectedLlmModel = _groqLlmModels.first;
      });
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('groq_api_key', _groqApiKey);
    await prefs.setString('groq_stt_model', _selectedSttModel);
    await prefs.setString('groq_llm_model', _selectedLlmModel);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved! ✅')),
      );
    }
  }

  // _noop — local whisper switching removed in Groq architecture
  void _noop(String newMode) {}

  @override
  void dispose() {
    super.dispose();
  }

  // --- MODIFIED: The entire build method for the new UI ---
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () {
              _saveSettings();
              FocusScope.of(context).unfocus();
            },
            tooltip: 'Save Settings',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildSectionTitle('AI Configuration (Groq)'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade400, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Groq API Key', style: TextStyle(fontSize: 14, color: Colors.grey)),
                TextField(
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'Paste your Groq API key here',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onChanged: (value) => _groqApiKey = value,
                  controller: TextEditingController(text: _groqApiKey)
                    ..selection = TextSelection.collapsed(offset: _groqApiKey.length),
                ),
                const Divider(height: 16),
                DropdownButtonFormField<String>(
                  value: _selectedSttModel,
                  decoration: const InputDecoration(
                    labelText: '🎙️ Speech-to-Text Model',
                    border: InputBorder.none,
                  ),
                  items: _groqSttModels
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedSttModel = v!),
                ),
                const Divider(height: 16),
                DropdownButtonFormField<String>(
                  value: _selectedLlmModel,
                  decoration: const InputDecoration(
                    labelText: '🧠 Brain (LLM) Model',
                    border: InputBorder.none,
                  ),
                  items: _groqLlmModels
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedLlmModel = v!),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildSectionTitle('Theme'),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildThemeOption(
                context,
                'Light',
                Icons.light_mode,
                themeProvider.themeMode == ThemeMode.light,
                () => themeProvider.setThemeMode(ThemeMode.light),
              ),
              const SizedBox(width: 16),
              _buildThemeOption(
                context,
                'Dark',
                Icons.dark_mode,
                themeProvider.themeMode == ThemeMode.dark,
                () => themeProvider.setThemeMode(ThemeMode.dark),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
    );
  }

  Widget _buildThemeOption(BuildContext context, String title, IconData icon, bool isSelected, VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: isSelected ? colorScheme.primary.withOpacity(0.1) : Colors.transparent,
            border: Border.all(color: isSelected ? colorScheme.primary : Colors.grey),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Icon(icon, color: isSelected ? colorScheme.primary : Colors.grey),
              const SizedBox(height: 8),
              Text(title, textAlign: TextAlign.center, style: TextStyle(color: isSelected ? colorScheme.primary : Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Services ---

class TranscriptionService {
  static const String _groqBaseUrl = 'https://api.groq.com/openai/v1';

  static const String _polishSystemPrompt =
      'You are a professional secretary and expert note-taker. '
      'Your task is to transform a raw voice transcript into a clean, well-organized, professional Markdown note. '
      'Fix any technical or phonetic errors (e.g. Aadhar, Raspberry Pi, mAadhaar, VID, PVC). '
      'Remove filler words (um, uh, like, you know) and clean up jargon. '
      '\n\nOutput structure (strictly follow this):\n'
      '1. Start with a single # heading that captures the main context or topic of the entire audio.\n'
      '2. Use ## subheadings to divide the content into logical sections.\n'
      '3. Under each subheading, present the information as clear, concise bullet points (-).\n'
      '4. Bold (**) all key terms, names, decisions, and important concepts.\n'
      '\nOutput ONLY the Markdown. Do not wrap in triple backticks. Do not add any preamble or explanation.';


  /// Main entry point: 2 API calls — Whisper STT → Groq LLM Polish.
  Future<Map<String, String>> processNote(String audioPath) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('groq_api_key') ?? '';
    final sttModel = prefs.getString('groq_stt_model') ?? 'whisper-large-v3';
    final llmModel = prefs.getString('groq_llm_model') ?? 'llama-3.3-70b-versatile';

    if (apiKey.isEmpty) {
      throw Exception('Groq API Key is not set. Please add it in Settings.');
    }

    // Stage 1: Whisper STT (API Call 1)
    final rawTranscript = await _callWhisper(audioPath, apiKey, sttModel);

    if (rawTranscript.trim().length < 3) {
      return {
        'rawTranscript': 'No speech detected.',
        'cleanedTranscript': 'No speech detected.',
        'polishedNote': 'No speech was detected in the recording. Please try again.',
      };
    }

    // Stage 2: LLM Polish (API Call 2)
    final polishedNote = await _callGroqLLM(rawTranscript, apiKey, llmModel);

    return {
      'rawTranscript': rawTranscript,
      'cleanedTranscript': rawTranscript, // same as raw — Whisper output is already clean
      'polishedNote': polishedNote,
    };
  }

  /// Stage 1 (public): Transcribe audio using Groq Whisper.
  Future<String> transcribe(String audioPath) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('groq_api_key') ?? '';
    final sttModel = prefs.getString('groq_stt_model') ?? 'whisper-large-v3';
    if (apiKey.isEmpty) throw Exception('Groq API Key is not set. Please add it in Settings.');
    return _callWhisper(audioPath, apiKey, sttModel);
  }

  /// Stage 2 (public): Polish transcript using Groq LLM.
  Future<Map<String, String>> polish(String rawTranscript) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('groq_api_key') ?? '';
    final llmModel = prefs.getString('groq_llm_model') ?? 'llama-3.3-70b-versatile';
    if (apiKey.isEmpty) throw Exception('Groq API Key is not set. Please add it in Settings.');
    if (rawTranscript.trim().length < 3) {
      return {
        'rawTranscript': 'No speech detected.',
        'cleanedTranscript': 'No speech detected.',
        'polishedNote': 'No speech was detected in the recording. Please try again.',
      };
    }
    final polishedNote = await _callGroqLLM(rawTranscript, apiKey, llmModel);
    return {
      'rawTranscript': rawTranscript,
      'cleanedTranscript': rawTranscript,
      'polishedNote': polishedNote,
    };
  }

  Future<String> _callWhisper(String audioPath, String apiKey, String sttModel) async {
    final url = Uri.parse('$_groqBaseUrl/audio/transcriptions');
    final filename = audioPath.split('/').last;

    final file = await http.MultipartFile.fromPath('file', audioPath, filename: filename);
    final request = http.MultipartRequest('POST', url)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['model'] = sttModel
      ..fields['response_format'] = 'text'
      ..files.add(file);

    final streamed = await request.send().timeout(const Duration(seconds: 60));
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode == 200) return response.body.trim();
    if (response.statusCode == 401) throw Exception('Invalid Groq API Key. Please check Settings.');
    if (response.statusCode == 429) throw Exception('QUOTA_EXHAUSTED: Groq STT quota reached.');
    throw Exception('Groq Whisper error (${response.statusCode}): ${response.body}');
  }

  Future<String> _callGroqLLM(String transcript, String apiKey, String llmModel) async {
    final url = Uri.parse('$_groqBaseUrl/chat/completions');
    final response = await http
        .post(
          url,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': llmModel,
            'messages': [
              {'role': 'system', 'content': _polishSystemPrompt},
              {'role': 'user', 'content': 'PROCESS THIS TRANSCRIPT:\n\n$transcript'},
            ],
            'temperature': 0.3,
            'max_tokens': 4096,
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      String content = data['choices'][0]['message']['content'].toString().trim();
      if (content.startsWith('```')) {
        final lines = content.split('\n');
        final stripped = lines.skip(1).toList();
        if (stripped.isNotEmpty && stripped.last.startsWith('```')) stripped.removeLast();
        content = stripped.join('\n').trim();
      }
      return content;
    }
    if (response.statusCode == 401) throw Exception('Invalid Groq API Key. Please check Settings.');
    if (response.statusCode == 429) throw Exception('QUOTA_EXHAUSTED: Groq LLM quota reached. Try switching Brain model.');
    throw Exception('Groq LLM error (${response.statusCode}): ${response.body}');
  }

  /// Re-polish raw transcript directly via Groq (for the ✨ Try Again button).
  Future<String> rePolishDirect(String rawTranscript, String apiKey, String llmModel) async {
    return _callGroqLLM(rawTranscript, apiKey, llmModel);
  }
}


// --- NEW AI BRAIN ANIMATION WIDGET ---

class AiBrainAnimation extends StatefulWidget {
  const AiBrainAnimation({super.key});

  @override
  State<AiBrainAnimation> createState() => _AiBrainAnimationState();
}

class _AiBrainAnimationState extends State<AiBrainAnimation> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: BrainPainter(progress: _controller.value),
          size: const Size(200, 150),
        );
      },
    );
  }
}

class BrainPainter extends CustomPainter {
  final double progress;
  final List<Offset> neurons;
  final List<List<int>> connections;
  final math.Random random;

  BrainPainter({required this.progress})
      : random = math.Random(1), // Seeded for consistent patterns
        neurons = List.generate(15, (i) {
          final r = math.Random(i);
          return Offset(r.nextDouble() * 200, r.nextDouble() * 150);
        }),
        connections = [] {
    _generateConnections();
  }

  void _generateConnections() {
    for (int i = 0; i < neurons.length; i++) {
      for (int j = i + 1; j < neurons.length; j++) {
        // Connect nodes that are reasonably close
        if ((neurons[i] - neurons[j]).distance < 80 && random.nextDouble() > 0.5) {
          connections.add([i, j]);
        }
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final synapsePaint = Paint()
      ..color = Colors.green.withOpacity(0.2)
      ..strokeWidth = 1.0;

    final neuronPaint = Paint()..color = Colors.green.withOpacity(0.8);

    final glowPaint = Paint()
      ..color = Colors.green.withOpacity(0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    final pulsePaint = Paint()
      ..color = Colors.white
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    // 1. Draw connections (synapses)
    for (var connection in connections) {
      canvas.drawLine(neurons[connection[0]], neurons[connection[1]], synapsePaint);
    }

    // 2. Draw neurons and glowing effects
    for (int i = 0; i < neurons.length; i++) {
      // Make different neurons glow based on time
      final wave = math.sin(progress * 2 * math.pi + (i * math.pi / 4));
      if (wave > 0.5) {
        canvas.drawCircle(neurons[i], 10 + wave * 4, glowPaint);
      }
      canvas.drawCircle(neurons[i], 4, neuronPaint);
    }

    // 3. Draw traveling pulses
    final pulseCount = (connections.length / 4).floor();
    for (int i = 0; i < pulseCount; i++) {
      final connectionIndex = (i + (progress * pulseCount).floor()) % connections.length;
      final connection = connections[connectionIndex];
      final start = neurons[connection[0]];
      final end = neurons[connection[1]];

      // Animate the pulse along the line
      final pulsePosition = Offset.lerp(start, end, (progress * 2) % 1.0)!;
      canvas.drawCircle(pulsePosition, 3, pulsePaint);
    }
  }

  @override
  bool shouldRepaint(covariant BrainPainter oldDelegate) => progress != oldDelegate.progress;
}
