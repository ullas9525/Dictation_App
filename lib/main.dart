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

// --- Floating dictation bubble (Android) ---
//
// The bubble itself is native (OverlayService.kt). Dart supplies the settings,
// the recording/processing sheet (overlayMain) and the final insert action.

/// Which transcript the bubble should offer first / paste by default.
enum TranscriptFormat { raw, clean, polished }

/// Reads a stored format, falling back to [TranscriptFormat.polished] for old
/// installs or unknown values.
TranscriptFormat transcriptFormatFromPref(String? value) {
  for (final TranscriptFormat format in TranscriptFormat.values) {
    if (format.name == value) return format;
  }
  return TranscriptFormat.polished;
}

extension TranscriptFormatLabels on TranscriptFormat {
  /// Short label used by the result chips.
  String get label => switch (this) {
        TranscriptFormat.raw => 'Raw',
        TranscriptFormat.clean => 'Clean',
        TranscriptFormat.polished => 'Polished',
      };

  /// Full label used by Settings.
  String get settingLabel => switch (this) {
        TranscriptFormat.raw => 'Raw transcript',
        TranscriptFormat.clean => 'Clean transcript',
        TranscriptFormat.polished => 'Polished note',
      };
}

/// Packages the bubble reacts to when no preference has been saved yet.
const String defaultOverlayTargetApps = 'com.whatsapp';

/// Parses the comma-separated target list. Empty input falls back to WhatsApp
/// so the feature is never silently unusable after a bad write.
List<String> parseOverlayTargetApps(String? raw) {
  final List<String> result = <String>[];
  final Set<String> seen = <String>{};
  for (final String part in (raw ?? '').split(',')) {
    final String value = part.trim();
    if (value.isEmpty || !seen.add(value)) continue;
    result.add(value);
  }
  if (result.isEmpty) result.add(defaultOverlayTargetApps);
  return result;
}

/// Serialises the target list, trimming blanks/duplicates and never writing an
/// empty value that would disable the bubble without explanation.
String overlayTargetAppsValue(Iterable<String> packages) {
  final List<String> result = <String>[];
  final Set<String> seen = <String>{};
  for (final String packageName in packages) {
    final String value = packageName.trim();
    if (value.isEmpty || !seen.add(value)) continue;
    result.add(value);
  }
  if (result.isEmpty) return defaultOverlayTargetApps;
  return result.join(',');
}

/// `*` allows every app; otherwise require a plausible Android package name.
bool isValidOverlayTargetApp(String value) {
  final String trimmed = value.trim();
  if (trimmed == '*') return true;
  return RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$')
      .hasMatch(trimmed);
}

String overlayTargetAppLabel(String packageName) {
  switch (packageName) {
    case '*':
      return 'Any app';
    case 'com.whatsapp':
      return 'WhatsApp';
    default:
      return packageName;
  }
}

/// SharedPreferences keys used by both the Flutter settings screen and the
/// native bubble (which reads them from `FlutterSharedPreferences` with the
/// `flutter.` prefix).
class OverlayPrefs {
  static const String enabled = 'overlay_enabled';
  static const String targetFormat = 'overlay_target_format';
  static const String targetApps = 'overlay_target_apps';
}

/// Native permission/service state reported by `dictation_app/overlay`.
class OverlayStatus {
  const OverlayStatus({
    this.supported = true,
    this.canDrawOverlays = false,
    this.accessibilityEnabled = false,
    this.serviceRunning = false,
  });

  /// Used on non-Android platforms and when the platform channel is missing.
  static const OverlayStatus unsupported = OverlayStatus(supported: false);

  final bool supported;
  final bool canDrawOverlays;
  final bool accessibilityEnabled;
  final bool serviceRunning;

  /// Both manual grants are present.
  bool get ready => supported && canDrawOverlays && accessibilityEnabled;
}

/// Thin, failure-tolerant bridge to the native bubble.
///
/// Every call swallows `MissingPluginException` / `PlatformException`: on
/// desktop/tests there is no Android host, and a settings screen must still
/// render instead of crashing.
class OverlayBridge {
  static const MethodChannel _settings =
      MethodChannel('dictation_app/overlay');
  static const MethodChannel _activity =
      MethodChannel('dictation_app/overlay_activity');

  static Future<OverlayStatus> getStatus() async {
    if (!Platform.isAndroid) return OverlayStatus.unsupported;
    try {
      final Map<String, bool>? result =
          await _settings.invokeMapMethod<String, bool>('getStatus');
      if (result == null) return const OverlayStatus();
      return OverlayStatus(
        canDrawOverlays: result['canDrawOverlays'] ?? false,
        accessibilityEnabled: result['accessibilityEnabled'] ?? false,
        serviceRunning: result['serviceRunning'] ?? false,
      );
    } catch (_) {
      return OverlayStatus.unsupported;
    }
  }

  static Future<bool> requestOverlayPermission() =>
      _invokeBool(_settings, 'requestOverlayPermission');

  static Future<bool> openAccessibilitySettings() =>
      _invokeBool(_settings, 'openAccessibilitySettings');

  static Future<bool> startOverlay() => _invokeBool(_settings, 'startOverlay');

  static Future<bool> stopOverlay() => _invokeBool(_settings, 'stopOverlay');

  static Future<bool> requestNotificationPermission() =>
      _invokeBool(_settings, 'requestNotificationPermission');

