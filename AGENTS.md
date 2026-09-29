# AGENTS.md — Dictation App

## Quick start
```bash
flutter pub get
flutter run --release    # run on device
flutter build apk --release
flutter analyze          # lint (uses flutter_lints)
flutter test             # 1 test, currently outdated
```

## Architecture (serverless)

- **All app code** in `lib/main.dart` (~2600 lines, single file)
- **Zero backend**: calls Groq (STT) + OpenRouter/NVIDIA (LLM) directly from Flutter via `http` package
- **3 API calls per note**: Groq Whisper STT → LLM Clean (remove fillers, fix grammar) → LLM Polish (structured markdown, with translation)
- **State management**: Provider (`ThemeProvider`, `NoteProvider`, `RecordingProvider`)
- **Persistence**: `shared_preferences` for API keys, STT/LLM model choice, translation toggle, theme
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
- **"+" button** (next to the section title only) opens `_showProviderSheet` → preset chip or free-form name/base URL/model(s) → `_upsertProvider` → persisted → instantly used for polishing and as a fallback. No code change needed for a new provider.
- **Provider rows have no "+" buttons and no ">" chevron.** Each row has a star for making that provider primary; tapping the row opens the flow. The standalone "Connect another provider" entry is the only add path.
- **Main providers cannot be deleted.** `LlmProvider.isProtected` covers OpenRouter and Gemini; `_removeProvider` rejects them with a message, and the provider settings sheet hides the Remove action for them. Only "+"-connected providers expose Remove.
- **Key-remembering flow**: tapping a provider row calls `_openProvider` — no stored key → `_connectProvider` → `_askForApiKey` dialog (asked only this once, saved to the registry) → then the provider settings sheet; stored key → settings open directly. Keys are managed from the sheet (masked `••••xxxx` + "Update key" / "Remove key"); a removed key makes the dialog appear again on the next tap.
- The ✨ Try-Again sheet and the `TranscribePage` error screen both build their provider/model pickers from the registry (`_loadRetryOptions`), and the retry applies the selected model to its provider before re-running.

## Key classes

| Class | File:line | Role |
|-------|-----------|------|
| `LlmProvider` / `ProviderRegistry` | `main.dart:339` / `415` | Provider model + SharedPreferences-backed registry |
| `TranscriptionService` | `main.dart:2783` | `_callWhisper` + provider-agnostic `_callProvider` + `_callLLMWithFallback` + `rePolishWithFallback` |
| `RecordingProvider` | `main.dart:123` | Audio recording lifecycle |
| `NoteProvider` | `main.dart:56` | Raw/cleaned/polished transcript + translation state |
| `TranscribePage` | `main.dart:1781` | Processing screen with stepper |
| `SettingsPage` | `main.dart:2066` | Groq config + provider registry UI (+ / edit / delete / set primary) + translation + theme + clipboard |
| `NotePage` | `main.dart:1311` | Tab view (Raw / Cleaned / Polished) with edit/copy/✨ re-polish |

## Default models
- **STT (Groq)**: `whisper-large-v3` (alt: `whisper-large-v3-turbo`)
- **OpenRouter**: `meta-llama/llama-3.2-3b-instruct:free` (24 free models in `ProviderRegistry.openRouterModels`)
- **Gemini** (default fallback): `gemini-2.5-flash` (also `gemini-2.5-pro`, `gemini-2.5-flash-lite`, `gemini-2.0-flash`)

## Fallback flow
- `_callLLMWithFallback()` loads the registry, puts the primary (`primary_provider_id`) first, then every other connected provider in the order it was added
- Providers without a key are skipped; on 429/quota (`_isRateLimited`) it moves to the next provider; any other error is rethrown
- Used by `processNote()`, `clean()`, and `polish()` (the main transcription flow)
- `✨` Re-polish uses `rePolishWithFallback(providerId:, model:)` — it prefers the provider + model chosen in the sheet, then falls back through the remaining providers

## Gotchas

- **`test/widget_test.dart` is stale** — references a `MyApp` class that no longer exists; will fail
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
