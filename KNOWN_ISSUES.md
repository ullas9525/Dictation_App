# KNOWN ISSUES — PARKED BACKLOG

> **STATUS: PARKED. DO NOT FIX AS PART OF THE FLOATING OVERLAY WORK.**
>
> Findings from a read-only audit of commit `597f183` ("Provider Display",
> 2026-10-04). They are recorded so they are not forgotten. Fixing them is a
> separate, later effort. Line numbers refer to the pre-overlay revision and
> will drift — use the method names and commit hash to relocate them.

**Severity:** `high` = user-visible breakage / data-loss risk; `medium` = rough
edge or misleading behavior; `low` = cleanup / documentation.
**Direction** is a suggested fix, deliberately *not* implemented.

---

## Functional

### KI-01 — Translated transcript tabs are dead code
- **Severity:** medium
- **Evidence:** `lib/main.dart` — `NoteProvider` translated fields,
  `NotePage._showTranslated`, `TranscribePage` pop map.
- **What happens:** `NotePage` has an Orig/Trans switch and three translated
  fields, but `TranscribePage` never returns `raw_translated`,
  `cleaned_translated` or `polished_translated`. Translation is applied
  in-place inside the Polish prompt, so the switch never appears.
- **Direction:** remove the dead fields/switch, or populate them and return the
  keys.

### KI-02 — Notes are never persisted
- **Severity:** high (data loss)
- **Evidence:** `NoteProvider` is in-memory only; the Notes tab is a single-note
  viewer; `RecordingProvider` writes to `getTemporaryDirectory()`.
- **What happens:** closing the app loses the current note; recorded `.m4a`
  files accumulate in temp storage and are never deleted.
- **Direction:** add a notes repository (SQLite/Isar/files) + history list, and
  clean temp audio after processing.

### KI-03 — Custom provider creation can dead-end
- **Severity:** medium
- **Evidence:** `_showProviderSheet`; `needsCustomModel` is computed from the
  initial Gemini preset.
- **What happens:** choosing the "Custom" chip on a new provider leaves
  `needsCustomModel == false` and `selectedModel == ''`, so the sheet shows an
  empty model dropdown and no text field. The user must discover
  "Edit models (0 available)" to recover.
- **Direction:** recompute the custom-model mode when the preset changes, or
  always show an editable model field for the Custom preset.

### KI-04 — Stepper's Processing ring is frozen at 0
- **Severity:** low / medium (misleading UI)
- **Evidence:** `TranscribePage` builds `ProcessingStepper(currentStep: ...)`
  without `transcriptionProgress` or `transcriptionLabel`; `_buildStep` passes
  `value: transcriptionProgress` (`0.0`) for the current Processing step.
- **What happens:** a determinate ring at 0 looks empty/stuck, while
  Uploading/Downloading use indeterminate spinners.
- **Direction:** pass real progress, or use an indeterminate spinner for that
  step.

### KI-05 — Retry permanently rewrites the primary brain
- **Severity:** medium (surprising side effect)
- **Evidence:** `TranscribePage._retryWithSelectedModel` calls
  `ProviderRegistry.save(prefs, providers, providers[index].id)` and sets
  `providers[index].model = parts[1]`.
- **What happens:** choosing a brain on the error screen permanently changes
  the user's primary provider and default model.
- **Direction:** apply the choice to this request only, or confirm the
  promotion explicitly.

### KI-06 — Clean and Polish each restart at the primary provider
- **Severity:** medium (latency/cost)
- **Evidence:** `_startProcessing` calls `service.clean(...)` then
  `service.polish(...)`; each calls `_callLLMWithFallback`, which restarts the
  ordered chain.
- **What happens:** if the primary is broken, it is attempted twice per note
  (once for Clean, once for Polish) before the working fallback answers.
- **Direction:** remember the last working provider for the note, or add a
  short-lived circuit breaker.