  /// Puts [text] on the clipboard and queues the accessibility paste.
  /// Returns false when the accessibility service is not running.
  static Future<bool> insertText(String text) async {
    if (!Platform.isAndroid || text.isEmpty) return false;
    try {
      return await _activity.invokeMethod<bool>(
            'insertText',
            <String, dynamic>{'text': text},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> copyText(String text) async {
    if (!Platform.isAndroid || text.isEmpty) return false;
    try {
      return await _activity.invokeMethod<bool>(
            'copyText',
            <String, dynamic>{'text': text},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> accessibilityConnected() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _activity.invokeMethod<bool>('accessibilityConnected') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Closes the overlay activity (the target app then regains focus).
  static Future<void> closeOverlay() async {
    if (!Platform.isAndroid) return;
    try {
      await _activity.invokeMethod<void>('close');
    } catch (_) {
      // Already closed.
    }
  }

  static Future<bool> _invokeBool(MethodChannel channel, String method) async {
    if (!Platform.isAndroid) return false;
    try {
      return await channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// Strips Markdown formatting symbols so only plain text remains.
///
/// Removes heading markers (`#`), bold/italic markers (`**`, `*`),
/// bullet/list markers (`-`, `*`), code fences and backticks, blockquotes,
/// horizontal rules, and link wrappers. Strips stray hash and quote
/// characters, then collapses excess whitespace.
String _stripMarkdown(String text) {
  if (text.isEmpty) return text;
  return text
      // Fenced code blocks
      .replaceAll(RegExp(r'```+'), '')
      // Heading markers at the start of a line (#, ##, etc.)
      .replaceAllMapped(
          RegExp(r'^[ \t]*#{1,6}[ \t]+', multiLine: true), (_) => '')
      // Bold and italic markers
      .replaceAll(RegExp(r'\*\*|\*'), '')
      // Inline code backticks
      .replaceAll(RegExp(r'`+'), '')
      // Blockquote markers at the start of a line
      .replaceAllMapped(RegExp(r'^[ \t]*>[ \t]?', multiLine: true), (_) => '')
      // Horizontal rules (--- or *** on their own line)
      .replaceAllMapped(
          RegExp(r'^[ \t]*[-*]{3,}[ \t]*$', multiLine: true), (_) => '')
      // Bullet list markers at the start of a line (- or *)
      .replaceAllMapped(
          RegExp(r'^[ \t]*[-*][ \t]+', multiLine: true), (_) => '')
      // Links: [text](url) -> text
      .replaceAllMapped(
          RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
      // Stray formatting characters
      .replaceAll('#', '')
      .replaceAll('"', '')
      .replaceAll("'", '')
      // Normalize whitespace
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

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

  // --- NEW: which "brain" (provider + model) produced each tab ---
  String _rawProviderName = '';
  String _rawModel = '';
  String _cleanedProviderName = '';
  String _cleanedModel = '';
  String _polishedProviderName = '';
  String _polishedModel = '';

  String get rawTranscript => _rawTranscript;
  String get cleanedTranscript => _cleanedTranscript;
  String get polishedTranscript => _polishedTranscript;

  /// Provider + model that produced each tab, e.g. "Groq" /
  /// "whisper-large-v3". Empty until a note has been processed.
  String get rawProviderName => _rawProviderName;
  String get rawModel => _rawModel;
  String get cleanedProviderName => _cleanedProviderName;
  String get cleanedModel => _cleanedModel;
  String get polishedProviderName => _polishedProviderName;
  String get polishedModel => _polishedModel;

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

  void updatePolishedNote(String newNote, {String? providerName, String? model}) {
    _polishedTranscript = newNote;
    if (providerName != null) _polishedProviderName = providerName;
    if (model != null) _polishedModel = model;
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

    // --- NEW: which provider + model produced each tab ---
    _rawProviderName = transcripts['rawProvider'] ?? '';
    _rawModel = transcripts['rawModel'] ?? '';
    _cleanedProviderName = transcripts['cleanedProvider'] ?? '';
    _cleanedModel = transcripts['cleanedModel'] ?? '';
    _polishedProviderName = transcripts['polishedProvider'] ?? '';
    _polishedModel = transcripts['polishedModel'] ?? '';

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

  /// In-flight microphone initialisation. The overlay creates a provider and
  /// starts recording immediately, so `startRecording()` can race the
  /// constructor's permission request; sharing the future avoids asking twice
  /// (and avoids treating the second request as a denial).
  Future<void>? _initInFlight;

  Future<void> _initRecorder() {
    if (_isInitialized) return Future<void>.value();
    final Future<void>? existing = _initInFlight;
    if (existing != null) return existing;

    final Future<void> future = _doInitRecorder();
    _initInFlight = future;
    future.whenComplete(() {
      if (identical(_initInFlight, future)) _initInFlight = null;
    });
    return future;
  }

  Future<void> _doInitRecorder() async {
    print("DEBUG: Initializing recorder permissions...");
    try {
      final status = await ph.Permission.microphone.request();
      if (status != ph.PermissionStatus.granted) {
        print("DEBUG: Microphone permission NOT granted");
        return;
      }

      _recorder = AudioRecorder();
      _isInitialized = true;
      print("DEBUG: Recorder initialized");
      notifyListeners();
    } catch (e) {
      print("DEBUG: Error initializing recorder: $e");
    }
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

// --- LLM Provider Registry (provider-independent) ---

/// One LLM "brain" the app can talk to.
///
/// Every provider speaks the OpenAI-compatible
/// `POST {baseUrl}/chat/completions` protocol (OpenRouter, Gemini, Groq, OpenAI,
/// NVIDIA NIM, Together, a local vLLM...), which means a brand-new provider can
/// be connected at runtime from the "+" button in Settings and is immediately
/// usable for polishing — and as an automatic fallback.
class LlmProvider {
  final String id;
  String name;
  String baseUrl;
  String apiKey;
  String model;
  List<String> models;

  LlmProvider({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
    this.model = '',
    List<String>? models,
  }) : models = List<String>.from(models ?? const <String>[]);

  bool get isOpenRouter => baseUrl.contains('openrouter.ai');

  /// Editable base URL. It may be pasted with or without the trailing
  /// `/chat/completions` — both forms are normalised here.
  String get chatCompletionsUrl {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }

  /// A provider only takes part in the pipeline once it has an API key.
  bool get isConfigured =>
      apiKey.trim().isNotEmpty && chatCompletionsUrl.startsWith('http');

  /// Keeps [model] consistent with the known [models] list.
  void normalize() {
    if (model.trim().isEmpty && models.isNotEmpty) {
      model = models.first;
    } else if (model.trim().isNotEmpty && models.isNotEmpty && !models.contains(model)) {
      models = <String>[model, ...models];
    }
  }

  /// The two main providers (OpenRouter and Gemini) can be edited, but they
  /// cannot be removed. Only providers connected through "+" may be deleted.
  bool get isProtected => id == 'openrouter' || id == 'gemini';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'models': models,
      };

  factory LlmProvider.fromJson(Map<String, dynamic> json) {
    return LlmProvider(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'Provider').toString(),
      baseUrl: (json['baseUrl'] ?? '').toString(),
      apiKey: (json['apiKey'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
      models: (json['models'] as List<dynamic>? ?? const <dynamic>[])
          .map<String>((dynamic m) => m.toString())
          .toList(),
    );
  }
}

/// A suggested endpoint offered as a chip inside the "Connect a provider" sheet.
class ProviderPreset {
  final String name;
  final String baseUrl;
  final List<String> models;
  const ProviderPreset(this.name, this.baseUrl, this.models);
}

/// Persists the connected providers (`llm_providers`) plus the id of the primary
/// brain (`primary_provider_id`) in SharedPreferences.
class ProviderRegistry {
  static const String _providersKey = 'llm_providers';
  static const String _primaryKey = 'primary_provider_id';

  static const String openRouterBaseUrl = 'https://openrouter.ai/api/v1';
  static const String geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta/openai';

  static const List<String> openRouterModels = <String>[
    'cohere/north-mini-code:free',
    'cognitivecomputations/dolphin-mistral-24b-venice-edition:free',
    'google/gemma-4-26b-a4b-it:free',
    'google/gemma-4-31b-it:free',
    'liquid/lfm-2.5-1.2b-instruct:free',
    'liquid/lfm-2.5-1.2b-thinking:free',
    'meta-llama/llama-3.2-3b-instruct:free',
    'meta-llama/llama-3.3-70b-instruct:free',
    'nousresearch/hermes-3-llama-3.1-405b:free',
    'nvidia/llama-nemotron-embed-vl-1b-v2:free',
    'nvidia/llama-nemotron-rerank-vl-1b-v2:free',
    'nvidia/nemotron-3-nano-30b-a3b:free',
    'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
    'nvidia/nemotron-3-super-120b-a12b:free',
    'nvidia/nemotron-3-ultra-550b-a55b:free',
    'nvidia/nemotron-3.5-content-safety:free',
    'nvidia/nemotron-nano-9b-v2:free',
    'nvidia/nemotron-nano-12b-v2-vl:free',
    'openai/gpt-oss-20b:free',
    'openai/gpt-oss-120b:free',
    'poolside/laguna-xs.2:free',
    'poolside/laguna-m.1:free',
    'qwen/qwen3-coder:free',
    'qwen/qwen3-next-80b-a3b-instruct:free',
  ];

  static const List<String> geminiModels = <String>[
    'gemini-2.5-flash',
    'gemini-2.5-pro',
    'gemini-2.5-flash-lite',
    'gemini-2.0-flash',
  ];

  /// Parses the comma separated model list the provider sheet stores
  /// (`LlmProvider.models` rendered as text), keeping the order and dropping
  /// blanks — the model dropdown offers exactly these entries.
  static List<String> parseModelList(String raw) => raw
      .split(',')
      .map((String m) => m.trim())
      .where((String m) => m.isNotEmpty)
      .toList();

  /// The models shown by the model dropdown: the provider's list (comma
  /// separated text), guaranteed to contain the currently selected (default)
  /// model so the dropdown can display it even when the list was edited down.
  static List<String> modelChoices(String rawModels, String selected) {
    final List<String> choices = parseModelList(rawModels);
    if (selected.isNotEmpty && !choices.contains(selected)) {
      choices.insert(0, selected);
    }
    return choices;
  }

  /// Chips offered inside the "Connect a provider" sheet. "Custom" lets the user
  /// point the app at any other OpenAI-compatible endpoint.
  static const List<ProviderPreset> presets = <ProviderPreset>[
    ProviderPreset('Gemini', geminiBaseUrl, geminiModels),
    ProviderPreset('OpenRouter', openRouterBaseUrl, openRouterModels),
    ProviderPreset('Groq', 'https://api.groq.com/openai/v1', <String>[
      'llama-3.3-70b-versatile',
      'openai/gpt-oss-120b',
      'openai/gpt-oss-20b',
    ]),
    ProviderPreset('OpenAI', 'https://api.openai.com/v1', <String>[
      'gpt-4o-mini',
      'gpt-4o',
    ]),
    ProviderPreset('Mistral', 'https://api.mistral.ai/v1', <String>[
      'mistral-small-latest',
      'mistral-large-latest',
    ]),
    ProviderPreset('Custom', '', <String>[]),
  ];

  static const String openRouterModelsUrl =
      'https://openrouter.ai/api/v1/models';

  /// Extracts the IDs of currently free OpenRouter chat models from a decoded
  /// `/models` payload. A model counts as free only when both its prompt and
  /// completion prices are zero. Returned IDs are sorted and deduplicated.
  static List<String> freeOpenRouterModelIds(dynamic decoded) {
    if (decoded is! Map) return <String>[];
    final dynamic rawData = decoded['data'];
    if (rawData is! List) return <String>[];

    final Set<String> ids = <String>{};
    for (final dynamic entry in rawData) {
      if (entry is! Map) continue;
      final String id = (entry['id'] ?? '').toString().trim();
      final dynamic pricing = entry['pricing'];
      if (id.isEmpty || pricing is! Map) continue;
      if (!_isZeroPrice(pricing['prompt'])) continue;
      if (!_isZeroPrice(pricing['completion'])) continue;
      ids.add(id);
    }

    final List<String> sorted = ids.toList()..sort();
    return sorted;
  }

  /// Parses an OpenRouter `/models` response body into sorted free model IDs.
  /// Malformed payloads return an empty list so callers can show an error.
  static List<String> freeOpenRouterModelIdsFromJson(String body) {
    try {
      return freeOpenRouterModelIds(jsonDecode(body));
    } catch (_) {
      return <String>[];
    }
  }

  static bool _isZeroPrice(dynamic value) {
    if (value == null) return false;
    if (value is num) return value == 0;
    final String text = value.toString().trim().toLowerCase();
    if (text.isEmpty) return false;
    final double? parsed = double.tryParse(text);
    return parsed != null && parsed == 0;
  }

  static LlmProvider openRouterDefault() => LlmProvider(
        id: 'openrouter',
        name: 'OpenRouter',
        baseUrl: openRouterBaseUrl,
        model: openRouterModels.first,
        models: openRouterModels,
      );

  static LlmProvider geminiDefault() => LlmProvider(
        id: 'gemini',
        name: 'Gemini',
        baseUrl: geminiBaseUrl,
        model: geminiModels.first,
        models: geminiModels,
      );

  /// Loads the connected providers. On the first run after this upgrade the
  /// registry is seeded from the legacy flat settings.
  static Future<List<LlmProvider>> load(SharedPreferences prefs) async {
    final String? raw = prefs.getString(_providersKey);
    if (raw == null) return _migrateLegacy(prefs);

    List<LlmProvider> providers;
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return _migrateLegacy(prefs);
      providers = decoded
          .whereType<Map<String, dynamic>>()
          .map(LlmProvider.fromJson)
          .where((LlmProvider p) => p.id.isNotEmpty && p.baseUrl.isNotEmpty)
          .toList();
    } catch (_) {
      return _migrateLegacy(prefs);
    }
    for (final LlmProvider p in providers) {
      p.normalize();
    }
    return providers;
  }

  /// Seeds OpenRouter + Gemini from the legacy single-provider settings.
  ///
  /// NVIDIA used to be the hard-coded fallback; it is intentionally dropped here
  /// in favour of Gemini, plus anything the user connects with the "+" button.
  static Future<List<LlmProvider>> _migrateLegacy(SharedPreferences prefs) async {
    final LlmProvider openRouter = openRouterDefault();
    openRouter.apiKey = prefs.getString('openrouter_api_key') ?? '';
    final String? legacyModel = prefs.getString('openrouter_model');
    if (legacyModel != null && legacyModel.trim().isNotEmpty) {
      openRouter.model = legacyModel.trim();
    }
    openRouter.normalize();

    // `gemini_api_key` is left over from the old Gemini era and is reused if set.
    final LlmProvider gemini = geminiDefault();
    gemini.apiKey = prefs.getString('gemini_api_key') ?? '';
    gemini.normalize();

    final List<LlmProvider> providers = <LlmProvider>[openRouter, gemini];

    final String? legacyPrimary = prefs.getString('primary_api');
    String primaryId = openRouter.id;
    if (legacyPrimary == 'gemini') {
      primaryId = gemini.id;
    } else if (legacyPrimary == 'nvidia') {
      primaryId = openRouter.apiKey.isNotEmpty ? openRouter.id : gemini.id;
    } else if (openRouter.apiKey.isEmpty && gemini.apiKey.isNotEmpty) {
      primaryId = gemini.id;
    }

    await save(prefs, providers, primaryId);
    for (final String legacyKey in const <String>[
      'nvidia_api_key',
      'nvidia_model',
      'primary_api',
    ]) {
      await prefs.remove(legacyKey);
    }
    return providers;
  }

  static Future<void> save(
    SharedPreferences prefs,
    List<LlmProvider> providers,
    String primaryId,
  ) async {
    await prefs.setString(
      _providersKey,
      jsonEncode(providers.map((LlmProvider p) => p.toJson()).toList()),
    );
    await prefs.setString(_primaryKey, resolvePrimaryId(providers, primaryId));
  }

  /// Guarantees the stored primary id always points at an existing provider.
  static String resolvePrimaryId(List<LlmProvider> providers, String preferredId) {
    if (providers.isEmpty) return '';
    if (providers.any((LlmProvider p) => p.id == preferredId)) return preferredId;
    return providers.first.id;
  }

  /// Primary brain first, then every other provider in the order it was added.
  static List<LlmProvider> orderedForFallback(
      List<LlmProvider> providers, String primaryId) {
    if (providers.isEmpty) return <LlmProvider>[];
    final int index = providers.indexWhere((LlmProvider p) => p.id == primaryId);
    if (index <= 0) return List<LlmProvider>.from(providers);
    final LlmProvider primary = providers[index];
    return <LlmProvider>[
      primary,
      ...providers.where((LlmProvider p) => p.id != primary.id),
    ];
  }

  /// Human-readable chain, e.g. `OpenRouter → Gemini → My Local LLM`.
  static String flowLabel(List<LlmProvider> providers, String primaryId) {
    final List<String> names = orderedForFallback(providers, primaryId)
        .map((LlmProvider p) => p.name)
        .toList();
    if (names.isEmpty) return 'No provider connected yet — tap + to add one';
    return names.join(' → ');
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
          _autoCopyResult(noteProvider);
          widget.onNoteProcessed();
        }
      }
    }
  }

  Future<void> _autoCopyResult(NoteProvider noteProvider) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('auto_copy_enabled') ?? false;
    if (!enabled) return;
    final target = prefs.getString('auto_copy_target') ?? 'polished';
    final text = target == 'clean' ? noteProvider.cleanedTranscript : noteProvider.polishedTranscript;
    await Clipboard.setData(ClipboardData(text: _stripMarkdown(text)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${target == 'clean' ? 'Clean' : 'Polish'} note copied to clipboard 📋')),
      );
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
        _autoCopyResult(noteProvider);
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
                    : () => _showTryAgainSheet(noteProvider),
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
                // --- Which brain (provider + model) produced this tab ---
                _buildProviderInfo(noteProvider),
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

  // --- Try Again with any connected Brain ---
  Future<void> _showTryAgainSheet(NoteProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    final List<LlmProvider> all = await ProviderRegistry.load(prefs);
    final String primaryId = prefs.getString('primary_provider_id') ?? '';
    final List<LlmProvider> available = ProviderRegistry.orderedForFallback(all, primaryId)
        .where((LlmProvider p) => p.isConfigured)
        .toList();
    if (available.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Connect an LLM provider (e.g. Gemini) in Settings first.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    if (!mounted) return;

    LlmProvider sheetProvider = available.first;
    String sheetModel = sheetProvider.model;

    await showModalBottomSheet(
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
                  const Text('Try Again with Another Brain',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: sheetProvider.id,
                    decoration: InputDecoration(
                      labelText: 'Provider',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    items: available
                        .map((LlmProvider p) => DropdownMenuItem<String>(
                              value: p.id,
                              child: Text(p.name),
                            ))
                        .toList(),
                    onChanged: (String? v) {
                      if (v == null) return;
                      final LlmProvider picked =
                          available.firstWhere((LlmProvider p) => p.id == v);
                      setSheetState(() {
                        sheetProvider = picked;
                        sheetModel = picked.model.isNotEmpty
                            ? picked.model
                            : (picked.models.isNotEmpty ? picked.models.first : '');
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  if (sheetProvider.models.isEmpty)
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Model',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => sheetModel = v.trim(),
                    )
                  else
                    DropdownButtonFormField<String>(
                      value: sheetProvider.models.contains(sheetModel)
                          ? sheetModel
                          : sheetProvider.models.first,
                      decoration: InputDecoration(
                        labelText: 'Model',
                        border:
                            OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      items: sheetProvider.models
                          .map((String m) => DropdownMenuItem<String>(
                                value: m,
                                child: Text(m, overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: (v) => setSheetState(() => sheetModel = v!),
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
                        _rePolishWithProvider(provider, sheetProvider, sheetModel);
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

  /// Re-polishes with the chosen provider + model, automatically falling back to
  /// the other connected providers when that one is rate-limited.
  Future<void> _rePolishWithProvider(
      NoteProvider provider, LlmProvider target, String model) async {
    provider.setPolishing(true);
    try {
      final service = TranscriptionService();
      final ProviderResult result = await service.rePolishWithFallback(
        provider.rawTranscript,
        providerId: target.id,
        model: model,
      );
      provider.updatePolishedNote(result.content,
          providerName: result.providerName, model: result.model);
      _lastPolished = '';
      if (mounted) {
        setState(() { _showTranslated = false; _isEditing = false; });
        _tabController.animateTo(2);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('\u2728 Re-polished!'), backgroundColor: Colors.blue),
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



  /// Shows which provider + model produced the note on the currently selected
  /// tab, right above the Copy / Edit buttons. Renders nothing until a note has
  /// been processed (so a "no speech" result shows no blank label).
  Widget _buildProviderInfo(NoteProvider provider) {
    final int tab = _tabController.index;
    final String providerName = tab == 0
        ? provider.rawProviderName
        : tab == 1
            ? provider.cleanedProviderName
            : provider.polishedProviderName;
    final String model = tab == 0
        ? provider.rawModel
        : tab == 1
            ? provider.cleanedModel
            : provider.polishedModel;
    if (providerName.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade400, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.memory, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Provider: $providerName',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (model.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Model: $model',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
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

  // Retry options built from the provider registry: "<providerId>|<model>".
  List<String> _retryOptions = <String>[];
  String _selectedRetryOption = '';

  // Results of stages that already succeeded. Groq transcription is never
  // repeated: once the audio has been transcribed, a retry only re-runs the
  // LLM stage against a different provider/model.
  ProviderResult? _sttResult;
  ProviderResult? _cleanedResult;

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
      _currentStep = _sttResult == null
          ? ProcessingStep.uploading
          : ProcessingStep.processing;
    });

    try {
      final service = TranscriptionService();

      // Stage 1: Whisper STT — skipped when the audio was already transcribed.
      final ProviderResult sttResult =
          _sttResult ?? await service.transcribe(widget.audioPath);
      _sttResult = sttResult;
      final String rawTranscript = sttResult.content;

      // Stage 2: LLM Clean — skipped when it already succeeded.
      if (!mounted) return;
      setState(() => _currentStep = ProcessingStep.processing);
      final ProviderResult cleanedResult =
          _cleanedResult ?? await service.clean(rawTranscript);
      _cleanedResult = cleanedResult;

      // Stage 3: LLM Polish — shown as "Processing" (continues)
      final ProviderResult polishedResult = await service.polish(rawTranscript);

      // Stage 4: Done — shown as "Downloading" briefly
      if (!mounted) return;
      setState(() => _currentStep = ProcessingStep.completed);
      await Future.delayed(const Duration(milliseconds: 600));

      if (mounted) {
        Navigator.of(context).pop(<String, String>{
          'rawTranscript': rawTranscript,
          'rawProvider': sttResult.providerName,
          'rawModel': sttResult.model,
          'cleanedTranscript': cleanedResult.content,
          'cleanedProvider': cleanedResult.providerName,
          'cleanedModel': cleanedResult.model,
          'polishedNote': polishedResult.content,
          'polishedProvider': polishedResult.providerName,
          'polishedModel': polishedResult.model,
        });
      }
    } catch (e) {
      // Offer every model of every connected provider so a retry can switch
      // brains without leaving the flow.
      final List<String> retryOptions = await _loadRetryOptions();
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _retryOptions = retryOptions;
          if (!retryOptions.contains(_selectedRetryOption)) {
            _selectedRetryOption = retryOptions.isNotEmpty ? retryOptions.first : '';
          }
        });
      }
    }
  }

  /// `"<providerId>|<model>"` entries for every provider that has an API key.
  Future<List<String>> _loadRetryOptions() async {
    final prefs = await SharedPreferences.getInstance();
    final List<LlmProvider> providers = await ProviderRegistry.load(prefs);
    final String primaryId = prefs.getString('primary_provider_id') ?? '';
    final List<String> options = <String>[];
    for (final LlmProvider provider
        in ProviderRegistry.orderedForFallback(providers, primaryId)) {
      if (!provider.isConfigured) continue;
      final List<String> models =
          provider.models.isEmpty ? <String>[provider.model] : provider.models;
      for (final String model in models) {
        if (model.trim().isEmpty) continue;
        options.add('${provider.id}|$model');
      }
    }
    return options;
  }

  /// Applies the model picked on the error screen (making its provider the
  /// primary brain) and runs the pipeline again.
  Future<void> _retryWithSelectedModel() async {
    final List<String> parts = _selectedRetryOption.split('|');
    if (parts.length == 2) {
      final prefs = await SharedPreferences.getInstance();
      final List<LlmProvider> providers = await ProviderRegistry.load(prefs);
      final int index = providers.indexWhere((LlmProvider p) => p.id == parts[0]);
      if (index >= 0) {
        providers[index].model = parts[1];
        await ProviderRegistry.save(prefs, providers, providers[index].id);
      }
    }
    await _startProcessing();
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
                      Text(
                        _sttResult == null
                            ? _errorMessage
                            : _errorMessage.contains('QUOTA_EXHAUSTED')
                                ? 'Quota exhausted for this AI model. Please switch the model.'
                                : _errorMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.blueGrey.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle,
                                color: Colors.green, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _sttResult == null
                                    ? 'Groq still needs to transcribe the audio — Retry will send it to Groq again.'
                                    : 'Audio already transcribed by Groq — Retry skips Groq and only re-runs the AI note step.',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade700),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (_sttResult == null)
                        const Text(
                          'Speech-to-text failed, so there is nothing to polish yet. '
                          'Check your Groq API key in Settings, then Retry.',
                          textAlign: TextAlign.center,
                        )
                      else if (_retryOptions.isEmpty)
                        const Text(
                          'No LLM provider is configured. Connect one (e.g. Gemini) with the + button in Settings.',
                          textAlign: TextAlign.center,
                        )
                      else
                        ListTile(
                          title: const Text('Try another brain model'),
                          subtitle: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedRetryOption,
                              isExpanded: true,
                              items: _retryOptions.map((String option) {
                                return DropdownMenuItem<String>(
                                  value: option,
                                  child: Text(option.replaceFirst('|', ' · '),
                                      overflow: TextOverflow.ellipsis),
                                );
                              }).toList(),
                              onChanged: (String? newValue) {
                                if (newValue != null) {
                                  setState(() {
                                    _selectedRetryOption = newValue;
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
                            onPressed: _retryWithSelectedModel,
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                            child: Text(_sttResult == null
                                ? 'Retry transcription'
                                : 'Retry with this brain'),
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

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {

  // --- GROQ STATE (STT only) ---
  String _groqApiKey = '';
  String _selectedSttModel = 'whisper-large-v3';

  /// Owned by the state so an auto-save rebuild never rebuilds the text field's
  /// controller (which would throw the caret around while a key is typed).
  final TextEditingController _groqKeyController = TextEditingController();

  // --- LLM PROVIDER REGISTRY (provider-independent) ---
  /// Every connected "brain". Seeded with OpenRouter + Gemini, and extendable at
  /// runtime through the "+" button that sits next to a provider card.
  List<LlmProvider> _providers = <LlmProvider>[];
  String _primaryProviderId = '';
  bool _providersLoaded = false;
  bool _refreshingFreeOpenRouterModels = false;
  int? _openRouterModelsRefreshedAtMs;

  // --- AUTO-SAVE (Settings) ---
  /// Every change is persisted shortly after it is made, so the old
  /// manual "save" button is no longer needed. Saving is silent: nothing is
  /// shown in the app bar for it.
  Timer? _autoSaveTimer;

  // --- TRANSLATION VARIABLES ---
  bool _enableTranslation = false;
  String _selectedTargetLanguage = 'English';

  // --- AUTO-COPY VARIABLES ---
  bool _autoCopyEnabled = false;
  String _autoCopyTarget = 'polished'; // 'clean' or 'polished'

  // --- FLOATING DICTATION BUBBLE ---
  bool _overlayEnabled = false;
  TranscriptFormat _overlayTargetFormat = TranscriptFormat.polished;
  List<String> _overlayTargetApps = <String>[defaultOverlayTargetApps];
  OverlayStatus _overlayStatus = OverlayStatus.unsupported;
  bool _overlayBusy = false;

  final List<String> _groqSttModels = [
    'whisper-large-v3-turbo',
    'whisper-large-v3',
  ];

  final List<String> _targetLanguages = [
    'English',
    'Hindi',
    'Kannada',
    'Telugu',
    'Tamil',
    'Malayalam',
    'Marathi',
    'Bengali',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permissions are granted in Android Settings, so returning to the app is
    // the moment their status (and the service) needs refreshing.
    if (state == AppLifecycleState.resumed && _overlayEnabled) {
      _refreshOverlayStatus();
      _syncOverlayService();
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final providers = await ProviderRegistry.load(prefs);
    if (mounted) {
      setState(() {
        _groqApiKey = prefs.getString('groq_api_key') ?? '';
        _groqKeyController.text = _groqApiKey;
        _selectedSttModel = prefs.getString('groq_stt_model') ?? 'whisper-large-v3';
        _providers = providers;
        _primaryProviderId = ProviderRegistry.resolvePrimaryId(
            providers, prefs.getString('primary_provider_id') ?? '');
        _providersLoaded = true;
        _enableTranslation = prefs.getBool('enable_translation') ?? false;
        _selectedTargetLanguage = prefs.getString('target_language') ?? 'English';
        _autoCopyEnabled = prefs.getBool('auto_copy_enabled') ?? false;
        _autoCopyTarget = prefs.getString('auto_copy_target') ?? 'polished';
        _overlayEnabled = prefs.getBool(OverlayPrefs.enabled) ?? false;
        _overlayTargetFormat = transcriptFormatFromPref(
            prefs.getString(OverlayPrefs.targetFormat));
        _overlayTargetApps = parseOverlayTargetApps(
            prefs.getString(OverlayPrefs.targetApps));
        _openRouterModelsRefreshedAtMs =
            prefs.getInt('openrouter_free_models_refreshed_at_ms');
        
        if (!_groqSttModels.contains(_selectedSttModel)) _selectedSttModel = _groqSttModels.first;
        if (!_targetLanguages.contains(_selectedTargetLanguage)) _selectedTargetLanguage = _targetLanguages.first;
      });
    }

    // The native side owns the real permission/service state; fetch it after
    // the saved values are on screen, then make the service match the toggle.
    await _refreshOverlayStatus();
    await _syncOverlayService();
  }

  /// Persists everything a moment after a change is made (debounced so typing a
  /// key does not trigger a write per character).
  void _scheduleAutoSave() {
    if (!mounted) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      await _persistAllSettings();
    });
  }

  /// Writes the current state without any confirmation dialog or snackbar.
  Future<void> _persistAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('groq_api_key', _groqApiKey);
    await prefs.setString('groq_stt_model', _selectedSttModel);
    await ProviderRegistry.save(prefs, _providers, _primaryProviderId);
    await prefs.setBool('enable_translation', _enableTranslation);
    await prefs.setString('target_language', _selectedTargetLanguage);
    await prefs.setBool('auto_copy_enabled', _autoCopyEnabled);
    await prefs.setString('auto_copy_target', _autoCopyTarget);
    await prefs.setBool(OverlayPrefs.enabled, _overlayEnabled);
    await prefs.setString(
        OverlayPrefs.targetFormat, _overlayTargetFormat.name);
    await prefs.setString(
        OverlayPrefs.targetApps, overlayTargetAppsValue(_overlayTargetApps));
  }

  @override
  void dispose() {
    // Nothing is lost when the screen closes: a change that had not been
    // written yet is flushed immediately.
    final bool pending = _autoSaveTimer?.isActive ?? false;
    _autoSaveTimer?.cancel();
    if (pending) _persistAllSettings();
    WidgetsBinding.instance.removeObserver(this);
    _groqKeyController.dispose();
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
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildSectionTitle('AI Configuration'),
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
                const Text('Groq API Key (for STT)', style: TextStyle(fontSize: 14, color: Colors.grey)),
                TextField(
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'Paste your Groq API key here',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onChanged: (value) {
                    _groqApiKey = value;
                    _scheduleAutoSave();
                  },
                  controller: _groqKeyController,
                ),
                const Divider(height: 16),
                DropdownButtonFormField<String>(
                  value: _selectedSttModel,
                  decoration: const InputDecoration(
                    labelText: '🎙️ Speech-to-Text (Groq Whisper)',
                    border: InputBorder.none,
                  ),
                  items: _groqSttModels
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selectedSttModel = v);
                    _scheduleAutoSave();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(child: _buildSectionTitle('LLM Brain Providers')),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'Connect a new provider',
                onPressed: () => _showProviderSheet(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Tap a provider to add its API key once — after that it opens its settings directly. The primary brain is tried first; every other connected provider is used automatically if it fails for any reason.',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          if (!_providersLoaded)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12.0),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_providers.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade400, width: 1),
              ),
              child: Column(
                children: [
                  const Text('No provider connected yet.',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text(
                    'Tap + to connect Gemini, OpenRouter, or any other provider.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: () => _showProviderSheet(),
                    icon: const Icon(Icons.add),
                    label: const Text('Connect a provider'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red, foregroundColor: Colors.white),
                  ),
                ],
              ),
            )
          else
            ..._providers.map((LlmProvider provider) => _buildProviderRow(provider)),
          if (_providers.any((LlmProvider p) => p.isOpenRouter)) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _refreshingFreeOpenRouterModels
                    ? null
                    : _handleRefreshOpenRouterModels,
                icon: _refreshingFreeOpenRouterModels
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(
                  _refreshingFreeOpenRouterModels
                      ? 'Refreshing free models…'
                      : 'Retry free model list',
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "Downloads OpenRouter's current model catalog and keeps only free models. "
              'Last refreshed: ${_formatFreeModelRefreshTime(_openRouterModelsRefreshedAtMs)}.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'Flow: ${ProviderRegistry.flowLabel(_providers, _primaryProviderId)}',
            style: TextStyle(
                fontSize: 13, color: Colors.grey.shade600, fontStyle: FontStyle.italic),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _showProviderSheet(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Connect another provider'),
            ),
          ),
          const SizedBox(height: 24),
          _buildSectionTitle('Floating Dictation Bubble'),
          const SizedBox(height: 8),
          _buildOverlaySection(),
          const SizedBox(height: 24),
          _buildSectionTitle('Translation'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade400, width: 1),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Enable Translation'),
                  subtitle: const Text('Translate polished notes'),
                  value: _enableTranslation,
                  onChanged: (bool value) {
                    setState(() {
                      _enableTranslation = value;
                    });
                    _scheduleAutoSave();
                  },
                ),
                if (_enableTranslation)
                  DropdownButtonFormField<String>(
                    value: _selectedTargetLanguage,
                    decoration: const InputDecoration(labelText: 'Target Language'),
                    items: _targetLanguages
                        .map((lang) => DropdownMenuItem(value: lang, child: Text(lang)))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _selectedTargetLanguage = v);
                      _scheduleAutoSave();
                    },
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
          ),
          const SizedBox(height: 24),
          _buildSectionTitle('Clipboard'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade400, width: 1),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Auto-Copy to Clipboard'),
                  subtitle: const Text('Copy result after processing'),
                  value: _autoCopyEnabled,
                  onChanged: (bool value) {
                    setState(() => _autoCopyEnabled = value);
                    _scheduleAutoSave();
                  },
                ),
                if (_autoCopyEnabled)
                  DropdownButtonFormField<String>(
                    value: _autoCopyTarget,
                    decoration: const InputDecoration(labelText: 'Copy Target'),
                    items: const [
                      DropdownMenuItem(value: 'clean', child: Text('Clean Note')),
                      DropdownMenuItem(value: 'polished', child: Text('Polish Note')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _autoCopyTarget = v);
                      _scheduleAutoSave();
                    },
                  ),
              ],
            ),
          ),
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

  /// Compact, tappable entry for one provider.
  ///
  /// Tapping it asks for the API key **only while none is stored**; once a key
  /// has been saved the provider opens its settings directly. The "+" icon
  /// connects yet another provider.
  Widget _buildProviderRow(LlmProvider provider) {
    final bool isPrimary = provider.id == _primaryProviderId;
    final bool isConnected = provider.isConfigured;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isPrimary ? Colors.red : Colors.grey.shade400,
            width: isPrimary ? 1.5 : 1,
          ),
        ),
        child: ListTile(
          onTap: () => _openProvider(provider),
          contentPadding: const EdgeInsets.only(left: 12, right: 4),
          leading: Icon(
            isPrimary ? Icons.psychology : Icons.memory,
            color: isPrimary ? Colors.red : Colors.grey,
          ),
          title: Text(
            isPrimary ? '${provider.name} · primary brain' : provider.name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            isConnected
                ? '✅ Connected · ${provider.model}'
                : 'No API key yet — tap to add it',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: isConnected ? Colors.green.shade700 : Colors.orange.shade800,
            ),
          ),
          trailing: IconButton(
            icon: Icon(
              isPrimary ? Icons.star : Icons.star_border,
              color: isPrimary ? Colors.amber : Colors.grey,
            ),
            tooltip: isPrimary ? 'Primary brain' : 'Set as primary brain',
            onPressed: isPrimary ? null : () => _setPrimaryProvider(provider),
          ),
        ),
      ),
    );
  }

  /// Clicking a provider: ask for the API key only while none is stored, then
  /// open its settings directly.
  Future<void> _openProvider(LlmProvider provider) async {
    if (!provider.isConfigured) {
      final bool connected = await _connectProvider(provider);
      if (!connected || !mounted) return;
    }
    await _showProviderSheet(existing: provider);
  }

  /// Asks for a provider API key with a dialog and remembers it.
  /// Returns true when a key was saved (false when the user cancelled).
  Future<bool> _connectProvider(LlmProvider provider,
      {bool prefillExisting = false}) async {
    final String? key =
        await _askForApiKey(provider, prefillExisting: prefillExisting);
    if (key == null) return false;
    setState(() => provider.apiKey = key);
    await _persistProviders();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${provider.name} connected ✅')),
      );
    }
    return true;
  }

  /// Last 4 characters of a saved key, used for the masked display.
  String _maskedKey(String key) {
    final String trimmed = key.trim();
    if (trimmed.length <= 4) return '••••';
    return '••••${trimmed.substring(trimmed.length - 4)}';
  }

  /// Downloads the current OpenRouter `/models` catalog and keeps only models
  /// whose prompt and completion prices are both zero. Returns the new count.
  Future<int> _refreshFreeOpenRouterModels() async {
    if (_refreshingFreeOpenRouterModels) return -1;

    final int index =
        _providers.indexWhere((LlmProvider p) => p.id == 'openrouter');
    if (index < 0) {
      throw Exception('OpenRouter is not in the provider list.');
    }
    final LlmProvider provider = _providers[index];

    setState(() => _refreshingFreeOpenRouterModels = true);
    try {
      final Uri url = Uri.parse(ProviderRegistry.openRouterModelsUrl);
      final Map<String, String> headers = <String, String>{
        'Content-Type': 'application/json',
      };
      // The catalog endpoint is public; a key is only sent when one exists.
      if (provider.isConfigured) {
        headers['Authorization'] = 'Bearer ${provider.apiKey}';
      }
      final http.Response response =
          await http.get(url, headers: headers).timeout(const Duration(seconds: 30));

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Exception(
            'Invalid OpenRouter API key. Update the key, then refresh again.');
      }
      if (response.statusCode == 429) {
        throw Exception(
            'OpenRouter rate-limited the refresh request. Wait a minute and retry.');
      }
      if (response.statusCode != 200) {
        throw Exception(
            'OpenRouter returned status ${response.statusCode} while refreshing models.');
      }

      final List<String> freshModels =
          ProviderRegistry.freeOpenRouterModelIdsFromJson(response.body);
      if (freshModels.isEmpty) {
        throw Exception(
            'OpenRouter did not return any free models. The key may lack access, or the catalog may be temporarily unavailable.');
      }

      final int refreshedAtMs = DateTime.now().millisecondsSinceEpoch;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'openrouter_free_models_refreshed_at_ms', refreshedAtMs);
      setState(() {
        provider.models = freshModels;
        if (!freshModels.contains(provider.model)) {
          provider.model = freshModels.first;
        }
        _openRouterModelsRefreshedAtMs = refreshedAtMs;
      });
      await _persistProviders();
      return freshModels.length;
    } finally {
      if (mounted) {
        setState(() => _refreshingFreeOpenRouterModels = false);
      } else {
        _refreshingFreeOpenRouterModels = false;
      }
    }
  }

  /// Handles the Settings "Retry free model list" button.
  Future<void> _handleRefreshOpenRouterModels() async {
    try {
      final int count = await _refreshFreeOpenRouterModels();
      if (count < 0 || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('OpenRouter free models refreshed: $count available ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Could not refresh free models: ${e.toString().replaceFirst('Exception: ', '')}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _persistProviders() async {
    final prefs = await SharedPreferences.getInstance();
    await ProviderRegistry.save(prefs, _providers, _primaryProviderId);
  }

  Future<void> _setPrimaryProvider(LlmProvider provider) async {
    setState(() => _primaryProviderId = provider.id);
    await _persistProviders();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${provider.name} is now the primary brain 🧠')),
      );
    }
  }

  Future<void> _removeProvider(LlmProvider provider) async {
    if (provider.isProtected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  '${provider.name} is a main provider and cannot be removed.')),
        );
      }
      return;
    }
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Remove ${provider.name}?'),
            content: const Text('Its API key will be deleted from this device.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    setState(() {
      _providers.removeWhere((LlmProvider p) => p.id == provider.id);
      _primaryProviderId =
          ProviderRegistry.resolvePrimaryId(_providers, _primaryProviderId);
    });
    await _persistProviders();
  }

  /// The API-key dialog. Returns the trimmed key, or null when cancelled.
  Future<String?> _askForApiKey(LlmProvider provider,
      {bool prefillExisting = false}) async {
    final TextEditingController keyController = TextEditingController(
        text: prefillExisting ? provider.apiKey : '');
    bool obscure = true;
    String? error;

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text('${provider.name} API key'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prefillExisting
                        ? 'Update or replace the key stored on this device.'
                        : 'Paste your key once — the app remembers it for every future run.',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: keyController,
                    obscureText: obscure,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: 'Paste your ${provider.name} key',
                      border: const OutlineInputBorder(),
                      errorText: error,
                      suffixIcon: IconButton(
                        icon: Icon(
                            obscure ? Icons.visibility_off : Icons.visibility),
                        tooltip: obscure ? 'Show key' : 'Hide key',
                        onPressed: () =>
                            setDialogState(() => obscure = !obscure),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final String key = keyController.text.trim();
                    if (key.isEmpty) {
                      setDialogState(
                          () => error = 'Please paste your API key.');
                      return;
                    }
                    Navigator.pop(ctx, key);
                  },
                  child: const Text('Save key'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- Floating dictation bubble settings ---

  Widget _buildOverlaySection() {
    final bool android = Platform.isAndroid;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade400, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable floating bubble'),
            subtitle: Text(
              android
                  ? 'Show a mic bubble when a supported app focuses a text field.'
                  : 'Android only — the bubble needs overlay and accessibility permissions.',
            ),
            value: _overlayEnabled,
            onChanged:
                android && !_overlayBusy ? _setOverlayEnabled : null,
          ),
          if (!android)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'The normal Home-screen dictation still works here. '
                'The floating bubble and direct insertion are Android-only.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            )
          else if (_overlayEnabled) ...[
            const Divider(),
            _buildOverlayStatusRow(
              icon: Icons.layers_outlined,
              title: 'Display over other apps',
              granted: _overlayStatus.canDrawOverlays,
              actionLabel: 'Grant',
              onAction: _openOverlayPermission,
            ),
            _buildOverlayStatusRow(
              icon: Icons.accessibility_new,
              title: 'Dictation bubble accessibility',
              granted: _overlayStatus.accessibilityEnabled,
              actionLabel: 'Enable',
              onAction: _openAccessibilitySettings,
            ),
            Row(
              children: [
                Icon(
                  _overlayStatus.serviceRunning
                      ? Icons.check_circle
                      : Icons.info_outline,
                  size: 20,
                  color: _overlayStatus.serviceRunning
                      ? Colors.green
                      : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _overlayStatus.serviceRunning
                        ? 'Bubble service is running'
                        : 'Bubble service is stopped — grant both permissions, then refresh.',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                IconButton(
                  icon: _overlayBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  tooltip: 'Refresh permission status and start the service',
                  onPressed: _overlayBusy ? null : _syncOverlayService,
                ),
              ],
            ),
            if (_overlayStatus.ready && !_overlayStatus.serviceRunning)
              Text(
                'Both permissions are granted. Tap refresh to start the bubble service.',
                style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
              ),
            const Divider(),
            DropdownButtonFormField<TranscriptFormat>(
              value: _overlayTargetFormat,
              decoration: const InputDecoration(
                labelText: 'Default transcript',
                helperText:
                    'Preselected in the bubble. You can switch Raw / Clean / Polished per message before inserting.',
                helperMaxLines: 2,
              ),
              items: TranscriptFormat.values
                  .map((TranscriptFormat format) => DropdownMenuItem<TranscriptFormat>(
                        value: format,
                        child: Text(format.settingLabel),
                      ))
                  .toList(),
              onChanged: (TranscriptFormat? value) {
                if (value == null) return;
                setState(() => _overlayTargetFormat = value);
                _scheduleAutoSave();
              },
            ),
            const SizedBox(height: 14),
            const Text(
              'Apps that show the bubble',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 2),
            Text(
              'The bubble only appears when one of these apps focuses an editable, non-password field.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                ..._overlayTargetApps.map(
                  (String packageName) => InputChip(
                    avatar: Icon(
                      packageName == '*' ? Icons.public : Icons.chat_bubble_outline,
                      size: 18,
                    ),
                    label: Text(overlayTargetAppLabel(packageName)),
                    onDeleted: _overlayTargetApps.length > 1
                        ? () => _removeOverlayTargetApp(packageName)
                        : null,
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Add app'),
                  onPressed: _overlayBusy ? null : _addOverlayTargetApp,
                ),
              ],
            ),
            if (!_overlayTargetApps.contains('*'))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _overlayBusy ? null : _addAnyApp,
                  icon: const Icon(Icons.public, size: 18),
                  label: const Text('Allow any app'),
                ),
              ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline, size: 18, color: Colors.green.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Privacy: audio is captured only after you tap the bubble. '
                      'The accessibility service reads only the focused text field '
                      '(to place the bubble and paste the result); it does not store '
                      'screen content or audio. The transcript still goes through the '
                      'Groq / LLM providers configured above.',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOverlayStatusRow({
    required IconData icon,
    required String title,
    required bool granted,
    required String actionLabel,
    required Future<void> Function() onAction,
  }) {
    return Row(
      children: [
        Icon(icon, size: 20, color: granted ? Colors.green : Colors.orange),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
        if (granted)
          const Icon(Icons.check_circle, size: 18, color: Colors.green)
        else
          TextButton(
            onPressed: _overlayBusy ? null : () => onAction(),
            child: Text(actionLabel),
          ),
      ],
    );
  }

  Future<void> _setOverlayEnabled(bool value) async {
    setState(() => _overlayEnabled = value);
    // Persist immediately (not on the 300 ms debounce): the native
    // accessibility service reads this pref on the very next focus event.
    await _persistAllSettings();

    if (!Platform.isAndroid) return;
    if (!value) {
      await OverlayBridge.stopOverlay();
      await _refreshOverlayStatus();
      return;
    }

    // Android 13+ shows the foreground-service notification only when this
    // runtime permission is granted; a denial is not fatal.
    await OverlayBridge.requestNotificationPermission();
    final OverlayStatus status = await OverlayBridge.getStatus();
    if (!mounted) return;
    setState(() => _overlayStatus = status);

    if (!status.canDrawOverlays) {
      await _showOverlaySetupDialog();
      return;
    }
    if (!status.accessibilityEnabled) {
      await _showAccessibilityDialog();
      return;
    }
    await _syncOverlayService();
  }

  Future<void> _showOverlaySetupDialog() async {
    final bool openSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Two permissions are needed'),
            content: const Text(
              '1. Allow "Display over other apps" so the bubble can sit above WhatsApp.\n\n'
              '2. Turn on the "Dictation bubble" accessibility service so the app can '
              'detect a focused text field and paste the transcript.\n\n'
              'Audio is only captured after you tap the bubble.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Later'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open overlay settings'),
              ),
            ],
          ),
        ) ??
        false;
    if (openSettings) await _openOverlayPermission();
  }

  Future<void> _showAccessibilityDialog() async {
    final bool openSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('One more step'),
            content: const Text(
              'Turn on the "Dictation bubble" service in Accessibility so the app can '
              'see which text field is focused and paste the transcript. '
              'It never stores your screen content.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Later'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open Accessibility'),
              ),
            ],
          ),
        ) ??
        false;
    if (openSettings) await _openAccessibilitySettings();
  }

  Future<void> _openOverlayPermission() async {
    await OverlayBridge.requestOverlayPermission();
    // Status refreshes when the app resumes from Android Settings.
  }

  Future<void> _openAccessibilitySettings() async {
    await OverlayBridge.openAccessibilitySettings();
  }

  Future<void> _refreshOverlayStatus() async {
    if (!Platform.isAndroid) {
      if (mounted) {
        setState(() => _overlayStatus = OverlayStatus.unsupported);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _overlayBusy = true);
    final OverlayStatus status = await OverlayBridge.getStatus();
    if (!mounted) return;
    setState(() {
      _overlayStatus = status;
      _overlayBusy = false;
    });
  }

  /// Starts the foreground service when the feature is on and both permissions
  /// are granted; stops it when the toggle is off.
  Future<void> _syncOverlayService() async {
    if (!Platform.isAndroid) return;
    if (!_overlayEnabled) {
      await OverlayBridge.stopOverlay();
      await _refreshOverlayStatus();
      return;
    }
    final OverlayStatus status = await OverlayBridge.getStatus();
    if (!mounted) return;
    setState(() => _overlayStatus = status);
    if (!status.ready) return;
    if (!status.serviceRunning) {
      await OverlayBridge.startOverlay();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _refreshOverlayStatus();
    }
  }

  Future<void> _addOverlayTargetApp() async {
    final TextEditingController controller = TextEditingController();
    final String? value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add an app'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the app\'s Android package name. WhatsApp is '
              '"com.whatsapp".',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Package name',
                hintText: 'com.example.app',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (String text) =>
                  Navigator.pop(ctx, text.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    if (!isValidOverlayTargetApp(value)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That does not look like an Android package name.'),
          ),
        );
      }
      return;
    }
    if (_overlayTargetApps.contains(value)) return;
    setState(() {
      _overlayTargetApps.add(value);
    });
    _scheduleAutoSave();
  }

  void _addAnyApp() {
    if (_overlayTargetApps.contains('*')) return;
    setState(() {
      _overlayTargetApps.add('*');
    });
    _scheduleAutoSave();
  }

  void _removeOverlayTargetApp(String packageName) {
    setState(() {
      _overlayTargetApps.remove(packageName);
      if (_overlayTargetApps.isEmpty) {
        _overlayTargetApps.add(defaultOverlayTargetApps);
      }
    });
    _scheduleAutoSave();
  }

  String _formatFreeModelRefreshTime(int? refreshedAtMs) {
    if (refreshedAtMs == null) return 'never';
    final DateTime at =
        DateTime.fromMillisecondsSinceEpoch(refreshedAtMs, isUtc: true)
            .toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }

  /// Provider sheet: connects a brand-new provider (with preset chips) or opens
  /// the settings of an already connected provider.
  ///
  /// Stored API keys never appear here as editable text — key entry always goes
  /// through the dedicated `_askForApiKey` dialog, and the key is asked only
  /// until one has been saved.
  Future<void> _showProviderSheet({LlmProvider? existing}) async {
    final bool isNew = existing == null;
    final ProviderPreset defaultPreset = ProviderRegistry.presets.first;
    final TextEditingController nameController =
        TextEditingController(text: existing?.name ?? defaultPreset.name);
    final TextEditingController urlController =
        TextEditingController(text: existing?.baseUrl ?? defaultPreset.baseUrl);
    // The pickable models live in a controller so the picker can be a dropdown;
    // `selectedModel` is the default model shown while the dropdown is closed.
    final List<String> initialModels = (existing?.models ?? defaultPreset.models)
        .where((String m) => m.trim().isNotEmpty)
        .toList();
    // A provider with no model list yet (a hand-typed custom one) has nothing to
    // pick from, so that single model is typed once instead.
    final bool needsCustomModel = initialModels.isEmpty;
    final TextEditingController modelsController = TextEditingController(
        text: needsCustomModel ? (existing?.model ?? '') : initialModels.join(', '));
    String selectedModel = existing?.model ??
        (initialModels.isNotEmpty ? initialModels.first : '');
    // The full model list stays out of the initial view — it is revealed with
    // the "Edit models" action.
    bool showModelsEditor = false;
    String selectedPreset = existing?.name ?? defaultPreset.name;
    String? error;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final List<String> availableModels =
                ProviderRegistry.modelChoices(modelsController.text, selectedModel);
            if (selectedModel.isEmpty && availableModels.isNotEmpty) {
              selectedModel = availableModels.first;
            }

            /// Edit mode saves every valid change as it is made — no save button.
            void autoApply() {
              if (isNew) return;
              final String name = nameController.text.trim();
              final String url = urlController.text.trim();
              if (name.isEmpty || !url.startsWith('http') || selectedModel.isEmpty) {
                return;
              }
              _upsertProvider(
                existing: existing,
                name: name,
                baseUrl: url,
                model: selectedModel,
                models: ProviderRegistry.modelChoices(
                    modelsController.text, selectedModel),
                silent: true,
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isNew ? 'Connect a provider' : 'Edit ${existing.name}',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Any endpoint that speaks the OpenAI-compatible /chat/completions API works — the app uses it immediately.',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 12),
                    if (isNew) ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: ProviderRegistry.presets
                            .map((ProviderPreset preset) => ChoiceChip(
                                  label: Text(preset.name),
                                  selected: selectedPreset == preset.name,
                                  onSelected: (_) {
                                    setSheetState(() {
                                      selectedPreset = preset.name;
                                      nameController.text = preset.name;
                                      urlController.text = preset.baseUrl;
                                      modelsController.text = preset.models.join(', ');
                                      selectedModel = preset.models.isNotEmpty
                                          ? preset.models.first
                                          : '';
                                      error = null;
                                    });
                                  },
                                ))
                            .toList(),
                      ),
                      const SizedBox(height: 16),
                    ] else ...[
                      Row(
                        children: [
                          Icon(
                            existing.isConfigured
                                ? Icons.check_circle
                                : Icons.key_off,
                            size: 18,
                            color: existing.isConfigured
                                ? Colors.green.shade700
                                : Colors.orange.shade800,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              existing.isConfigured
                                  ? 'API key saved ${_maskedKey(existing.apiKey)}'
                                  : 'No API key saved yet',
                              style: TextStyle(
                                fontSize: 13,
                                color: existing.isConfigured
                                    ? Colors.grey.shade700
                                    : Colors.orange.shade800,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              await _connectProvider(existing,
                                  prefillExisting: existing.isConfigured);
                              if (mounted) setSheetState(() {});
                            },
                            child: Text(existing.isConfigured
                                ? 'Update key'
                                : 'Add API key'),
                          ),
                          if (existing.isConfigured)
                            TextButton(
                              onPressed: () async {
                                setState(() => existing.apiKey = '');
                                await _persistProviders();
                                setSheetState(() {});
                              },
                              child: const Text('Remove key'),
                            ),
                        ],
                      ),
                      const Divider(height: 8),
                      Text('Provider settings',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey.shade600)),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: nameController,
                      onChanged: (String _) {
                        setSheetState(() {});
                        autoApply();
                      },
                      decoration: const InputDecoration(
                        labelText: 'Provider name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: urlController,
                      keyboardType: TextInputType.url,
                      onChanged: (String _) {
                        setSheetState(() {});
                        autoApply();
                      },
                      decoration: const InputDecoration(
                        labelText: 'Base URL',
                        hintText: 'https://api.example.com/v1',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (needsCustomModel)
                      // Nothing to pick from yet — type the model once.
                      TextField(
                        controller: modelsController,
                        onChanged: (String v) {
                          final List<String> parsed = _parseModelList(v);
                          setSheetState(() {
                            if (parsed.isNotEmpty) selectedModel = parsed.first;
                            error = null;
                          });
                          autoApply();
                        },
                        decoration: const InputDecoration(
                          labelText: 'Model',
                          hintText: 'e.g. gemini-2.5-flash',
                          border: OutlineInputBorder(),
                        ),
                      )
                    else ...[
                      // Closed it shows only the default model; tap to expand
                      // the full list of models this provider offers.
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Default model',
                          border: OutlineInputBorder(),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: selectedModel,
                            isExpanded: true,
                            items: availableModels
                                .map((String m) => DropdownMenuItem<String>(
                                      value: m,
                                      child: Text(m,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 14)),
                                    ))
                                .toList(),
                            onChanged: (String? v) {
                              if (v == null) return;
                              setSheetState(() {
                                selectedModel = v;
                                error = null;
                              });
                              autoApply();
                            },
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setSheetState(
                              () => showModelsEditor = !showModelsEditor),
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: Text(showModelsEditor
                              ? 'Hide model list'
                              : 'Edit models (${availableModels.length} available)'),
                        ),
                      ),
                      if (showModelsEditor) ...[
                        const SizedBox(height: 4),
                        TextField(
                          controller: modelsController,
                          onChanged: (String v) {
                            final List<String> parsed = _parseModelList(v);
                            setSheetState(() {
                              if (parsed.isNotEmpty && !parsed.contains(selectedModel)) {
                                selectedModel = parsed.first;
                              }
                              error = null;
                            });
                            autoApply();
                          },
                          decoration: const InputDecoration(
                            labelText: 'Available models (comma separated)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ],
                    if (!isNew) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Changes are saved automatically — no need to press save.',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(error!, style: const TextStyle(color: Colors.red)),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.check),
                        label: Text(isNew ? 'Connect provider' : 'Done'),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white),
                        onPressed: () async {
                          final String name = nameController.text.trim();
                          final String url = urlController.text.trim();
                          final String model = selectedModel.trim();
                          if (name.isEmpty) {
                            setSheetState(
                                () => error = 'Please enter a provider name.');
                            return;
                          }
                          if (!url.startsWith('http')) {
                            setSheetState(() => error =
                                'Please enter a valid base URL starting with http.');
                            return;
                          }
                          if (model.isEmpty) {
                            setSheetState(
                                () => error = 'Please enter a model name.');
                            return;
                          }
                          final List<String> models =
                              List<String>.from(availableModels);
                          if (!models.contains(model)) models.insert(0, model);
                          if (!isNew) {
                            // Everything already persisted as it was typed;
                            // flush once more and close.
                            autoApply();
                            Navigator.pop(ctx);
                            return;
                          }
                          Navigator.pop(ctx);
                          final LlmProvider? saved = await _upsertProvider(
                            name: name,
                            baseUrl: url,
                            model: model,
                            models: models,
                          );
                          if (saved != null && !saved.isConfigured) {
                            // A provider created without a key is asked once,
                            // right after it is created.
                            await _openProvider(saved);
                          }
                        },
                      ),
                    ),
                    if (!isNew) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                setState(() => _primaryProviderId = existing.id);
                                await _persistProviders();
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(
                                            '${existing.name} is now the primary brain 🧠')),
                                  );
                                  setSheetState(() {});
                                }
                              },
                              icon: const Icon(Icons.star, size: 18),
                              label: const Text('Set as primary'),
                            ),
                          ),
                          if (!existing.isProtected) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  Navigator.pop(ctx);
                                  await _removeProvider(existing);
                                },
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.red),
                                label: const Text('Remove',
                                    style: TextStyle(color: Colors.red)),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    nameController.dispose();
    urlController.dispose();
    modelsController.dispose();
  }

  /// Parses a comma separated model list, keeping the order and dropping blanks.
  List<String> _parseModelList(String raw) =>
      ProviderRegistry.parseModelList(raw);

  /// Persists a newly connected provider (or the edits of an existing one).
  /// Keys are never edited here: pass `apiKey: null` to leave a stored key
  /// untouched, or a new value to replace it when a dialog has collected one.
  /// `silent` skips the confirmation snackbar (used by the sheet's auto-save).
  Future<LlmProvider?> _upsertProvider({
    LlmProvider? existing,
    required String name,
    required String baseUrl,
    required String model,
    required List<String> models,
    String? apiKey,
    bool silent = false,
  }) async {
    // Auto-save fires on every edit; a write that changes nothing is skipped so
    // the list is not rebuilt (and the open sheet not disturbed) for nothing.
    if (existing != null &&
        existing.name == name &&
        existing.baseUrl == baseUrl &&
        existing.model == model &&
        existing.apiKey == (apiKey ?? existing.apiKey) &&
        existing.models.join(',') == models.join(',')) {
      return existing;
    }
    LlmProvider? result;
    setState(() {
      if (existing != null) {
        existing.name = name;
        existing.baseUrl = baseUrl;
        existing.model = model;
        existing.models = List<String>.from(models);
        if (apiKey != null) existing.apiKey = apiKey;
        result = existing;
      } else {
        final LlmProvider created = LlmProvider(
          id: 'provider_${DateTime.now().millisecondsSinceEpoch}',
          name: name,
          baseUrl: baseUrl,
          apiKey: apiKey ?? '',
          model: model,
          models: models,
        );
        created.normalize();
        _providers.add(created);
        // The first provider ever connected becomes the primary brain.
        if (_primaryProviderId.isEmpty) _primaryProviderId = created.id;
        result = created;
      }
    });
    await _persistProviders();
    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name saved ✅')),
      );
    }
    return result;
  }
}

