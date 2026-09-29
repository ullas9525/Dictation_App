// Tests for the provider-independent LLM registry that replaced the hard-coded
// OpenRouter + NVIDIA fallback (NVIDIA → Gemini + the "+" button).
//
// Run with: flutter test test/provider_registry_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_notes_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('seeds OpenRouter + Gemini from the legacy settings and drops NVIDIA', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openrouter_api_key': 'or-key',
      'openrouter_model': 'meta-llama/llama-3.3-70b-instruct:free',
      'nvidia_api_key': 'nv-key',
      'nvidia_model': 'deepseek-ai/deepseek-v4-flash',
      'primary_api': 'nvidia',
    });
    final prefs = await SharedPreferences.getInstance();

    final providers = await ProviderRegistry.load(prefs);

    expect(providers.map((LlmProvider p) => p.name), ['OpenRouter', 'Gemini']);
    expect(providers.first.apiKey, 'or-key');
    expect(providers.first.model, 'meta-llama/llama-3.3-70b-instruct:free');
    expect(providers.last.baseUrl, ProviderRegistry.geminiBaseUrl);
    expect(providers.last.model, 'gemini-2.5-flash');
    // Gemini has no key yet, so it is stored but not used in the pipeline.
    expect(providers.last.isConfigured, isFalse);

    // The removed NVIDIA settings are cleaned up and OpenRouter keeps the slot.
    expect(prefs.getString('nvidia_api_key'), isNull);
    expect(prefs.getString('nvidia_model'), isNull);
    expect(prefs.getString('primary_api'), isNull);
    expect(prefs.getString('primary_provider_id'), 'openrouter');
  });

  test('a provider connected with "+" is persisted and used', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final providers = await ProviderRegistry.load(prefs);

    final LlmProvider custom = LlmProvider(
      id: 'provider_1',
      name: 'My Local LLM',
      baseUrl: 'http://192.168.1.5:11434/v1',
      apiKey: 'local',
      model: 'llama3',
    )..normalize();
    await ProviderRegistry.save(prefs, <LlmProvider>[...providers, custom], '');

    // An empty primary id resolves to the first provider in the registry.
    expect(prefs.getString('primary_provider_id'), 'openrouter');

    final List<LlmProvider> reloaded = await ProviderRegistry.load(prefs);
    expect(reloaded.length, 3);
    expect(reloaded.last.name, 'My Local LLM');
    expect(reloaded.last.isConfigured, isTrue);
    expect(reloaded.last.chatCompletionsUrl,
        'http://192.168.1.5:11434/v1/chat/completions');
  });

  test('fallback order is primary-first, then the other connected providers', () async {
    final List<LlmProvider> providers = <LlmProvider>[
      ProviderRegistry.openRouterDefault()..apiKey = 'or-key',
      ProviderRegistry.geminiDefault()..apiKey = 'gem-key',
      LlmProvider(
        id: 'provider_3',
        name: 'Groq',
        baseUrl: 'https://api.groq.com/openai/v1',
        apiKey: 'g-key',
        model: 'llama-3.3-70b-versatile',
      ),
    ];

    final List<LlmProvider> ordered =
        ProviderRegistry.orderedForFallback(providers, 'gemini');
    expect(ordered.map((LlmProvider p) => p.name), ['Gemini', 'OpenRouter', 'Groq']);
    expect(ProviderRegistry.flowLabel(providers, 'gemini'),
        'Gemini → OpenRouter → Groq');
    // An unknown primary id keeps the stored order instead of throwing.
    expect(ProviderRegistry.orderedForFallback(providers, 'gone').first.name,
        'OpenRouter');
    expect(ProviderRegistry.flowLabel(<LlmProvider>[], ''), contains('No provider'));
  });

  test('base URL is normalised for both paste styles', () {
    final LlmProvider provider = LlmProvider(
      id: 'x',
      name: 'X',
      baseUrl: 'https://example.com/v1/chat/completions',
      apiKey: 'k',
      model: 'm',
    );
    expect(provider.chatCompletionsUrl,
        'https://example.com/v1/chat/completions');

    provider.baseUrl = 'https://example.com/v1/';
    expect(provider.chatCompletionsUrl,
        'https://example.com/v1/chat/completions');
    expect(provider.isConfigured, isTrue);

    provider.apiKey = '   ';
    expect(provider.isConfigured, isFalse);
  });

  test('an emptied provider list is not re-seeded', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'llm_providers': '[]',
      'primary_provider_id': '',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(await ProviderRegistry.load(prefs), isEmpty);
  });

  test('corrupt registry JSON falls back to the legacy migration', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'llm_providers': '{not json',
    });
    final prefs = await SharedPreferences.getInstance();
    final providers = await ProviderRegistry.load(prefs);
    expect(providers.map((LlmProvider p) => p.name), ['OpenRouter', 'Gemini']);
  });

  group('OpenRouter free model list (Retry free model list)', () {
    const String body = '''
{
  "data": [
    {"id": "paid/model-a", "pricing": {"prompt": "0.000002", "completion": "0.00001"}},
    {"id": "free/model-c", "pricing": {"prompt": "0", "completion": "0"}},
    {"id": "free/model-b", "pricing": {"prompt": "0.0", "completion": "0.00"}},
    {"id": "free/model-c", "pricing": {"prompt": "0", "completion": "0"}},
    {"id": "free/model-d", "pricing": {"prompt": "0", "completion": "0.00001"}},
    {"id": "free/model-e", "pricing": {"prompt": "0", "completion": "0", "web_search": "0.01"}},
    {"id": "free/model-f", "pricing": {}},
    {"pricing": {"prompt": "0", "completion": "0"}},
    "not-an-object",
    {"id": "free/model-g", "pricing": {"prompt": 0, "completion": 0}}
  ]
}
''';

    test('keeps only models whose prompt AND completion prices are zero',
        () {
      final List<String> ids =
          ProviderRegistry.freeOpenRouterModelIdsFromJson(body);

      // Paid model-d, model-f (missing prices), the malformed entries and the
      // model without an id must all be dropped.
      expect(ids, <String>[
        'free/model-b',
        'free/model-c',
        'free/model-e',
        'free/model-g',
      ]);
      expect(ids, isNot(contains('paid/model-a')));
      expect(ids, isNot(contains('free/model-d')));
      expect(ids, isNot(contains('free/model-f')));
      expect(ids.toSet().length, ids.length, reason: 'no duplicates');
    });

    test('the list is sorted so the dropdown stays stable', () {
      final List<String> ids =
          ProviderRegistry.freeOpenRouterModelIdsFromJson(body);
      final List<String> sorted = [...ids]..sort();
      expect(ids, sorted);
    });

    test('malformed payloads return an empty list instead of throwing', () {
      expect(ProviderRegistry.freeOpenRouterModelIdsFromJson('not json'),
          isEmpty);
      expect(ProviderRegistry.freeOpenRouterModelIdsFromJson('{"data": 5}'),
          isEmpty);
      expect(ProviderRegistry.freeOpenRouterModelIdsFromJson('[]'), isEmpty);
      expect(ProviderRegistry.freeOpenRouterModelIdsFromJson('null'), isEmpty);
      expect(ProviderRegistry.freeOpenRouterModelIds('{"data": {}}'), isEmpty);
      expect(ProviderRegistry.freeOpenRouterModelIds(null), isEmpty);
    });
  });

  test('provider failure lines carry provider, model and truncated detail', () {
    final String line = TranscriptionService.providerFailureLine(
      'OpenRouter',
      'some/retired-model:free',
      Exception('x' * 400),
    );

    expect(line, startsWith('OpenRouter (some/retired-model:free): '));
    expect(line.length, lessThan(320), reason: 'detail is truncated');
    expect(
      TranscriptionService.providerFailureLine(
          'Gemini', 'gemini-2.5-flash', Exception('quota exceeded')),
      'Gemini (gemini-2.5-flash): quota exceeded',
    );
  });
}
