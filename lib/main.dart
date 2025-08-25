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
  String _rawTranscript = 'Record a new note from the Home screen.';
  String _cleanedTranscript = 'Your cleaned note will appear here.';
  String _polishedTranscript = 'Your polished note will appear here.';

  String get rawTranscript => _rawTranscript;
  String get cleanedTranscript => _cleanedTranscript;
  String get polishedTranscript => _polishedTranscript;

  void updateTranscripts(Map<String, String> transcripts) {
    _rawTranscript = transcripts['rawTranscript'] ?? 'No raw transcript available.';
    _cleanedTranscript = transcripts['cleanedTranscript'] ?? 'No cleaned transcript available.';
    _polishedTranscript = transcripts['polishedNote'] ?? 'No polished note available.';
    notifyListeners();
  }
}

class RecordingProvider with ChangeNotifier {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  StreamSubscription? _recorderSubscription;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  bool get isRecording => _recorder.isRecording;

  String? _audioPath;
  String? get audioPath => _audioPath;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  double _decibelLevel = -120.0; // Start at minimum decibels
  double get decibelLevel => _decibelLevel;

  RecordingProvider() {
    _initRecorder();
  }

  Future<void> _initRecorder() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      // Handle permission denial
      return;
    }
    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
    _isInitialized = true;
    notifyListeners();
  }

  Future<void> startRecording() async {
    if (!_isInitialized || isRecording) return;

    Directory tempDir = await getTemporaryDirectory();
    _audioPath = '${tempDir.path}/voice_note_${DateTime.now().millisecondsSinceEpoch}.aac';

    await _recorder.startRecorder(
      toFile: _audioPath,
      codec: Codec.aacADTS,
    );

    _recorderSubscription = _recorder.onProgress!.listen((e) {
      _duration = e.duration;
      // Use a default of -120 if decibels is null
      _decibelLevel = e.decibels ?? -120.0;
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> stopRecording() async {
    if (!_isInitialized || !isRecording) return;

    await _recorder.stopRecorder();
    await _recorderSubscription?.cancel();
    _recorderSubscription = null;
    _duration = Duration.zero;
    _decibelLevel = -120.0;
    notifyListeners();
  }

  Future<void> cancelRecording() async {
    if (!_isInitialized || !isRecording) return;

    await _recorder.stopRecorder();
    await _recorderSubscription?.cancel();
    _recorderSubscription = null;
    _audioPath = null;
    _duration = Duration.zero;
    _decibelLevel = -120.0;
    notifyListeners();
  }

  @override
  void dispose() {
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
              ..._availableMicrophones.map((mic) => ListTile(
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
              )).toList(),
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

  Future<void> _toggleRecording(RecordingProvider recorder) async {
    if (!recorder.isInitialized) return;

    if (!recorder.isRecording) {
      final prefs = await SharedPreferences.getInstance();
      final apiKey = prefs.getString('apiKey') ?? '';
      if (apiKey.isEmpty) {
        if(mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Please add your Gemini API Key in Settings first.'),
            action: SnackBarAction(label: 'Settings', onPressed: widget.onNavigateToSettings),
          ));
        }
        return;
      }
      _animationController.forward();
      await recorder.startRecording();
    } else {
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
              if (!recorder.isRecording) const ParticleBackground(),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDarkMode
                        ? [Colors.grey[900]!, Colors.grey[850]!]
                        : [Colors.grey.shade100, Colors.white],
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
                        child: recorder.isRecording
                          ? AudioWaveformVisualizer(decibelLevel: recorder.decibelLevel)
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
                      GestureDetector(
                        onTap: () => _toggleRecording(recorder),
                        child: Container(
                          padding: const EdgeInsets.all(25),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.red,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.red.withOpacity(recorder.isRecording ? 0.4 : _pulseAnimation.value * 0.6),
                                spreadRadius: recorder.isRecording ? 10 : 5 + 15 * _pulseAnimation.value,
                                blurRadius: recorder.isRecording ? 20 : 10 + 30 * _pulseAnimation.value,
                              )
                            ],
                          ),
                          child: Icon(recorder.isRecording ? Icons.stop : Icons.mic, color: Colors.white, size: 40),
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextButton(
                        onPressed: recorder.isRecording ? recorder.cancelRecording : null,
                        child: Text('Cancel', style: TextStyle(color: recorder.isRecording ? theme.textTheme.bodyLarge?.color : Colors.grey, fontSize: 16)),
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
    _particles = List.generate(50, (_) => Particle(
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

// --- UPDATED WIDGET: Audio Waveform Visualizer ---
class AudioWaveformVisualizer extends StatefulWidget {
  final double decibelLevel;
  const AudioWaveformVisualizer({super.key, required this.decibelLevel});

  @override
  State<AudioWaveformVisualizer> createState() => _AudioWaveformVisualizerState();
}

class _AudioWaveformVisualizerState extends State<AudioWaveformVisualizer> {
  List<double> _waveforms = [];
  final int _maxWaveforms = 100;
  Timer? _scrollTimer;

  // --- FIX: New variables to manage data flow ---
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

      // --- FIX: Store the latest value and set a flag ---
      _lastDecibel = normalized;
      _hasNewData = true;
    }
  }

  void _startScrolling() {
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 75), (timer) { // Slightly slower scroll
      if (mounted) {
        setState(() {
          // --- FIX: Use the flag to decide what to add ---
          if (_hasNewData) {
             _waveforms.add(_lastDecibel);
             _hasNewData = false; // Reset the flag
          } else {
            // Add a zero to create the flat line effect when there's no new data
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

    // Draw the top part of the wave
    final lastX = size.width;
    final lastY = size.height / 2 - (waveforms.last * size.height * 0.8).clamp(2.0, size.height) / 2;
    path.lineTo(lastX, lastY);
    path.lineTo(lastX, size.height / 2);

    // Mirror the path for the bottom part
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


// --- REFACTORED WIDGET: NotePage ---
class NotePage extends StatefulWidget {
  const NotePage({super.key});

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NoteProvider>(
      builder: (context, noteProvider, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Note'),
            centerTitle: true,
            bottom: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Raw Transcript'),
                Tab(text:'Cleaned'),
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
                      _buildTranscriptCard(context, noteProvider.rawTranscript),
                      _buildTranscriptCard(context, noteProvider.cleanedTranscript),
                      _buildPolishedCard(context, noteProvider.polishedTranscript),
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
                            child: ClipRect( // Prevents overflow
                              child: Transform.translate(
                                offset: Offset(-_tabController.animation!.value * constraints.maxWidth, 0),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: constraints.maxWidth,
                                      child: _buildCopyButton(
                                        context,
                                        'Copy Transcript',
                                        noteProvider.rawTranscript,
                                        isMarkdown: false,
                                      ),
                                    ),
                                    SizedBox(
                                      width: constraints.maxWidth,
                                      child: _buildCopyButton(
                                        context,
                                        'Copy Transcript',
                                        noteProvider.cleanedTranscript,
                                        isMarkdown: false,
                                      ),
                                    ),
                                    SizedBox(
                                      width: constraints.maxWidth,
                                      child: _buildCopyButton(
                                        context,
                                        'Copy Transcript',
                                        noteProvider.polishedTranscript,
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
         final textToCopy = isMarkdown
             ? text.replaceAll(RegExp(r'(#+\s?|\*\*|-\s?)'), '')
             : text;
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
         shape:
             RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
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

// --- Enum for Processing State ---
enum ProcessingStep { transcribing, cleaning, polishing, completed }

// --- REFACTORED WIDGET: TranscribePage ---
class TranscribePage extends StatefulWidget {
  final String audioPath;
  const TranscribePage({super.key, required this.audioPath});

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  ProcessingStep _currentStep = ProcessingStep.transcribing;
  bool _isProcessing = true;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _startProcessing();
  }

  // --- MODIFIED: This method now uses the new single-call service ---
  Future<void> _startProcessing() async {
    if (!mounted) return;
    setState(() {
      _isProcessing = true;
      _errorMessage = '';
      _currentStep = ProcessingStep.transcribing;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final apiKey = prefs.getString('apiKey') ?? '';
      final modelName = prefs.getString('modelName') ?? 'gemini-2.5-flash';


      final service = TranscriptionService();

      // Single API call to get all three results
      final result = await service.processAudio(widget.audioPath, apiKey, modelName);

      // Update UI stepper for a better user experience
      if(mounted) setState(() { _currentStep = ProcessingStep.cleaning; });
      await Future.delayed(const Duration(milliseconds: 400));

      if(mounted) setState(() { _currentStep = ProcessingStep.polishing; });
      await Future.delayed(const Duration(milliseconds: 400));


      if(mounted) setState(() { _currentStep = ProcessingStep.completed; });
      await Future.delayed(const Duration(milliseconds: 400));

      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      if(mounted) {
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


// --- NEW WIDGET: Processing Stepper ---
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
            _buildStep(context, 'Transcribing', ProcessingStep.transcribing),
            _buildConnector(ProcessingStep.cleaning),
            _buildStep(context, 'Cleaning', ProcessingStep.cleaning),
            _buildConnector(ProcessingStep.polishing),
            _buildStep(context, 'Polishing', ProcessingStep.polishing),
          ],
        ),
      ],
    );
  }

  bool _isStepActive(ProcessingStep step) {
    return currentStep.index >= step.index;
  }

  // --- FIXED METHOD: Added BuildContext ---
  Widget _buildStep(BuildContext context, String title, ProcessingStep step) {
    final isActive = _isStepActive(step);
    final isCurrent = currentStep == step;
    final isCompleted = currentStep.index > step.index;

    Color circleColor = isActive ? Colors.green : Colors.grey.shade400;
    Widget child = const SizedBox();

    if (isCompleted) {
      child = const Icon(Icons.check, color: Colors.white, size: 16);
    } else if (isCurrent) {
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
            color: isActive ? (isDarkTheme(context) ? Colors.white : Colors.black) : Colors.grey,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildConnector(ProcessingStep step) {
    final isActive = _isStepActive(step);
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: 2,
        color: isActive ? Colors.green : Colors.grey.shade400,
        margin: const EdgeInsets.only(bottom: 28),
      ),
    );
  }

  bool isDarkTheme(BuildContext context) => Theme.of(context).brightness == Brightness.dark;
}


class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _apiKeyController = TextEditingController();
  final _modelNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _apiKeyController.text = prefs.getString('apiKey') ?? '';
        _modelNameController.text = prefs.getString('modelName') ?? 'gemini-1.5-flash';
      });
    }
  }

  Future<void> _saveApiKey(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiKey', value);
  }

    Future<void> _saveModelName(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('modelName', value);
  }


  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
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
              suffixIcon: IconButton(
                icon: const Icon(Icons.save),
                onPressed: () {
                  _saveApiKey(_apiKeyController.text);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('API Key saved!')),
                  );
                  FocusScope.of(context).unfocus();
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Get your key from Google AI Studio. Your API key is stored securely on your device.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 24),
          _buildSectionTitle('Model Name'),
          const SizedBox(height: 8),
          TextField(
            controller: _modelNameController,
            decoration: InputDecoration(
              hintText: 'Use gemini-1.5-flash',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.save),
                onPressed: () {
                  _saveModelName(_modelNameController.text);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Model name saved!')),
                  );
                  FocusScope.of(context).unfocus();
                },
              ),
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

// --- MODIFIED: This class now makes a single, optimized API call ---
class TranscriptionService {

  // This new method replaces the three separate ones.
  Future<Map<String, String>> processAudio(String audioPath, String apiKey, String modelName) async {
    if (apiKey.isEmpty) {
      throw Exception('API Key is missing. Please add it in Settings.');
    }

    // Using a more capable model that is good at following JSON instructions.
    final model = GenerativeModel(model: modelName, apiKey: apiKey);

    // The new, comprehensive prompt asking for a JSON response.
    final prompt = '''
You are an AI assistant for a voice note app. Process the attached audio file and provide three distinct outputs in a single, valid JSON object.

The JSON object must have these exact keys: "rawTranscript", "cleanedTranscript", and "polishedNote".

1.  **rawTranscript**: Provide a direct, accurate transcription of the audio.
2.  **cleanedTranscript**: Take the raw transcript, remove filler words (like "um", "uh"), correct obvious grammar mistakes, and fix punctuation. Do not add any new information, introductory phrases, or explanations. The output must ONLY be the cleaned text itself.
3.  **polishedNote**: Transform the cleaned transcript into a well-structured note. Use markdown for formatting (e.g., "## Headings", "- Bullet points"). Identify key points and action items. The output must ONLY be the markdown note itself, starting directly with the content. Do not include any conversational preamble like "Here is the polished note...".

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

      // Clean the response to ensure it's valid JSON.
      // The model sometimes wraps the JSON in ```json ... ```.
      final cleanedJson = responseText.replaceAll('```json', '').replaceAll('```', '').trim();

      // Decode the JSON string into a Map.
      final decodedJson = jsonDecode(cleanedJson) as Map<String, dynamic>;

      // Ensure all required keys are present.
      if (!decodedJson.containsKey('rawTranscript') ||
          !decodedJson.containsKey('cleanedTranscript') ||
          !decodedJson.containsKey('polishedNote')) {
        throw Exception('The AI response is missing required data. Please try again.');
      }

      // Return the results as a strongly-typed Map.
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
      // Catches JSON parsing errors or other unexpected issues.
      throw Exception('An unexpected error occurred while processing the note: $e');
    }
  }
}