// --- Services ---

/// A piece of text together with the provider + model that produced it, so the
/// Note screen can show which "brain" wrote each tab (Groq for the raw
/// transcript, an LLM provider for the cleaned / polished note).
class ProviderResult {
  final String content;
  final String providerName; // e.g. "Groq", "OpenRouter", "Gemini"
  final String model;        // e.g. "whisper-large-v3", "meta-llama/...:free"

  const ProviderResult({
    required this.content,
    this.providerName = '',
    this.model = '',
  });

  /// True once a provider is known — a "no speech" early return leaves it empty
  /// so the UI can hide the label instead of showing a blank provider.
  bool get hasProvider => providerName.isNotEmpty;

  /// e.g. "OpenRouter · meta-llama/llama-3.2-3b-instruct:free".
  String get label => model.isEmpty ? providerName : '$providerName · $model';
}

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

  static const String _cleanSystemPrompt =
      'You are a professional editor. Clean up a raw voice transcript. '
      'Remove all filler words (um, uh, like, you know, sort of, kind of, actually, basically, literally). '
      'Fix grammar and sentence structure. Correct technical or phonetic errors. '
      'Keep the content and meaning exactly the same \u2014 do not add, remove, or rephrase substantive information. '
      'Do NOT use Markdown formatting. Output plain text only, with proper capitalization and punctuation.';

  /// Main entry point: 3 API calls — Whisper STT → LLM Clean → LLM Polish (both with fallback).
  Future<Map<String, String>> processNote(String audioPath) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('groq_api_key') ?? '';
    final sttModel = prefs.getString('groq_stt_model') ?? 'whisper-large-v3';

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

    // Stage 2: LLM Clean (API Call 2) with automatic fallback
    final cleanedTranscript =
        (await _callLLMWithFallback(rawTranscript, systemPrompt: _cleanSystemPrompt)).content;

    // Stage 3: LLM Polish (API Call 3) with automatic fallback
    final polishedNote = (await _callLLMWithFallback(rawTranscript)).content;

    return {
      'rawTranscript': rawTranscript,
      'cleanedTranscript': cleanedTranscript,
      'polishedNote': polishedNote,
    };
  }

  /// Stage 1 (public): Transcribe audio using Groq Whisper.
  Future<ProviderResult> transcribe(String audioPath) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('groq_api_key') ?? '';
    final sttModel = prefs.getString('groq_stt_model') ?? 'whisper-large-v3';
    if (apiKey.isEmpty) throw Exception('Groq API Key is not set. Please add it in Settings.');
    final String text = await _callWhisper(audioPath, apiKey, sttModel);
    return ProviderResult(content: text, providerName: 'Groq', model: sttModel);
  }

  /// Stage 2 (public): Clean transcript via LLM — remove fillers, fix grammar.
  Future<ProviderResult> clean(String rawTranscript) async {
    if (rawTranscript.trim().length < 3) {
      return ProviderResult(content: rawTranscript);
    }
    return _callLLMWithFallback(rawTranscript, systemPrompt: _cleanSystemPrompt);
  }

  /// Stage 3 (public): Polish transcript with auto-fallback between LLM providers.
  Future<ProviderResult> polish(String rawTranscript) async {
    if (rawTranscript.trim().length < 3) {
      return const ProviderResult(
          content: 'No speech was detected in the recording. Please try again.');
    }
    return _callLLMWithFallback(rawTranscript);
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

  /// The polish prompt, extended with the translation instruction when the user
  /// enabled translation in Settings.
  Future<String> _polishPromptWithTranslation() async {
    final prefs = await SharedPreferences.getInstance();
    final bool translate = prefs.getBool('enable_translation') ?? false;
    final String targetedLanguage = prefs.getString('target_language') ?? 'English';
    return translate
        ? _polishSystemPrompt + '\n\nAlso, translate the entire cleaned and structured output into $targetedLanguage. Ensure the final note is written completely in $targetedLanguage.'
        : _polishSystemPrompt;
  }

  /// Provider-agnostic LLM call.
  ///
  /// Every connected provider — built-in or added by the user with "+" — is
  /// reached through the same OpenAI-compatible `/chat/completions` contract, so
  /// a newly connected provider starts working without any code change.
  Future<String> _callProvider(LlmProvider provider, String transcript,
      {String? systemPrompt, String? modelOverride}) async {
    final String prompt = systemPrompt ?? await _polishPromptWithTranslation();
    final String model = (modelOverride ?? provider.model).trim();
    if (model.isEmpty) {
      throw Exception('No model selected for ${provider.name}. Please pick one in Settings.');
    }

    final url = Uri.parse(provider.chatCompletionsUrl);
    final Map<String, String> headers = <String, String>{
      'Authorization': 'Bearer ${provider.apiKey}',
      'Content-Type': 'application/json',
    };
    if (provider.isOpenRouter) {
      headers['HTTP-Referer'] = 'https://github.com/ullas9525/Dictation_App';
      headers['X-Title'] = 'Voice Notes App';
    }

    final response = await http
        .post(
          url,
          headers: headers,
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': prompt},
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
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception('Invalid ${provider.name} API Key. Please check Settings.');
    }
    if (response.statusCode == 429) {
      throw Exception('${provider.name} quota reached. Try another model or provider.');
    }
    throw Exception('${provider.name} LLM error (${response.statusCode}): ${response.body}');
  }

  /// Combines one failed provider attempt into a compact error line.
  static String providerFailureLine(String name, String model, Object error) {
    final String detail =
        error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
    final String trimmed =
        detail.length > 220 ? '${detail.substring(0, 220)}…' : detail;
    return '$name ($model): $trimmed';
  }

  /// Re-polish (✨ Try Again) with a specific provider + model. When that attempt
  /// fails with a recoverable provider error, the other connected providers
  /// are tried automatically.
  Future<ProviderResult> rePolishWithFallback(
    String rawTranscript, {
    required String providerId,
    required String model,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final List<LlmProvider> all = await ProviderRegistry.load(prefs);
    final String primaryId = prefs.getString('primary_provider_id') ?? '';
    final List<LlmProvider> configured =
        ProviderRegistry.orderedForFallback(all, primaryId)
            .where((LlmProvider p) => p.isConfigured)
            .toList();

    if (configured.isEmpty) {
      throw Exception(
          'No LLM provider is configured. Connect one (e.g. Gemini) with the + button in Settings.');
    }

    final LlmProvider chosen = configured.firstWhere(
      (LlmProvider p) => p.id == providerId,
      orElse: () => configured.first,
    );
    final List<LlmProvider> attempts = <LlmProvider>[
      chosen,
      ...configured.where((LlmProvider p) => p.id != chosen.id),
    ];

    return _runProviderChain(
      attempts,
      (LlmProvider provider) => _callProvider(
        provider,
        rawTranscript,
        modelOverride: provider.id == chosen.id ? model : null,
      ),
      // The chosen provider uses the picked model; any fallback uses its own.
      modelFor: (LlmProvider provider) =>
          provider.id == chosen.id ? model : provider.model,
    );
  }

  /// Shared fallback loop. Every recoverable provider error moves to the next
  /// provider. Non-recoverable errors stop immediately. When every attempt
  /// fails, all attempts are reported together.
  Future<ProviderResult> _runProviderChain(
    List<LlmProvider> attempts,
    Future<String> Function(LlmProvider provider) call, {
    String Function(LlmProvider provider)? modelFor,
  }) async {
    final List<String> failures = <String>[];
    for (final LlmProvider provider in attempts) {
      try {
        final String content = await call(provider);
        return ProviderResult(
          content: content,
          providerName: provider.name,
          model: (modelFor ?? (LlmProvider p) => p.model)(provider),
        );
      } catch (e) {
        // Every failure raised here belongs to one specific provider/model
        // (bad key, retired model, quota, 5xx, timeout, network, …), so the
        // next connected provider is always tried. Only when all of them fail
        // is an aggregated, per-provider error shown to the user.
        failures.add(TranscriptionService.providerFailureLine(
            provider.name, provider.model, e));
      }
    }

    throw Exception(
        'Every connected LLM provider failed (${attempts.map((LlmProvider p) => p.name).join(', ')}).\n${failures.join('\n')}');
  }

  /// Tries the primary provider first, then every other connected provider
  /// (Gemini, OpenRouter, or anything added later with "+") until one succeeds.
  Future<ProviderResult> _callLLMWithFallback(String transcript,
      {String? systemPrompt}) async {
    final prefs = await SharedPreferences.getInstance();
    final List<LlmProvider> all = await ProviderRegistry.load(prefs);
    final String primaryId = prefs.getString('primary_provider_id') ?? '';
    final List<LlmProvider> providers =
        ProviderRegistry.orderedForFallback(all, primaryId)
            .where((LlmProvider p) => p.isConfigured)
            .toList();

    if (providers.isEmpty) {
      throw Exception(
          'No LLM provider is configured. Connect one (e.g. Gemini) with the + button in Settings.');
    }

    return _runProviderChain(
      providers,
      (LlmProvider provider) =>
          _callProvider(provider, transcript, systemPrompt: systemPrompt),
    );
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

// --- Floating dictation sheet (second Flutter entrypoint) ---
//
// Launched by OverlayService when the mic bubble is tapped. It is intentionally
// separate from the full app: a small bottom sheet that records, runs the
// existing STT -> Clean -> Polish pipeline, previews all three formats, and
// hands the chosen text to the accessibility service.

/// Runs inside OverlayDictationActivity. Keep this entrypoint tiny: it only
/// needs the recorder and the transcription service.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider<RecordingProvider>(
      create: (_) => RecordingProvider(),
      child: const _OverlayDictationApp(),
    ),
  );
}

