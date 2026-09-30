# AGENTS.md — Dictation App

## Quick start
```bash
flutter pub get
flutter run --release    # run on device
flutter build apk --release
flutter analyze          # lint (uses flutter_lints)
flutter test             # 15 tests: provider registry/fallback + Settings auto-save widgets
```

## Architecture (serverless)

- **All app code** in `lib/main.dart` (~3750 lines, single file)
- **Zero backend**: calls Groq (STT) + OpenRouter/NVIDIA (LLM) directly from Flutter via `http` package
- **3 API calls per note**: Groq Whisper STT → LLM Clean (remove fillers, fix grammar) → LLM Polish (structured markdown, with translation)
- **State management**: Provider (`ThemeProvider`, `NoteProvider`, `RecordingProvider`)
- **Persistence**: `shared_preferences` for API keys, STT/LLM model choice, translation toggle, theme — **written automatically** (debounced auto-save, no save button)
- **Audio**: recorded as AAC/M4A (`record` package), sampled at 16kHz mono

## API services
| Service | Purpose | Config key(s) | Endpoint |
|---------|---------|---------------|----------|
| **Groq** | Speech-to-Text (Whisper) | `groq_api_key`, `groq_stt_model` | `api.groq.com/openai/v1/audio/transcriptions` |
| **LLM providers** | LLM Brain + fallbacks (registry-driven) | `llm_providers` (JSON), `primary_provider_id` | any OpenAI-compatible `{baseUrl}/chat/completions` |

Built-in defaults: **OpenRouter** (`openrouter.ai/api/v1`) and **Gemini**
(`generativelanguage.googleapis.com/v1beta/openai`). NVIDIA was removed as the
hard-coded fallback — it can be re-added (like anything else) as a custom provider.

## Provider registry (provider-independent)
- `LlmProvider` (`main.dart:339`) — `{id, name, baseUrl, apiKey, model, models}`; `chatCompletionsUrl` normalises the base URL and `isConfigured` gates participation.
- `ProviderRegistry` (`main.dart:415`) — `load`, `save`, `resolvePrimaryId`, `orderedForFallback`, `flowLabel` + `presets` (chips in the connect sheet).
- SharedPreferences: `llm_providers` (JSON list, **API keys included**) and `primary_provider_id`.
- First launch after the upgrade migrates `openrouter_api_key` / `openrouter_model` (and a legacy `gemini_api_key`) into the registry, then removes `nvidia_api_key`, `nvidia_model`, `primary_api`.
- **"+" button** (next to the section title only) opens `_showProviderSheet` → preset chip or name/base URL + a model **dropdown** → `_upsertProvider` → persisted → instantly used for polishing and as a fallback. No code change needed for a new provider.
- **Provider rows have no "+" buttons and no ">" chevron.** Each row has a star for making that provider primary; tapping the row opens the flow. The standalone "Connect another provider" entry is the only add path.
- **Main providers cannot be deleted.** `LlmProvider.isProtected` covers OpenRouter and Gemini; `_removeProvider` rejects them with a message, and the provider settings sheet hides the Remove action for them. Only "+"-connected providers expose Remove.
- **Key-remembering flow**: tapping a provider row calls `_openProvider` — no stored key → `_connectProvider` → `_askForApiKey` dialog (asked only this once, saved to the registry) → then the provider settings sheet; stored key → settings open directly. Keys are managed from the sheet (masked `••••xxxx` + "Update key" / "Remove key"); a removed key makes the dialog appear again on the next tap.
- **Model picker is a dropdown, never a text box**: `_showProviderSheet` keeps `selectedModel` (the default model) + `modelsController` (the pickable list) and renders `InputDecorator → DropdownButtonHideUnderline → DropdownButton(isExpanded: true)` — closed it shows only the selected model, expanded it lists `provider.models`, and choosing an entry makes it the default. `DropdownButtonFormField` is avoided on purpose (needs a `Form`, and its `value:` is deprecated in this Flutter version).
- **The model list is not in the initial view**: it is revealed by the "Edit models (N available)" / "Hide model list" toggle (`showModelsEditor`), which is also how a custom provider's list is maintained. A provider with no models yet (`needsCustomModel`) falls back to one "Model" text field so it can be created at all. `ProviderRegistry.parseModelList()` / `modelChoices()` are the only list parsers — the dropdown always offers the selected model first (`modelChoices` prepends it when the edited list dropped it). Covered by tests in `test/provider_registry_test.dart`.
- **Everything auto-saves — Settings has no save button and no save indicator.** `_scheduleAutoSave()` (300 ms debounce) → `_persistAllSettings()` writes keys, STT model, registry, translation and clipboard prefs after each change — silently, the Settings app bar shows nothing for it (no 💾, no ✓), and `dispose()` flushes a pending write. In the provider sheet, `autoApply()` persists each valid edit immediately via `_upsertProvider(..., silent: true)` (the `silent` flag suppresses the per-keystroke snackbar) and the button reads **Done**; only *creating* a provider keeps an explicit "Connect provider" action.
- The ✨ Try-Again sheet and the `TranscribePage` error screen both build their provider/model pickers from the registry (`_loadRetryOptions`), and the retry applies the selected model to its provider before re-running.

## Key classes

