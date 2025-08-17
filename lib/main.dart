import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:math' as math;


// --- IMPORTANT ---
// Before running, add the flutter_markdown package to your pubspec.yaml file:
//
// dependencies:
//   flutter:
//     sdk: flutter
//   ...
//   flutter_markdown: ^0.7.1
//
// Then run `flutter pub get` in your terminal.


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

class _HomePageState extends State<HomePage> {
  bool _noiseReduction = true;
  bool _transcription = true;
  bool _aiProcessing = true;

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
      await recorder.startRecording();
    } else {
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
    return Consumer<RecordingProvider>(
      builder: (context, recorder, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('New Note'),
            centerTitle: true,
          ),
          body: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                _buildSettingItem('Microphone', 'Built-in'),
                _buildSwitchItem('Noise Reduction', _noiseReduction, (val) => setState(() => _noiseReduction = val)),
                _buildSwitchItem('Transcription', _transcription, (val) => setState(() => _transcription = val)),
                _buildSwitchItem('AI Processing', _aiProcessing, (val) => setState(() => _aiProcessing = val)),
                const Spacer(),
                Text(
                  _formatDuration(recorder.duration),
                  style: const TextStyle(fontSize: 60, fontWeight: FontWeight.w200),
                ),
                SizedBox(
                  height: 100,
                  child: recorder.isRecording 
                    ? AudioWaveformVisualizer(decibelLevel: recorder.decibelLevel)
                    : const Center(child: Text("Ready to Record", style: TextStyle(color: Colors.grey))),
                ),
                const Spacer(),
                Column(
                  children: [
                    GestureDetector(
                      onTap: () => _toggleRecording(recorder),
                      child: Container(
                        padding: const EdgeInsets.all(25),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.red,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withOpacity(0.3),
                              spreadRadius: 8,
                              blurRadius: 15,
                            )
                          ],
                        ),
                        child: Icon(recorder.isRecording ? Icons.stop : Icons.mic, color: Colors.white, size: 40),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: recorder.isRecording ? recorder.cancelRecording : null,
                      child: Text('Cancel', style: TextStyle(color: recorder.isRecording ? Theme.of(context).textTheme.bodyLarge?.color : Colors.grey)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingItem(String title, String value) {
    return ListTile(
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(color: Colors.grey)),
          const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
        ],
      ),
      onTap: () {},
    );
  }

  Widget _buildSwitchItem(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(title),
      value: value,
      onChanged: onChanged,
      activeColor: Colors.red,
    );
  }
}

// --- NEW WIDGET: Audio Waveform Visualizer ---
class AudioWaveformVisualizer extends StatefulWidget {
  final double decibelLevel;
  const AudioWaveformVisualizer({super.key, required this.decibelLevel});

  @override
  State<AudioWaveformVisualizer> createState() => _AudioWaveformVisualizerState();
}

class _AudioWaveformVisualizerState extends State<AudioWaveformVisualizer> {
  final List<double> _waveforms = [];
  final int _maxWaveforms = 50; // Number of bars to display