class _OverlayDictationApp extends StatelessWidget {
  const _OverlayDictationApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const OverlayDictationPage(),
    );
  }
}

enum _OverlayStage { starting, recording, processing, error }

class OverlayDictationPage extends StatefulWidget {
  const OverlayDictationPage({super.key});

  @override
  State<OverlayDictationPage> createState() => _OverlayDictationPageState();
}

class _OverlayDictationPageState extends State<OverlayDictationPage> {
  final TranscriptionService _service = TranscriptionService();
  final Map<TranscriptFormat, ProviderResult> _results =
      <TranscriptFormat, ProviderResult>{};

  _OverlayStage _stage = _OverlayStage.starting;
  TranscriptFormat _selectedFormat = TranscriptFormat.polished;
  String? _audioPath;
  String _errorMessage = '';
  bool _startingRecording = false;
  bool _finishing = false;
  bool _closed = false;

  // ── Draggable pill ────────────────────────────────────────────────────────
  // We use bottom/right Positioned anchoring by default so the pill always
  // appears near the keyboard regardless of what MediaQuery reports in the
  // translucent overlay activity. Once the user drags, we switch to absolute
  // top/left so free movement works everywhere on screen.
  bool _hasBeenDragged = false;
  Offset _dragPos = Offset.zero; // absolute top/left, only used after drag