| Class | File:line | Role |
|-------|-----------|------|
| `LlmProvider` / `ProviderRegistry` | `main.dart:339` / `419` | Provider model + SharedPreferences-backed registry |
| `TranscriptionService` | `main.dart:3378` | `_callWhisper` + provider-agnostic `_callProvider` + `_callLLMWithFallback` + `rePolishWithFallback` |
| `RecordingProvider` | `main.dart:123` | Audio recording lifecycle |
| `NoteProvider` | `main.dart:56` | Raw/cleaned/polished transcript + translation state |
| `TranscribePage` | `main.dart:1830` | Processing screen with stepper |
| `SettingsPage` | `main.dart:2189` | Groq config + provider registry UI (model dropdown, auto-save / edit / delete / set primary) + translation + theme + clipboard |
| `NotePage` | `main.dart:1360` | Tab view (Raw / Cleaned / Polished) with edit/copy/✨ re-polish |

## Default models
- **STT (Groq)**: `whisper-large-v3` (alt: `whisper-large-v3-turbo`)
- **OpenRouter**: `meta-llama/llama-3.2-3b-instruct:free` (24 free models in `ProviderRegistry.openRouterModels`)
- **Gemini** (default fallback): `gemini-2.5-flash` (also `gemini-2.5-pro`, `gemini-2.5-flash-lite`, `gemini-2.0-flash`)

## Fallback flow
- `_callLLMWithFallback()` loads the registry, puts the primary (`primary_provider_id`) first, then every other connected provider in the order it was added
- Both LLM loops (`_callLLMWithFallback` and `rePolishWithFallback`) share `_runProviderChain`, which **always moves to the next provider on any failure** (bad key, retired/paid model, quota, 4xx/5xx, timeout, network). The user only sees an error when *every* connected provider failed, and the message lists each provider's own failure (`providerFailureLine`)
- Providers without a key are skipped before the loop; a local "no provider configured" error is thrown before any attempt
- Used by `processNote()`, `clean()`, and `polish()` (the main transcription flow)
- `✨` Re-polish uses `rePolishWithFallback(providerId:, model:)` — it prefers the provider + model chosen in the sheet, then falls back through the remaining providers

## Retry semantics (TranscribePage)
- `_rawTranscript` / `_cleanedTranscript` cache each stage that already succeeded
- A retry **never re-sends audio to Groq** once transcription succeeded — only the failed LLM stage runs again, against the selected provider/model
- The error screen states which case applies ("audio already transcribed — Retry skips Groq" vs "Retry transcription") and the button label follows

## Free OpenRouter models (Settings)
- "Retry free model list" (Settings → LLM Brain Providers, shown when OpenRouter exists) calls `GET openrouter.ai/api/v1/models`
- `ProviderRegistry.freeOpenRouterModelIds*` keeps only models whose `pricing.prompt` **and** `pricing.completion` are zero — paid models disappear from every dropdown
- The refreshed list replaces `LlmProvider.models`; the selected model is preserved when still free, otherwise the first free model is selected
- `openrouter_free_models_refreshed_at_ms` stores the last refresh time (shown under the button)

## Gotchas

- **Settings has no save button and no save indicator (by design)** — `_scheduleAutoSave()` persists on every change, silently; do not re-add a 💾 action, a ✓/spinner in the app bar, or a "Settings saved!" snackbar
- **The dead `MyApp` counter test is gone** — `test/widget_test.dart` referenced a class that never existed in this app and aborted the whole `flutter test` run; it was deleted. Widget tests now live in `test/settings_auto_save_test.dart`, which pumps `SettingsPage` with `SharedPreferences.setMockInitialValues` and asserts the app bar has **no actions** (that is what keeps the save button and the ✓ from coming back)
- **Kotlin incremental compilation disabled** in `android/gradle.properties` (Windows cross-drive fix)
- **Gradle home** redirected to project-local `.gradle_home` (not global cache)
- **`.gitignore`** excludes AI tracking files (`changes.md`, `score.md`, `problemstatement.md`, `Muddu_Dictation_AI_Technical_Documentation.md`)
- **Existing instructions**: `.github/copilot-instructions.md` (graphify-first lookup), `.agents/rules/graphify.md` (same), `.agents/workflows/` (explain/graphify/understand)
- **`cleanedTranscript`** — now a separate LLM clean call (no longer `== rawTranscript`)
- **API keys** — one Groq key (STT) plus one key per connected LLM provider; all stored as plain text in `SharedPreferences`
- **Legacy keys removed on migration**: `nvidia_api_key`, `nvidia_model`, `primary_api` (the registry replaces them)

## Translation feature
- Toggle + language picker in Settings persist to `SharedPreferences`
- A single prompt extension appends the translation instruction to the polish prompt of whichever provider serves the request (no separate API call)
- Supported languages: English, Hindi, Kannada, Telugu, Tamil, Malayalam, Marathi, Bengali

## Auto-Copy to Clipboard
- Settings toggle `auto_copy_enabled` + dropdown `auto_copy_target` (`'clean'`/`'polished'`)
- After processing completes, `_autoCopyResult()` in `_HomePageState` reads prefs and copies the selected transcript to clipboard via `Clipboard.setData`
- Shows a snackbar confirming the copy
- Persisted in `SharedPreferences`