  @override
  void didUpdateWidget(covariant AudioWaveformVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.decibelLevel != oldWidget.decibelLevel) {
      setState(() {
        // Normalize decibel level from [-120, 0] to [0, 1]
        // Adding a small value to avoid log(0)
        final double normalized = (widget.decibelLevel.clamp(-120.0, 0.0) + 120) / 120;
        _waveforms.add(normalized);
        if (_waveforms.length > _maxWaveforms) {
          _waveforms.removeAt(0);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: WaveformPainter(
        waveforms: _waveforms,
        color: Colors.red,
      ),
      size: const Size(double.infinity, 100),
    );
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> waveforms;
  final Color color;

  WaveformPainter({required this.waveforms, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (waveforms.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final barWidth = size.width / (waveforms.length * 2 - 1);
    final spacing = barWidth;

    for (int i = 0; i < waveforms.length; i++) {
      final waveform = waveforms[i];
      final barHeight = (waveform * size.height).clamp(2.0, size.height);
      final left = i * (barWidth + spacing);
      final top = (size.height - barHeight) / 2;
      final rect = Rect.fromLTWH(left, top, barWidth, barHeight);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}


// --- REFACTORED WIDGET: NotePage ---
class NotePage extends StatefulWidget {
  const NotePage({super.key});

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        setState(() {
          _currentIndex = _tabController.index;
        });
      }
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
                Tab(text: 'Cleaned'),
                Tab(text: 'Polished'),
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
                      // Use Markdown for the polished version
                      _buildPolishedCard(context, noteProvider.polishedTranscript),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () {
                    String textToCopy;
                    switch (_currentIndex) {
                      case 0:
                        textToCopy = noteProvider.rawTranscript;
                        break;
                      case 1:
                        textToCopy = noteProvider.cleanedTranscript;
                        break;
                      case 2:
                        textToCopy = noteProvider.polishedTranscript;
                        break;
                      default:
                        textToCopy = '';
                    }
                    Clipboard.setData(ClipboardData(text: textToCopy));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Transcript copied!')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy Transcript'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
      
      final service = TranscriptionService();

      if(mounted) setState(() { _currentStep = ProcessingStep.transcribing; });
      final rawTranscript = await service.transcribeAudio(widget.audioPath, apiKey);
      
      if(mounted) setState(() { _currentStep = ProcessingStep.cleaning; });
      final cleanedTranscript = await service.cleanTranscript(rawTranscript, apiKey);

      if(mounted) setState(() { _currentStep = ProcessingStep.polishing; });
      final polishedNote = await service.polishNote(cleanedTranscript, apiKey);
      
      if(mounted) setState(() { _currentStep = ProcessingStep.completed; });

      final result = {
        'rawTranscript': rawTranscript,
        'cleanedTranscript': cleanedTranscript,
        'polishedNote': polishedNote,
      };

      // Wait a moment so the user sees the "completed" state
      await Future.delayed(const Duration(milliseconds: 1200));

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
      });
    }
  }

  Future<void> _saveApiKey(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiKey', value);
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
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
  
  Future<String> _generateContent(String prompt, String apiKey, {String? audioPath}) async {
    if (apiKey.isEmpty) {
      throw Exception('API Key is missing. Please add it in Settings.');
    }
    
    final model = GenerativeModel(model: 'gemini-2.5-pro', apiKey: apiKey);
    
    final List<Part> parts = [TextPart(prompt)];
    if (audioPath != null) {
      final audioFile = File(audioPath);
      final audioBytes = await audioFile.readAsBytes();
      parts.add(DataPart('audio/mpeg', audioBytes));
    }

    try {
      final response = await model.generateContent([Content.multi(parts)]);
      return response.text ?? 'Could not process request.';
    } on GenerativeAIException catch (e) {
      // --- UPDATED ERROR HANDLING ---
      if (e.message.contains('Unhandled format for Content')) {
        throw Exception('There was an issue with the audio format. Please try recording again. If the problem persists, ensure the app is updated.');
      }
      throw Exception('AI model error: ${e.message}');
    } catch (e) {
      throw Exception('An unexpected error occurred: $e');
    }
  }

  Future<String> transcribeAudio(String audioPath, String apiKey) async {
    return await _generateContent('Transcribe this audio file accurately.', apiKey, audioPath: audioPath);
  }

  Future<String> cleanTranscript(String rawTranscript, String apiKey) async {
    final prompt = 'Clean up this transcript by removing filler words (like "um", "uh", "like") and correcting obvious grammatical mistakes. Do not change the core meaning or add new information. Keep the language natural. Here is the transcript:\n\n$rawTranscript';
    return await _generateContent(prompt, apiKey);
  }

  Future<String> polishNote(String cleanedTranscript, String apiKey) async {
    final prompt = 'Take this cleaned transcript and turn it into a polished, well-structured note. Use markdown formatting like headings (e.g., "## Key Points"), bullet points (e.g., "- Point 1"), or numbered lists where appropriate to make it clear and easy to read. Identify and list any action items. Here is the transcript:\n\n$cleanedTranscript';
    return await _generateContent(prompt, apiKey);
  }
}