  @override
  void initState() {
    super.initState();
    _loadPrefsAndStart();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadPrefsAndStart() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final TranscriptFormat format =
        transcriptFormatFromPref(prefs.getString(OverlayPrefs.targetFormat));
    if (!mounted) return;
    setState(() {
      _selectedFormat = format;
    });
    await _startRecording();
  }

  Future<void> _startRecording() async {
    if (_startingRecording || _closed) return;
    _startingRecording = true;
    _finishing = false;
    await _deleteAudio();
    if (!mounted) return;
    setState(() {
      _stage = _OverlayStage.starting;
      _errorMessage = '';
      _results.clear();
    });

    final RecordingProvider recorder = context.read<RecordingProvider>();
    await recorder.startRecording();
    if (!mounted || _closed) return;

    if (!recorder.isSessionActive) {
      setState(() {
        _stage = _OverlayStage.error;
        _startingRecording = false;
        _errorMessage =
            'The microphone could not start. Allow microphone access for this app in '
            'Android Settings, then try again.';
      });
      return;
    }

    setState(() {
      _stage = _OverlayStage.recording;
      _startingRecording = false;
    });
  }

  /// ✓ tap: stop recording and auto-insert the default format — no preview,
  /// no confirmation. The user only taps once more after the mic.
  Future<void> _submit() async {
    if (_finishing || _closed) return;
    _finishing = true;
    if (mounted) {
      setState(() {
        _stage = _OverlayStage.processing;
      });
    }
    final RecordingProvider recorder = context.read<RecordingProvider>();
    final String? path = await recorder.stopRecording();
    if (!mounted || _closed) return;
    if (path == null || path.isEmpty) {
      setState(() {
        _stage = _OverlayStage.error;
        _finishing = false;
        _errorMessage = 'The recording could not be saved. Please try again.';
      });
      return;
    }
    _audioPath = path;
    await _finishAndInsert();
  }