### KI-07 — Copy vs auto-copy produce different text
- **Severity:** low / medium
- **Evidence:** `NotePage` Copy button strips Markdown from the Polished tab
  (`[*#_`/\\]`, leading `-`); `HomePage._autoCopyResult` copies the raw value.
- **What happens:** the clipboard contents depend on how the copy happened.
- **Direction:** share one "copy-ready text" formatter.

### KI-08 — Microphone selector is cosmetic
- **Severity:** medium (misleading)
- **Evidence:** `HomePage._loadAvailableMicrophones` returns a hard-coded list;
  `_selectedMicrophone` is never passed to `RecordConfig`/the recorder.
- **What happens:** choosing "Bluetooth Headset" or "USB Microphone" has no
  effect on which device records.
- **Direction:** enumerate real input devices (platform channel) or remove the
  selector.

### KI-09 — Upload button advertises only `.wav`
- **Severity:** low
- **Evidence:** `_pickAndUploadAudio` allows `wav`, `mp3`, `m4a`, `aac`, `ogg`;
  the label says "Upload .wav file".
- **Direction:** rename the label to "Upload audio".

### KI-10 — Default OpenRouter model is a code model
- **Severity:** medium (output quality)
- **Evidence:** `ProviderRegistry.openRouterDefault()` uses
  `openRouterModels.first`; the sorted seed list starts with
  `cohere/north-mini-code:free`.
- **What happens:** the first brain can be a coding model rather than a prose
  note-taker. The free-model refresh can likewise pick whatever sorts first
  (and may include embedding/rerank models).
- **Direction:** choose an explicit prose default and filter non-chat models.

### KI-11 — No speech path is inconsistent
- **Severity:** low
- **Evidence:** `TranscriptionService.processNote` (unused) returns friendly
  "No speech detected" placeholders; `TranscribePage` calls `transcribe`,
  `clean`, `polish` separately, where `clean` returns empty content and
  `polish` returns a fixed message without provider labels.
- **Direction:** unify the no-speech handling and provider metadata.

### KI-12 — No cancellation while processing
- **Severity:** medium (UX)
- **Evidence:** `TranscribePage` uses `PopScope(canPop: !_isProcessing)` and
  offers no cancel action; HTTP timeouts are 60 s per stage/provider.
- **What happens:** a slow or dead chain can keep the user on the screen for
  minutes.
- **Direction:** add a cancel action with `Client`/request abortion or a
  per-stage timeout budget.

## UX / Product

### KI-13 — Navigation recreates pages
- **Severity:** medium (state loss)
- **Evidence:** `MainScreen` builds `widgetOptions` and mounts only
  `elementAt(_selectedIndex)`.
- **What happens:** switching tabs loses HomePage animation/mic selection,
  Notes tab selection/edit mode/scroll position, Settings scroll position.
  Recording survives only because it lives in `RecordingProvider`.
- **Direction:** use an `IndexedStack` (or keep-alive) for the three pages.

### KI-14 — Microphone permission is requested at app launch
- **Severity:** low / medium (trust)
- **Evidence:** `RecordingProvider` constructor calls `_initRecorder`, which
  requests `Permission.microphone` before the user taps record.
- **Direction:** request on first record tap and explain why.

### KI-15 — Release build is not production-ready
- **Severity:** high (release)
- **Evidence:** `android/app/build.gradle.kts` signs release with the debug key;
  `applicationId = "com.example.dictation_app"`; manifest label
  `dictation_app`.
- **Direction:** real signing config, unique application id, branding.

### KI-16 — macOS target cannot function
- **Severity:** low (unused target)
- **Evidence:** `macos/Runner/DebugProfile.entitlements` and
  `Release.entitlements` lack `com.apple.security.network.client` and
  `com.apple.security.device.audio-input`.
- **What happens:** sandboxed macOS builds cannot call APIs or record.
- **Direction:** add entitlements if macOS is ever supported.

## Architecture / Build

### KI-17 — Single 3,899-line file
- **Severity:** low / medium (maintainability)
- **Evidence:** all Dart app code lives in `lib/main.dart`; tests import it.
- **Direction:** split into models/services/screens without changing behavior.

### KI-18 — Dead code and unused dependencies
- **Severity:** low
- **Evidence:** `TranscriptionService.processNote` is never called;
  `_buildCopyButton`, `_buildTranscriptCard`, `_buildPolishedCard` are unused;
  `share_plus` is imported but unused; `audioplayers`, `intl`,
  `flutter_spinkit` are unused dependencies; `_askForApiKey` never disposes its
  controller.
- **Direction:** remove or wire up; let the analyzer guide cleanup.

### KI-19 — No CI
- **Severity:** low
- **Evidence:** no workflow runs `flutter analyze`/`flutter test`; `.github/` is
  git-ignored and contains only local instructions.
- **Direction:** add a CI workflow once the docs are tracked.

### KI-20 — Accessibility/service behavior is OEM-dependent
- **Severity:** medium (new overlay feature)
- **Evidence:** new `DictationAccessibilityService` + `OverlayService`.
- **What happens:** battery optimizers (Xiaomi/Samsung/etc.) may kill the
  foreground service or accessibility service; custom keyboards/apps may not
  expose editable nodes.
- **Direction:** onboarding checklist + "service running" status + clipboard
  fallback (already the prototype behavior).

## Documentation / Repo

### KI-21 — AGENTS.md line references are stale
- **Severity:** low
- **Evidence:** `AGENTS.md` cites `LlmProvider` 339 (actual 366),
  `ProviderRegistry` 419 (actual 446), `TranscriptionService` 3378 (actual
  3501), `NotePage` 1360 (actual 1407), `TranscribePage` 1830 (actual 1938),
  `SettingsPage` 2189 (actual 2305); says "~3750 lines" (actual 3,899) and
  "15 tests" (actual 23 at the audit revision).
- **Direction:** regenerate the class/line table after the overlay lands.

### KI-22 — Technical documentation describes a retired pipeline
- **Severity:** low
- **Evidence:** `Muddu_Dictation_AI_Technical_Documentation.md` describes a
  2-stage pipeline and `_callGroqLLM`, both obsolete; the code does STT →
  Clean → Polish.
- **Direction:** rewrite the processing section.

### KI-23 — Some tracked instructions are local-only
- **Severity:** low
- **Evidence:** `.gitignore` ignores `.agents/`, `.github/`, `changes.md`,
  `score.md`, `problemstatement.md` and the technical doc; `AGENTS.md` and
  `README.md` are tracked and reference them.
- **What happens:** a fresh clone lacks the instructions the docs point to.
- **Direction:** decide what is public, then track or stop referencing it.

### KI-24 — Graphify graph is absent
- **Severity:** low
- **Evidence:** `graphify-out/` contains only an empty `cache/`; no
  `GRAPH_REPORT.md` or `wiki/index.md`.
- **Direction:** run `graphify update .` on a machine with the CLI when the
  graph-first workflow is wanted. (Not run during this work.)

### KI-25 — Aspirational docs are not evidence
- **Severity:** low
- **Evidence:** `score.md` claims 10/10 and "production ready"; the release
  signing and persistence gaps above contradict that. README's
  "summarization" framing is also stronger than the prompts, which restructure
  rather than summarize.
- **Direction:** treat `score.md` as a historical note; keep README claims
  accurate.

---

## Overlay feature — prototype limitations (by design for now)

These are *new* to the floating-bubble feature, not part of the parked audit
findings above.

1. **Android only.** The bubble, accessibility detection and paste bridge are
   native Android. Other platforms show an "Android only" note in Settings.
2. **The bubble only shows while the keyboard is visible.** It anchors above
   the IME window (Gboard etc.). A focused message bar with the keyboard
   closed shows no bubble.
3. **Two manual grants are required:** "Display over other apps" and the
   "Dictation bubble" accessibility service. Without both, no bubble/insertion.
4. **Android 13+ "Restricted setting" blocks the accessibility toggle for
   sideloaded installs** (confirmed on a real device). Workaround: App info →
   ⋮ → "Allow restricted settings"; or install via `adb install`
   (adb installs are not restricted). OS policy — the app cannot clear it.
5. **Activity-based capture can affect the keyboard.** Tapping the bubble opens
   a translucent Flutter activity; some keyboards/apps may hide and reopen the
   IME. This is a manual-test item on WhatsApp/Gboard.
6. **Insertion is best-effort.** It uses `ACTION_PASTE` and falls back to
   splicing via `ACTION_SET_TEXT`. Custom web views / non-standard editors may
   refuse both; the text is left on the clipboard.
7. **The transcript is auto-inserted on ✓ (per-message preview removed).**
   The recorder pill (✕ · visualizer · ✓) inserts the Settings-format
   transcript as soon as ✓ is tapped — no preview, no second confirmation.
   Wrong format? Record again with a different default.
8. **Target app detection is an allowlist** (`com.whatsapp` by default, `*` for
   any app) and only reacts to editable, non-password fields.
9. **Battery/RAM:** a foreground service keeps the bubble ready; the
   accessibility service is system-managed. OEM battery savers may still kill
   them.

---

*Parked at commit `597f183`. Nothing in this file is implemented by the overlay
change except where explicitly noted under "Overlay feature — prototype
limitations".*
