// Tests for showing which provider + model produced each note tab, above the
// Copy / Edit buttons on the Note screen.
//
// Run with: flutter test test/note_provider_label_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_notes_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProviderResult', () {
    test('carries the provider + model and flags a missing provider', () {
      const ProviderResult configured = ProviderResult(
        content: 'note',
        providerName: 'Gemini',
        model: 'gemini-2.5-flash',
      );
      expect(configured.hasProvider, isTrue);
      expect(configured.label, 'Gemini · gemini-2.5-flash');
      // A model-less result still names the provider.
      expect(const ProviderResult(content: 'x', providerName: 'Groq').label,
          'Groq');

      // A "no speech" early return has no provider at all.
      const ProviderResult noSpeech = ProviderResult(content: 'No speech');
      expect(noSpeech.hasProvider, isFalse);
      expect(noSpeech.label, '');
    });
  });

  group('NoteProvider stores the brain of every tab', () {
    test('updateTranscripts records the provider + model of each tab', () {
      final NoteProvider provider = NoteProvider()
        ..updateTranscripts(<String, String>{
          'rawTranscript': 'raw',
          'rawProvider': 'Groq',
          'rawModel': 'whisper-large-v3',
          'cleanedTranscript': 'clean',
          'cleanedProvider': 'OpenRouter',
          'cleanedModel': 'meta-llama/llama-3.2-3b-instruct:free',
          'polishedNote': 'polished',
          'polishedProvider': 'Gemini',
          'polishedModel': 'gemini-2.5-flash',
        });

      expect(provider.rawProviderName, 'Groq');
      expect(provider.rawModel, 'whisper-large-v3');
      expect(provider.cleanedProviderName, 'OpenRouter');
      expect(provider.cleanedModel, 'meta-llama/llama-3.2-3b-instruct:free');
      expect(provider.polishedProviderName, 'Gemini');
      expect(provider.polishedModel, 'gemini-2.5-flash');
    });

    test('updatePolishedNote refreshes the label after a re-polish', () {
      final NoteProvider provider = NoteProvider()
        ..updatePolishedNote('first')
        ..updatePolishedNote('second',
            providerName: 'OpenRouter', model: 'qwen/qwen3-coder:free');

      expect(provider.polishedTranscript, 'second');
      expect(provider.polishedProviderName, 'OpenRouter');
      expect(provider.polishedModel, 'qwen/qwen3-coder:free');
    });

    test('a transcript without provider keys leaves the label empty', () {
      final NoteProvider provider = NoteProvider()
        ..updateTranscripts(<String, String>{'rawTranscript': 'raw'});

      expect(provider.rawProviderName, '');
      expect(provider.cleanedProviderName, '');
      expect(provider.polishedProviderName, '');
    });
  });

  group('NotePage shows the label above the Copy / Edit buttons', () {
    Future<void> pumpNotePage(WidgetTester tester, NoteProvider provider) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        ChangeNotifierProvider<NoteProvider>.value(
          value: provider,
          child: const MaterialApp(home: NotePage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    NoteProvider populated() => NoteProvider()
      ..updateTranscripts(<String, String>{
        'rawTranscript': 'raw text',
        'rawProvider': 'Groq',
        'rawModel': 'whisper-large-v3',
        'cleanedTranscript': 'clean text',
        'cleanedProvider': 'OpenRouter',
        'cleanedModel': 'meta-llama/llama-3.2-3b-instruct:free',
        'polishedNote': '# Title',
        'polishedProvider': 'Gemini',
        'polishedModel': 'gemini-2.5-flash',
      });

    testWidgets('the Raw tab names the Groq STT model', (tester) async {
      await pumpNotePage(tester, populated());

      expect(find.text('Provider: Groq'), findsOneWidget);
      expect(find.text('Model: whisper-large-v3'), findsOneWidget);
      // The action buttons remain right below the label.
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('the Cleaned tab names the cleaning provider', (tester) async {
      await pumpNotePage(tester, populated());
      await tester.tap(find.text('Cleaned'));
      await tester.pumpAndSettle();

      expect(find.text('Provider: OpenRouter'), findsOneWidget);
      expect(
          find.text('Model: meta-llama/llama-3.2-3b-instruct:free'),
          findsOneWidget);
    });

    testWidgets('the Polished tab names the polishing provider',
        (tester) async {
      await pumpNotePage(tester, populated());
      await tester.tap(find.text('Polished Note'));
      await tester.pumpAndSettle();

      expect(find.text('Provider: Gemini'), findsOneWidget);
      expect(find.text('Model: gemini-2.5-flash'), findsOneWidget);
    });

    testWidgets('nothing is shown before a note is processed', (tester) async {
      await pumpNotePage(tester, NoteProvider());
      expect(find.textContaining('Provider:'), findsNothing);
      expect(find.textContaining('Model:'), findsNothing);
    });
  });
}