  Future<void> _finishAndInsert() async {
    final String? path = _audioPath;
    if (path == null) {
      await _startRecording();
      return;
    }

    if (mounted) {
      setState(() {
        _stage = _OverlayStage.processing;
        _errorMessage = '';
      });
    }

    try {
      final ProviderResult raw = await _service.transcribe(path);
      if (!mounted || _closed) return;
      if (raw.content.trim().length < 3) {
        _finishing = false;
        setState(() {
          _stage = _OverlayStage.error;
          _errorMessage =
              'No speech was detected. Tap the bubble again and speak a little closer.';
        });
        return;
      }
      _results[TranscriptFormat.raw] = raw;
      // The raw transcript is cached, so the audio is no longer needed even if
      // a later LLM stage has to be retried.
      await _deleteAudio();

      if (!mounted || _closed) return;
      final ProviderResult text = switch (_selectedFormat) {
        TranscriptFormat.raw => raw,
        TranscriptFormat.clean => await _service.clean(raw.content),
        TranscriptFormat.polished => await _service.polish(raw.content),
      };
      if (!mounted || _closed) return;
      _results[_selectedFormat] = text;

      await _insertText(_stripMarkdown(text.content.trim()));
    } catch (e) {
      if (!mounted || _closed) return;
      _finishing = false;
      setState(() {
        _stage = _OverlayStage.error;
        _errorMessage = _friendlyError(e);
      });
    }
  }

