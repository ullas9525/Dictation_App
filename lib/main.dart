import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert'; // Import for json decoding
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  StreamSubscription? _recorderSubscription;
  Timer? _durationTimer;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  bool _isSessionActive = false;
  bool get isSessionActive => _isSessionActive;

  bool get isRecording => _recorder.isRecording;

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
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      return;
    }
    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
    _isInitialized = true;
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
    _recorderSubscription = _recorder.onProgress!.listen((e) {
      _decibelLevel = e.decibels ?? -120.0;
      notifyListeners();
    });
  }

  Future<void> startRecording() async {
    if (!_isInitialized || _isSessionActive) return;

    Directory tempDir = await getTemporaryDirectory();
    _audioPath = '${tempDir.path}/voice_note_${DateTime.now().millisecondsSinceEpoch}.aac';

    await _recorder.startRecorder(
      toFile: _audioPath,
      codec: Codec.aacADTS,
    );

    _duration = Duration.zero;
    _startTimer();
    _startDecibelSubscription();

    _isPaused = false;
    _isSessionActive = true;
    notifyListeners();
  }

  Future<void> pauseRecording() async {
    if (!_isInitialized || !_isSessionActive || _isPaused) return;
    await _recorder.pauseRecorder();
    _isPaused = true;
    _durationTimer?.cancel();
    _recorderSubscription?.cancel();
    _recorderSubscription = null;
    notifyListeners();
  }

  Future<void> resumeRecording() async {
    if (!_isInitialized || !_isSessionActive || !_isPaused) return;
    await _recorder.resumeRecorder();
    _isPaused = false;
    _startTimer();
    _startDecibelSubscription();
    notifyListeners();
  }

  Future<void> stopRecording() async {
    if (!_isInitialized || !_isSessionActive) return;
    await _recorder.stopRecorder();
    _durationTimer?.cancel();
    await _recorderSubscription?.cancel();
    _recorderSubscription = null;
    _duration = Duration.zero;
    _decibelLevel = -120.0;
    _isPaused = false;
    _isSessionActive = false;
    notifyListeners();
  }

  Future<void> cancelRecording() async {
    if (!_isInitialized || !_isSessionActive) return;
    await _recorder.stopRecorder();
    _durationTimer?.cancel();
    await _recorderSubscription?.cancel();
    _recorderSubscription = null;
    _audioPath = null;
    _duration = Duration.zero;
    _decibelLevel = -120.0;
    _isPaused = false;
    _isSessionActive = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _recorderSubscription?.cancel();
    _recorder.closeRecorder();
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

    _animationController.reverse();
    await recorder.stopRecording();

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

  Future<void> _checkApiKeyAndStart(RecordingProvider recorder) async {
    if (!recorder.isInitialized) return;

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('apiKey') ?? '';
    if (apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Please add your Gemini API Key in Settings first.'),
          action: SnackBarAction(label: 'Settings', onPressed: widget.onNavigateToSettings),
        ));
      }
      return;
    }
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
                                onTap: () => _checkApiKeyAndStart(recorder),
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
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: recorder.isSessionActive ? 1.0 : 0.0,
                          child: recorder.isSessionActive
                              ? TextButton(
                                  onPressed: recorder.cancelRecording,
                                  child: const Text('Cancel', style: TextStyle(fontSize: 16)),
                                  style: TextButton.styleFrom(
                                    foregroundColor: theme.textTheme.bodyLarge?.color,
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  ),
                                )
                              : const SizedBox(),
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
  // --- NEW: State for showing translated text ---
  bool _showTranslated = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // --- MODIFIED: The entire build method for the new UI ---
  @override
  Widget build(BuildContext context) {
    return Consumer<NoteProvider>(
      builder: (context, noteProvider, child) {
        // --- NEW: Check if translated content exists ---
        final bool hasTranslation = noteProvider.rawTranscriptTranslated.isNotEmpty;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Note'),
            centerTitle: true,
            // --- NEW: Add toggle switch to actions if translation is available ---
            actions: [
              if (hasTranslation)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Row(
                    children: [
                      Text(_showTranslated ? "Translated" : "Original"),
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
                      // --- MODIFIED: Show text based on toggle state ---
                      _buildTranscriptCard(
                          context, _showTranslated ? noteProvider.rawTranscriptTranslated : noteProvider.rawTranscript),
                      _buildTranscriptCard(context,
                          _showTranslated ? noteProvider.cleanedTranscriptTranslated : noteProvider.cleanedTranscript),
                      _buildPolishedCard(
                          context,
                          _showTranslated
                              ? noteProvider.polishedTranscriptTranslated
                              : noteProvider.polishedTranscript),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return AnimatedBuilder(
                        animation: _tabController.animation!,
                        builder: (context, child) {
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const NeverScrollableScrollPhysics(),
                            child: ClipRect(
                              child: Transform.translate(
                                offset: Offset(-_tabController.animation!.value * constraints.maxWidth, 0),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: constraints.maxWidth,
                                      child: _buildCopyButton(
                                        context,
                                        'Copy Transcript',
                                        _showTranslated
                                            ? noteProvider.rawTranscriptTranslated
                                            : noteProvider.rawTranscript,
                                        isMarkdown: false,
                                      ),
                                    ),
                                    SizedBox(
                                      width: constraints.maxWidth,
                                      child: _buildCopyButton(
                                        context,
                                        'Copy Transcript',
                                        _showTranslated
                                            ? noteProvider.cleanedTranscriptTranslated
                                            : noteProvider.cleanedTranscript,
                                        isMarkdown: false,
                                      ),
                                    ),
                                    SizedBox(
                                      width: constraints.maxWidth,
                                      child: _buildCopyButton(
                                        context,
                                        'Copy Transcript',
                                        _showTranslated
                                            ? noteProvider.polishedTranscriptTranslated
                                            : noteProvider.polishedTranscript,
                                        isMarkdown: true,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
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

  Widget _buildTranscriptCard(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: SingleChildScrollView(
        child: Text(
          text,
          style: const TextStyle(fontSize: 16, height: 1.5),
        ),
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

enum ProcessingStep { uploading, processing, downloading, completed }

class TranscribePage extends StatefulWidget {
  final String audioPath;
  const TranscribePage({super.key, required this.audioPath});

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  ProcessingStep _currentStep = ProcessingStep.uploading;
  bool _isProcessing = true;
  String _errorMessage = '';

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
      // Simulate the "Uploading" phase for better UX
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      setState(() {
        _currentStep = ProcessingStep.processing;
      });

      final prefs = await SharedPreferences.getInstance();
      final apiKey = prefs.getString('apiKey') ?? '';
      final modelName = prefs.getString('modelName') ?? 'gemini-2.5-flash';
      final isTranslationEnabled = prefs.getBool('isTranslationEnabled') ?? false;
      final targetLanguage = prefs.getString('targetLanguage') ?? 'English';
      final service = TranscriptionService();

      // Both transcription and translation happen under the "Processing" step
      final originalResults = await service.processAudio(widget.audioPath, apiKey, modelName);
      Map<String, String> finalResults = Map.from(originalResults);

      if (isTranslationEnabled) {
        final translatedResults = await service.translateTexts(
          originalTexts: originalResults,
          targetLanguage: targetLanguage,
          apiKey: apiKey,
          modelName: modelName,
        );
        finalResults.addAll(translatedResults);
      }

      // Move to the "Downloading" phase
      if (!mounted) return;
      setState(() {
        _currentStep = ProcessingStep.downloading;
      });
      await Future.delayed(const Duration(milliseconds: 500));

      if (!mounted) return;
      setState(() {
        _currentStep = ProcessingStep.completed;
      });
      await Future.delayed(const Duration(milliseconds: 400));

      if (mounted) {
        Navigator.of(context).pop(finalResults);
      }
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
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(scale: animation, child: child),
                          );
                        },
                        child: _currentStep == ProcessingStep.processing
                            ? const AiBrainAnimation(key: ValueKey('brain'))
                            : const SizedBox(height: 150, key: ValueKey('placeholder')),
                      ),
                      const SizedBox(height: 20),
                      ProcessingStepper(currentStep: _currentStep),
                      const SizedBox(height: 40),
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
                      Text(_errorMessage, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Go Back')),
                          const SizedBox(width: 16),
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
  const ProcessingStepper({super.key, required this.currentStep});

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
            _buildConnector(ProcessingStep.downloading),
            _buildStep(context, 'Downloading', ProcessingStep.downloading),
          ],
        ),
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
      // Show a progress indicator for the current step
      child = Padding(
        padding: const EdgeInsets.all(4.0),
        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.green.shade700)),
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
  final _apiKeyController = TextEditingController();
  final _modelNameController = TextEditingController();

  // --- NEW STATE VARIABLES ---
  bool _isTranslationEnabled = false;
  String _selectedLanguage = 'English';
  final List<String> _supportedLanguages = [
    'Kannada',
    'English',
    'Telugu',
    'Tamil',
    'Hindi',
    'Spanish',
    'French',
    'German',
    'Japanese'
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  // --- MODIFIED: Load new settings from storage ---
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _apiKeyController.text = prefs.getString('apiKey') ?? '';
        _modelNameController.text = prefs.getString('modelName') ?? 'gemini-2.5-flash';
        _isTranslationEnabled = prefs.getBool('isTranslationEnabled') ?? false;
        _selectedLanguage = prefs.getString('targetLanguage') ?? 'Kannada';
      });
    }
  }

  // --- MODIFIED: Save new settings to storage ---
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiKey', _apiKeyController.text);
    await prefs.setString('modelName', _modelNameController.text);
    await prefs.setBool('isTranslationEnabled', _isTranslationEnabled);
    await prefs.setString('targetLanguage', _selectedLanguage);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved!')),
      );
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelNameController.dispose();
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
            tooltip: 'Save All Settings',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildSectionTitle('API Key'),
          const SizedBox(height: 8),
          TextField(
            controller: _apiKeyController,
            obscureText: true,
            decoration: InputDecoration(
              hintText: 'Enter your Gemini API Key',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Get your Google API key from Google AI Studio.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 24),
          _buildSectionTitle('Model Name'),
          const SizedBox(height: 8),
          TextField(
            controller: _modelNameController,
            decoration: InputDecoration(
              hintText: 'Use gemini-2.5-flash',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),

          // --- NEW TRANSLATION SECTION ---
          const SizedBox(height: 24),
          _buildSectionTitle('Translation'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade400, width: 1),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Enable Translation'),
                  value: _isTranslationEnabled,
                  onChanged: (bool value) {
                    setState(() {
                      _isTranslationEnabled = value;
                    });
                  },
                  activeColor: Colors.red,
                  contentPadding: EdgeInsets.zero,
                ),
                if (_isTranslationEnabled) ...[
                  const Divider(height: 1),
                  DropdownButtonFormField<String>(
                    value: _selectedLanguage,
                    decoration: const InputDecoration(
                      labelText: 'Target Language',
                      border: InputBorder.none,
                    ),
                    items: _supportedLanguages.map((String language) {
                      return DropdownMenuItem<String>(
                        value: language,
                        child: Text(language),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      setState(() {
                        _selectedLanguage = newValue!;
                      });
                    },
                  ),
                ]
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
              Text(title, style: TextStyle(color: isSelected ? colorScheme.primary : Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Services ---

class TranscriptionService {
  // This method ONLY transcribes now.
  Future<Map<String, String>> processAudio(String audioPath, String apiKey, String modelName) async {
    if (apiKey.isEmpty) {
      throw Exception('API Key is missing. Please add it in Settings.');
    }

    final model = GenerativeModel(model: modelName, apiKey: apiKey);

    final prompt = '''
You are an AI assistant for a voice note app. Process the attached audio file and provide three distinct outputs in a single, valid JSON object.

The JSON object must have these exact keys: "rawTranscript", "cleanedTranscript", and "polishedNote".

1.  **rawTranscript**: Provide a direct, accurate transcription of the audio.
2.  **cleanedTranscript**: Take the raw transcript, remove filler words (like "um", "uh"), correct obvious grammar mistakes, and fix punctuation.
3.  **polishedNote**: Transform the cleaned transcript into a well-structured markdown note.

Return only the raw JSON object.
''';

    final audioFile = File(audioPath);
    final audioBytes = await audioFile.readAsBytes();
    final parts = [
      TextPart(prompt),
      DataPart('audio/mpeg', audioBytes),
    ];

    try {
      final response = await model.generateContent([Content.multi(parts)]);
      final responseText = response.text;

      if (responseText == null) {
        throw Exception('Received an empty response from the AI model.');
      }

      final cleanedJson = responseText.replaceAll('```json', '').replaceAll('```', '').trim();
      final decodedJson = jsonDecode(cleanedJson) as Map<String, dynamic>;

      if (!decodedJson.containsKey('rawTranscript') ||
          !decodedJson.containsKey('cleanedTranscript') ||
          !decodedJson.containsKey('polishedNote')) {
        throw Exception('The AI response is missing required data. Please try again.');
      }

      return {
        'rawTranscript': decodedJson['rawTranscript'] as String,
        'cleanedTranscript': decodedJson['cleanedTranscript'] as String,
        'polishedNote': decodedJson['polishedNote'] as String,
      };
    } on GenerativeAIException catch (e) {
      if (e.message.contains('Unhandled format for Content')) {
        throw Exception('There was an issue with the audio format. Please try recording again.');
      }
      throw Exception('AI model error: ${e.message}');
    } catch (e) {
      throw Exception('An unexpected error occurred while processing the note: $e');
    }
  }

  // --- NEW METHOD FOR TRANSLATION ---
  Future<Map<String, String>> translateTexts({
    required Map<String, String> originalTexts,
    required String targetLanguage,
    required String apiKey,
    required String modelName,
  }) async {
    final model = GenerativeModel(model: modelName, apiKey: apiKey);

    final prompt = '''
You are an expert translator. I will provide a JSON object with three texts: "rawTranscript", "cleanedTranscript", and "polishedNote".
Your task is to translate all three of them into **$targetLanguage**.

Return a single, valid JSON object with these exact keys: "raw_translated", "cleaned_translated", and "polished_translated".

Do not add any explanations or conversational text. Return only the raw JSON object.
''';

    // Combine prompt with the texts to be translated
    final content = [
      Content.text(prompt),
      Content.text('Here is the JSON to translate: ${jsonEncode(originalTexts)}'),
    ];

    try {
      final response = await model.generateContent(content);
      final responseText = response.text;

      if (responseText == null) {
        throw Exception('Received an empty response from the AI model during translation.');
      }

      final cleanedJson = responseText.replaceAll('```json', '').replaceAll('```', '').trim();
      final decodedJson = jsonDecode(cleanedJson) as Map<String, dynamic>;

      return {
        'raw_translated': decodedJson['raw_translated'] as String? ?? '',
        'cleaned_translated': decodedJson['cleaned_translated'] as String? ?? '',
        'polished_translated': decodedJson['polished_translated'] as String? ?? '',
      };
    } catch (e) {
      throw Exception('An unexpected error occurred during translation: $e');
    }
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
