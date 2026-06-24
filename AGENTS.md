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

- **All app code** in `lib/main.dart` (~2200 lines, single file)
- **Zero backend**: calls Groq (STT) + OpenRouter (LLM) directly from Flutter via `http` package
- **2 API calls per note**: Groq Whisper STT → OpenRouter LLM polish (no separate clean step)
- **State management**: Provider (`ThemeProvider`, `NoteProvider`, `RecordingProvider`)
- **Persistence**: `shared_preferences` for API keys, STT/LLM model choice, translation toggle, theme
- **Audio**: recorded as AAC/M4A (`record` package), sampled at 16kHz mono

## API services
| Service | Purpose | Config key | Endpoint |
|---------|---------|------------|----------|
| **Groq** | Speech-to-Text (Whisper) | `groq_api_key`, `groq_stt_model` | `api.groq.com/openai/v1/audio/transcriptions` |
| **OpenRouter** | LLM Brain (primary) | `openrouter_api_key`, `openrouter_model` | `openrouter.ai/api/v1/chat/completions` |
| **NVIDIA** | LLM Brain (fallback) | `nvidia_api_key` | `integrate.api.nvidia.com/v1/chat/completions` |

## Key classes

| Class | File:line | Role |
|-------|-----------|------|
| `TranscriptionService` | `main.dart:2124` | 2 API calls (`_callWhisper`, `_callOpenRouterLLM`, `_callNVIDIALLM`) + `_callLLMWithFallback()` |
| `RecordingProvider` | `main.dart:123` | Audio recording lifecycle |
| `NoteProvider` | `main.dart:56` | Raw/cleaned/polished transcript + translation state |
| `TranscribePage` | `main.dart:1450` | Processing screen with stepper |
| `SettingsPage` | `main.dart:1708` | Groq, OpenRouter, NVIDIA config + Primary API selector + translation + theme |
| `NotePage` | `main.dart:1024` | Tab view (Raw / Cleaned / Polished) with edit/copy/✨ re-polish |

## Default models
- **STT (Groq)**: `whisper-large-v3` (alt: `whisper-large-v3-turbo`)
- **LLM Brain (OpenRouter)**: `meta-llama/llama-3.2-3b-instruct:free` (24 free models hardcoded in dropdown)
- **LLM Fallback (NVIDIA)**: `deepseek-ai/deepseek-v4-flash` (default, 12 models in dropdown)

## Fallback flow
- `_callLLMWithFallback()` reads `primary_api` from SharedPreferences (`'openrouter'` or `'nvidia'`)
- Tries primary provider first; on 429/rate-limit, silently tries the secondary
- Used by `processNote()` and `polish()` (the main transcription flow)
- `✨` Re-polish also falls back to NVIDIA if the selected OpenRouter model rate-limits

## Gotchas

- **`test/widget_test.dart` is stale** — references a `MyApp` class that no longer exists; will fail
- **Kotlin incremental compilation disabled** in `android/gradle.properties` (Windows cross-drive fix)
- **Gradle home** redirected to project-local `.gradle_home` (not global cache)
- **`.gitignore`** excludes AI tracking files (`changes.md`, `score.md`, `problemstatement.md`, `Muddu_Dictation_AI_Technical_Documentation.md`)
- **Existing instructions**: `.github/copilot-instructions.md` (graphify-first lookup), `.agents/rules/graphify.md` (same), `.agents/workflows/` (explain/graphify/understand)
- **`cleanedTranscript == rawTranscript`** — Whisper output is used directly (no separate clean LLM call)
- **Three separate API keys possible**: Groq (STT) + OpenRouter + NVIDIA (LLM brain with fallback)

## Translation feature
- Toggle + language picker in Settings persist to `SharedPreferences`
- A single prompt extension appends translation instruction to the OpenRouter LLM call (no separate API call)
- Supported languages: English, Hindi, Kannada, Telugu, Tamil, Malayalam, Marathi, Bengali
