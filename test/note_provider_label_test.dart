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

  group('NoteProvider stores translated transcripts', () {
    test('updateTranscripts records translated versions of all three stages',
        () {
      final NoteProvider provider = NoteProvider()
        ..updateTranscripts(<String, String>{
          'rawTranscript': 'Hello',
          'raw_translated': 'नमस्ते',
          'cleanedTranscript': 'Hello there.',
          'cleaned_translated': 'नमस्ते वहाँ।',
          'polishedNote': '# Greeting',
          'polished_translated': '# अभिवादन',
        });

      expect(provider.rawTranscriptTranslated, 'नमस्ते');
      expect(provider.cleanedTranscriptTranslated, 'नमस्ते वहाँ।');
      expect(provider.polishedTranscriptTranslated, '# अभिवादन');
    });

    test('translated fields are empty when not provided in the map', () {
      final NoteProvider provider = NoteProvider()
        ..updateTranscripts(<String, String>{
          'rawTranscript': 'Hello',
          'cleanedTranscript': 'Hello there.',
          'polishedNote': '# Greeting',
        });

      expect(provider.rawTranscriptTranslated, '');
      expect(provider.cleanedTranscriptTranslated, '');
      expect(provider.polishedTranscriptTranslated, '');
    });

    test('original and translated transcripts remain independent', () {
      final NoteProvider provider = NoteProvider()
        ..updateTranscripts(<String, String>{
          'rawTranscript': 'Original English',
          'raw_translated': 'मूल अंग्रेजी',
          'cleanedTranscript': 'Original English.',
          'cleaned_translated': 'मूल अंग्रेजी।',
          'polishedNote': '# Original',
          'polished_translated': '# मूल',
        });

      // Originals are unchanged.
      expect(provider.rawTranscript, 'Original English');
      expect(provider.cleanedTranscript, 'Original English.');
      expect(provider.polishedTranscript, '# Original');

      // Translated versions are separate.
      expect(provider.rawTranscriptTranslated, 'मूल अंग्रेजी');
      expect(provider.cleanedTranscriptTranslated, 'मूल अंग्रेजी।');
      expect(provider.polishedTranscriptTranslated, '# मूल');
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

  group('KI-06: ProviderResult carries providerId', () {
    test('providerId is set alongside providerName and model', () {
      final result = ProviderResult(
        content: 'note',
        providerName: 'Gemini',
        providerId: 'gemini',
        model: 'gemini-2.5-flash',
      );
      expect(result.providerId, 'gemini');
      expect(result.providerName, 'Gemini');
      expect(result.model, 'gemini-2.5-flash');
    });

    test('providerId defaults to empty string', () {
      final result = ProviderResult(content: 'note');
      expect(result.providerId, '');
    });
  });

  group('KI-01: NoteProvider translated update methods', () {
    test('updateRawTranscriptTranslated stores translated raw text separately',
        () {
      final provider = NoteProvider()
        ..updateRawTranscript('Hello')
        ..updateRawTranscriptTranslated('नमस्ते');

      expect(provider.rawTranscript, 'Hello');
      expect(provider.rawTranscriptTranslated, 'नमस्ते');
    });

    test('updateCleanedTranscriptTranslated stores translated cleaned text',
        () {
      final provider = NoteProvider()
        ..updateCleanedTranscript('Hello there.')
        ..updateCleanedTranscriptTranslated('नमस्ते वहाँ।');

      expect(provider.cleanedTranscript, 'Hello there.');
      expect(provider.cleanedTranscriptTranslated, 'नमस्ते वहाँ।');
    });

    test('updatePolishedNoteTranslated stores translated polished text', () {
      final provider = NoteProvider()
        ..updatePolishedNote('# Title')
        ..updatePolishedNoteTranslated('# शीर्षक');

      expect(provider.polishedTranscript, '# Title');
      expect(provider.polishedTranscriptTranslated, '# शीर्षक');
    });

    test('updating translated text does not change the original', () {
      final provider = NoteProvider()
        ..updateRawTranscript('Original English')
        ..updateRawTranscriptTranslated('मूल अंग्रेजी');

      expect(provider.rawTranscript, 'Original English');
      expect(provider.rawTranscriptTranslated, 'मूल अंग्रेजी');

      // Change the translated version
      provider.updateRawTranscriptTranslated('नया अनुवाद');

      // Original is unchanged
      expect(provider.rawTranscript, 'Original English');
      expect(provider.rawTranscriptTranslated, 'नया अनुवाद');
    });

    test('updating original text does not change the translation', () {
      final provider = NoteProvider()
        ..updateRawTranscript('Original English')
        ..updateRawTranscriptTranslated('मूल अंग्रेजी');

      // Change the original
      provider.updateRawTranscript('New English');

      expect(provider.rawTranscript, 'New English');
      expect(provider.rawTranscriptTranslated, 'मूल अंग्रेजी');
    });
  });

  group('KI-01: NotePage Original/Translated switch', () {
    NoteProvider populatedWithTranslation() => NoteProvider()
      ..updateTranscripts(<String, String>{
        'rawTranscript': 'Hello',
        'raw_translated': 'नमस्ते',
        'cleanedTranscript': 'Hello there.',
        'cleaned_translated': 'नमस्ते वहाँ।',
        'polishedNote': '# Title',
        'polished_translated': '# शीर्षक',
        'rawProvider': 'Groq',
        'rawModel': 'whisper-large-v3',
        'cleanedProvider': 'OpenRouter',
        'cleanedModel': 'meta-llama/llama-3.2-3b-instruct:free',
        'polishedProvider': 'Gemini',
        'polishedModel': 'gemini-2.5-flash',
      });

    testWidgets('displays original text when switch is off', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        ChangeNotifierProvider<NoteProvider>.value(
          value: populatedWithTranslation(),
          child: const MaterialApp(home: NotePage()),
        ),
      );
      await tester.pumpAndSettle();

      // Raw tab shows original by default
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('नमस्ते'), findsNothing);
    });

    testWidgets('displays translated text when switch is on', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        ChangeNotifierProvider<NoteProvider>.value(
          value: populatedWithTranslation(),
          child: const MaterialApp(home: NotePage()),
        ),
      );
      await tester.pumpAndSettle();

      // Turn on translation
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.text('नमस्ते'), findsOneWidget);
      expect(find.text('Hello'), findsNothing);
    });

    testWidgets('switching back to original restores original text',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        ChangeNotifierProvider<NoteProvider>.value(
          value: populatedWithTranslation(),
          child: const MaterialApp(home: NotePage()),
        ),
      );
      await tester.pumpAndSettle();

      // Turn on translation
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('नमस्ते'), findsOneWidget);

      // Turn off translation
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('नमस्ते'), findsNothing);
    });
  });
}