  Future<void> _retryAfterError() async {
    final String? path = _audioPath;
    if (path != null && File(path).existsSync()) {
      _finishing = true;
      await _finishAndInsert();
    } else {
      await _startRecording();
    }
  }

  Future<void> _insertText(String text) async {
    if (text.isEmpty) {
      _finishing = false;
      return;
    }

    final bool queued = await OverlayBridge.insertText(text);
    if (!mounted || _closed) return;

    if (!queued) {
      // Accessibility is off or the field vanished. Leave the text on the
      // clipboard so it can be pasted, then close without a copy step.
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted || _closed) return;
      await _close();
      return;
    }

    // Native queues the paste ~700 ms after this call. Let the sheet close
    // first so the target app regains input focus.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _close();
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    try {
      final RecordingProvider recorder = context.read<RecordingProvider>();
      if (recorder.isSessionActive) await recorder.cancelRecording();
    } catch (_) {
      // The provider may already be gone while the activity is finishing.
    }
    await _deleteAudio();
    await OverlayBridge.closeOverlay();
  }

  Future<void> _deleteAudio() async {
    final String? path = _audioPath;
    _audioPath = null;
    if (path == null) return;
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Temp files are harmless; never fail the sheet for cleanup.
    }
  }

  String _friendlyError(Object error) =>
      error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();

  @override
  Widget build(BuildContext context) {
    final RecordingProvider recorder = context.watch<RecordingProvider>();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: LayoutBuilder(
          builder: (BuildContext ctx, BoxConstraints constraints) {
            final Widget pill = _buildStage(recorder);

            // Before the user drags: anchor middle-right so the pill starts
            // at the vertical centre of the screen (like Whisper Flow).
            // Once dragged it switches to absolute top/left for free movement.
            if (!_hasBeenDragged) {
              return Stack(
                children: <Widget>[
                  Positioned(
                    // Middle-right, like Whisper Flow — user can drag anywhere.
                    right: 16,
                    top: constraints.maxHeight / 2 - 22,
                    child: GestureDetector(
                      onPanStart: (DragStartDetails details) {
                        // Convert from bottom/right anchor to absolute top/left
                        // so we can move freely anywhere after the first drag.
                        final RenderBox? box =
                            ctx.findRenderObject() as RenderBox?;
                        if (box != null) {
                          final Offset local =
                              box.globalToLocal(details.globalPosition);
                          setState(() {
                            _dragPos = Offset(
                              (local.dx - 80).clamp(
                                  0, constraints.maxWidth - 20),
                              (local.dy - 22).clamp(
                                  0, constraints.maxHeight - 20),
                            );
                            _hasBeenDragged = true;
                          });
                        }
                      },
                      child: pill,
                    ),
                  ),
                ],
              );
            }

            // After first drag: absolute top/left positioning.
            return Stack(
              children: <Widget>[
                Positioned(
                  left: _dragPos.dx.clamp(
                      0, (constraints.maxWidth - 20).clamp(0, double.infinity)),
                  top: _dragPos.dy.clamp(
                      0, (constraints.maxHeight - 20).clamp(0, double.infinity)),
                  child: GestureDetector(
                    onPanUpdate: (DragUpdateDetails details) {
                      setState(() {
                        _dragPos = Offset(
                          (_dragPos.dx + details.delta.dx).clamp(
                              0, constraints.maxWidth - 20),
                          (_dragPos.dy + details.delta.dy).clamp(
                              0, constraints.maxHeight - 20),
                        );
                      });
                    },
                    child: pill,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The compact pill that sits above the keyboard. While recording it holds
  /// exactly three things: a cancel ✕, the voice visualizer and a ✓ that
  /// finishes and inserts without any further prompt.
  Widget _pill({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        // Slightly lighter frosted look — closer to the reference screenshot.
        color: const Color(0xFF2A2D35),
        borderRadius: BorderRadius.circular(30),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.white10, width: 0.8),
      ),
      child: child,
    );
  }

  Widget _buildStage(RecordingProvider recorder) {
    switch (_stage) {
      case _OverlayStage.starting:
        return _buildStarting();
      case _OverlayStage.recording:
        return _buildRecording(recorder);
      case _OverlayStage.processing:
        return _buildProcessing();
      case _OverlayStage.error:
        return _buildError();
    }
  }

  double _visualLevel(double decibel) {
    // Typical speech sits around -30 … -10 dBFS in this stream.
    final double normalized = (decibel + 45) / 45;
    return normalized.clamp(0.08, 1.0);
  }

  Widget _buildStarting() {
    return _pill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Cancel button — white circle with dark ✕
          _circleButton(
            icon: Icons.close,
            bgColor: Colors.white,
            iconColor: const Color(0xFF1A1A1A),
            onTap: _close,
            tooltip: 'Close',
          ),
          const SizedBox(width: 10),
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFB0B0B0)),
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Starting…',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildRecording(RecordingProvider recorder) {
    final double level = _visualLevel(recorder.decibelLevel);
    return _pill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Cancel — white circle with dark ✕ (matches reference)
          _circleButton(
            icon: Icons.close,
            bgColor: Colors.white,
            iconColor: const Color(0xFF1A1A1A),
            onTap: _close,
            tooltip: 'Cancel',
          ),
          const SizedBox(width: 8),
          // Animated waveform dots
          _WaveformDots(level: level),
          const SizedBox(width: 8),
          // ✓ stops and auto-inserts — no preview step, no second confirmation.
          _circleButton(
            icon: Icons.check,
            bgColor: const Color(0xFF6B3FA0), // purple, matching reference
            iconColor: Colors.white,
            onTap: _submit,
            tooltip: 'Done',
            size: 44,
          ),
        ],
      ),
    );
  }

  Widget _buildProcessing() {
    // Processing pill mirrors the recording pill: ✕  [pulsing dots]  ✓
    // but both action buttons are disabled (greyed out) and the dots pulse
    // with a fixed animation to show activity.
    return _pill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _circleButton(
            icon: Icons.close,
            bgColor: Colors.white24,
            iconColor: Colors.white38,
            onTap: null, // disabled during processing
            tooltip: 'Cancel',
          ),
          const SizedBox(width: 8),
          const _ProcessingDots(),
          const SizedBox(width: 8),
          _circleButton(
            icon: Icons.check,
            bgColor: const Color(0xFF6B3FA0).withValues(alpha: 0.4),
            iconColor: Colors.white38,
            onTap: null, // disabled during processing
            tooltip: 'Done',
            size: 44,
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return _pill(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.error_outline, size: 16, color: Colors.orange),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _errorMessage,
                      style: const TextStyle(fontSize: 11, color: Colors.white70),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  GestureDetector(
                    onTap: _close,
                    child: const Text(
                      'Close',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: _retryAfterError,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.refresh, size: 13, color: Color(0xFF6B3FA0)),
                        SizedBox(width: 3),
                        Text(
                          'Try again',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF6B3FA0),
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A labelled circular icon button — used for ✕ cancel and ✓ done.
  Widget _circleButton({
    required IconData icon,
    required Color bgColor,
    required Color iconColor,
    required VoidCallback? onTap,
    required String tooltip,
    double size = 40,
  }) {
    final Widget circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
        boxShadow: onTap != null
            ? [
                BoxShadow(
                  color: bgColor.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Icon(icon, size: size * 0.48, color: iconColor),
    );
    if (onTap == null) return circle;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: circle,
      ),
    );
  }
}

/// Animated waveform dots (Whisper Flow style) driven by the recorder's
/// amplitude. Shows 7 dots whose height pulses with the voice level.
class _WaveformDots extends StatelessWidget {
  const _WaveformDots({required this.level});

  /// 0 (silence) … 1 (loud).
  final double level;

  // Shape weights for each dot — centre dot is tallest.
  static const List<double> _weights = <double>[
    0.30, 0.55, 0.80, 1.00, 0.80, 0.55, 0.30,
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 28,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List<Widget>.generate(_weights.length, (int i) {
          final double h = (4 + 22 * _weights[i] * level).clamp(4.0, 26.0);
          return AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(horizontal: 2.5),
            width: 4,
            height: h,
            decoration: BoxDecoration(
              // Matches the grey dots visible in the reference screenshot.
              color: Colors.white.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }
}

/// Three bouncing dots that indicate AI processing — shown in the processing
/// pill instead of a bare spinner.
class _ProcessingDots extends StatefulWidget {
  const _ProcessingDots();

  @override
  State<_ProcessingDots> createState() => _ProcessingDotsState();
}

class _ProcessingDotsState extends State<_ProcessingDots>
    with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _animations;

  static const int _dotCount = 7;
  static const List<double> _baseWeights = <double>[
    0.30, 0.55, 0.80, 1.00, 0.80, 0.55, 0.30,
  ];

  @override
  void initState() {
    super.initState();
    _controllers = List<AnimationController>.generate(_dotCount, (int i) {
      return AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      )..repeat(reverse: true);
    });
    // Stagger each dot by 80 ms so they ripple left-to-right.
    for (int i = 0; i < _dotCount; i++) {
      Future<void>.delayed(Duration(milliseconds: i * 80), () {
        if (mounted) _controllers[i].forward();
      });
    }
    _animations = _controllers.map((AnimationController c) {
      return Tween<double>(begin: 0.15, end: 1.0).animate(
        CurvedAnimation(parent: c, curve: Curves.easeInOut),
      );
    }).toList();
  }

  @override
  void dispose() {
    for (final AnimationController c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 28,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List<Widget>.generate(_dotCount, (int i) {
          return AnimatedBuilder(
            animation: _animations[i],
            builder: (BuildContext ctx, Widget? _) {
              final double h =
                  (4 + 22 * _baseWeights[i] * _animations[i].value)
                      .clamp(4.0, 26.0);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 2.5),
                width: 4,
                height: h,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.40),
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

