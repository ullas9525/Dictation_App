# Security and privacy audit

This document describes the security-sensitive capabilities used by the
floating dictation bubble and the privacy controls that limit them. It is
written against the code in `lib/main.dart` and
`android/app/src/main/kotlin/com/example/dictation_app/`.

> Scope: Android overlay and accessibility features. The ordinary Dictation app
> (recording on the Home screen, transcription, cleaning, polishing, editing and
> copying notes) works without either capability.

## 1. Capabilities and why they exist

| Capability | Declared in | Required for | What the app actually does |
|---|---|---|---|
| `RECORD_AUDIO` | `AndroidManifest.xml` | Dictation recording | Records AAC/M4A audio while the user records (Home screen or the overlay pill). The overlay only records after the bubble is tapped. Audio is then sent to Groq for speech-to-text. |
| `INTERNET` | `AndroidManifest.xml` | Transcription and note processing | HTTPS calls to `api.groq.com` and the OpenAI-compatible `/chat/completions` endpoint of each configured LLM provider. No analytics or telemetry endpoints exist. |
| `SYSTEM_ALERT_WINDOW` ("Display over other apps") | `AndroidManifest.xml` | Draw the floating microphone bubble | Adds one 44 dp `TYPE_APPLICATION_OVERLAY` window. The window contains only the bubble and is hosted by `BubbleOverlay` inside `DictationAccessibilityService`. It does not capture the screen, take screenshots or read other windows. |
| Accessibility service (`BIND_ACCESSIBILITY_SERVICE`) | `AndroidManifest.xml` + `accessibility_service_config.xml` | Detect a focused editable field and insert the transcript | Watches `TYPE_VIEW_FOCUSED`, `TYPE_WINDOW_STATE_CHANGED` and `TYPE_WINDOWS_CHANGED`. Reads only the focused editable, non-password node in allow-listed packages (to position the bubble and paste/append text). Keeps one node reference in memory and never stores screen content. |
| Overlay activity (`OverlayDictationActivity`) | `AndroidManifest.xml` | Record and process inside the target app | Translucent `FlutterActivity` running the `overlayMain` entrypoint. It is `FLAG_NOT_FOCUSABLE` so the keyboard stays with the app underneath. |

### No foreground service and no notification

The bubble window is hosted by the accessibility service that the feature
already requires (`BubbleOverlay.attach()` in `onServiceConnected`,
`detach()` in `onDestroy`). There is **no foreground service**, so the app
declares no `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE` or
`POST_NOTIFICATIONS` permission and posts **no notification at all** — not even
a silent or minimum-importance one. The bubble only exists while the
accessibility binding is alive, which is exactly the condition it needs anyway.

### Accessibility configuration

`accessibility_service_config.xml` is intentionally minimal:

- `typeViewFocused`, `typeWindowStateChanged`, `typeWindowsChanged` only.
  `typeWindowContentChanged` was removed — it fired on every keystroke and is
  not needed for focus/window transitions.
- `flagDefault|flagRetrieveInteractiveWindows`. `flagReportViewIds` was removed
  because no code reads view IDs.
- `canRetrieveWindowContent="true"` is required to find the focused node and the
  IME window bounds.
- `isAccessibilityTool` is intentionally **not** set: Dictation is a dictation
  tool, not an accessibility tool for people with disabilities.

Trade-off when the user turns the accessibility service off: automatic
insertion into other apps stops working (the bubble cannot be shown, and the
final paste cannot be performed). The ordinary Dictation app still records,
transcribes, cleans and polishes notes; results can be copied and pasted
manually. Dictation never disables or reconfigures the service itself.

## 2. Privacy mode

Settings → **Floating Dictation Bubble → Privacy mode** is the user-controlled
kill switch. Turning it on:

1. Persists `overlay_privacy_mode = true` and `overlay_enabled = false`
   immediately (not on the debounce).
2. Calls `OverlayBridge.stopOverlay()`, which removes the bubble window
   (`BubbleOverlay.hide()`). There is no service to stop and no notification to
   dismiss — the app never posts one.
3. Blocks the native bubble, the accessibility service and the overlay activity:
   - `BubbleOverlay.show()` / `openDictationActivity()` check
     `overlay_privacy_mode` and `overlay_enabled` directly from
     `FlutterSharedPreferences` and hide instead.
   - `DictationAccessibilityService.onAccessibilityEvent()` checks the same
     prefs **before inspecting the event**: while Privacy mode is on it does not
     classify the event, walk a window, read a node or schedule a task. It then
     calls `releaseDictationState()`, which removes every pending callback, drops
     the cached focused field and removes the bubble.
   - `queueInsert()` / `requestEvaluate()` / `performInsert()` / the paste
     verification callback re-check the same gate, so a task queued just before
     Privacy mode was turned on cannot run afterwards.
   - A `SharedPreferences` listener reacts the moment either pref changes, so
     the cached field and pending work are dropped without waiting for the next
     accessibility event.
   - `OverlayDictationActivity.onCreate()` finishes immediately when blocked,
     and `OverlayDictationPage._loadPrefsAndStart()` closes before touching the
     microphone.
4. Posts **nothing** in the notification shade: the feature has no foreground
   service and therefore no notification, in Privacy mode or otherwise.
5. Does **not** disable the accessibility service. That is a user-owned Android
   setting; silently changing it would break insertion without consent and is
   exactly the kind of behaviour integrity checks look for.
6. Shows the user what is still on. The Privacy mode panel states whether the
   Dictation accessibility service is still enabled, explains that Android and
   some banking apps can see it, and offers **Manage accessibility permission**,
   which opens `Settings.ACTION_ACCESSIBILITY_SETTINGS` (falling back to the app
   details page if that screen is unavailable). The same dialog appears right
   after Privacy mode is turned on.

### What is still running while Privacy mode is on

| Component | State |
|---|---|
| Floating bubble window (`TYPE_APPLICATION_OVERLAY`) | **Removed.** `stopOverlay` → `BubbleOverlay.hide()` (and `OverlayService` no longer exists). |
| Foreground service / notification | **Do not exist** — there is no foreground service and the app posts no notification. |
| `OverlayDictationActivity` | **Cannot launch** (checked in `BubbleOverlay` and in `onCreate`). |
| Accessibility **binding** (`DictationAccessibilityService`) | **Still bound** — Android owns that. It ignores every event immediately and holds no node reference. |
| Accessibility **work** (classification, window walk, node read, bubble positioning, paste) | **None.** Gated before the event is touched. |
| Microphone | **Not used** — no overlay activity can start. |

A stale `overlay_enabled = true` left by an older build is normalised on
Settings load (Privacy mode wins) and written back, so the accessibility service
also sees the overlay as off on its next event.

## 3. Sensitive-app detection: what Android does and does not provide

Investigated public Android capabilities:

- **Accessibility window/app package names** are available, but using them to
  classify "banking" apps would expand the accessibility service into
  continuous foreground-app monitoring. That is privacy-invasive and is exactly
  the kind of capability integrity checks are designed to flag. It is not used.
- **`UsageStatsManager`** can report recently used packages, but requires the
  special `PACKAGE_USAGE_STATS` access and is not a reliable real-time
  foreground-app signal. It is not used.
- **`ActivityManager.getRunningAppProcesses()`** is restricted/undocumented for
  third-party foreground detection. It is not used.
- **`FLAG_SECURE`** tells you that a window is protected; it does not identify a
  banking app and cannot be read from other apps. It is not used.
- **Package-name blacklists** are unmaintainable (banking apps, web wrappers,
  regional apps, renamed packages) and would not guarantee compatibility. They
  are not used.

There is therefore **no reliable, privacy-preserving, automatic "sensitive app"
detection** that fits this feature. Dictation does not attempt to detect, hide
from, suppress or evade banking-app checks.

The supported manual workflow is:

1. Open Dictation → Settings → Floating Dictation Bubble.
2. Turn **Privacy mode** on (or simply turn **Enable floating bubble** off).
   This removes the bubble and its overlay window. No service or notification
   is involved.
3. Tap **Manage accessibility permission** in the Privacy mode panel (also
   offered in the dialog that appears when Privacy mode is enabled). Android
   opens Accessibility settings; find **Dictation bubble** and switch it off.
   Android requires the user to do this — an app cannot change this permission.
4. Automatic insertion into other apps stops until the service is switched back
   on. The normal Dictation app still records, transcribes, cleans, polishes and
   copies notes, so use clipboard paste while the service is off.
5. Re-enable the service from the same screen when cross-app insertion is
   wanted again.

The Settings screen also explains this in **Privacy & data**.

### 3.1 Is the accessibility service the remaining trigger?

Evidence, not certainty:

- The YONO SBI message names a *suspicious accessibility service*, not an
  overlay. That points at an enabled `AccessibilityService`, which is exactly
  what remains after Privacy mode.
- Android exposes every enabled service through
  `AccessibilityManager.getEnabledAccessibilityServiceList()` and through the
  `ENABLED_ACCESSIBILITY_SERVICES` secure setting. A banking app can read that
  list without any special permission. Dictation cannot hide from that list, and
  trying to would be evasion.
- The bubble, its overlay window, its foreground service and the overlay
  activity are all verifiably stopped by Privacy mode, so they are not the
  headline cause of a message that explicitly says "accessibility service".
  (The app no longer runs a foreground service or posts a notification at all.)
- The exact detection rule YONO uses (service list, `isAccessibilityTool`,
  capability flags, package reputation, Play Integrity, or a combination) is
  **not known and was not reverse-engineered**.

Conclusion: the enabled `DictationAccessibilityService` is the **most likely**
remaining trigger. Only a physical-device test can confirm it, and that test is
described in §6. Compatibility is **not** claimed.

## 4. Data flow disclosure

- Audio is recorded only while the user is recording. The overlay opens only
  from a bubble tap and auto-starts recording in that sheet; a blocked launch
  exits before the microphone is used.
- Audio is uploaded to **Groq** for speech-to-text.
- The transcript is sent to the **LLM provider(s) the user configured**
  (OpenRouter, Gemini, or a custom OpenAI-compatible endpoint) for cleaning,
  polishing and optional translation.
- API keys and preferences are stored in this app's `SharedPreferences` on the
  device. Auto Backup is disabled (`android:allowBackup="false"`) so those
  preferences are not copied to cloud backups.
- There is no analytics, crash reporting or telemetry SDK in the project.

## 5. Banking-app compatibility limitations

- The exact YONO SBI detection mechanism is **not confirmed**. This work does
  not claim the warning is resolved.
- Overlay and accessibility capabilities can be flagged by banking apps even
  when no bubble is visible. Privacy mode removes the overlay window and stops
  all Dictation accessibility work, but **the accessibility service stays
  enabled** until the user turns it off in Android Settings — that binding is the
  most likely remaining trigger (§3.1).
- No bypass, concealment, package-name spoofing or integrity-check evasion is
  implemented.

## 6. Physical-device verification procedure (and status)

**Status: not yet performed.** No Android device was attached to the build
machine (`adb devices` returned an empty list), so none of the steps below have
been executed. Do not report the YONO warning as fixed until they are.

1. Install the release APK, grant overlay + accessibility, enable the floating
   bubble, and open YONO SBI. Record whether the warning appears (expected: it
   does, because the accessibility service is on).
2. In Dictation → Settings, turn **Privacy mode** on. Confirm the bubble
   disappears and that no Dictation notification exists in the shade at any
   point (the app has no foreground service).
3. Tap **Manage accessibility permission** and switch **Dictation bubble** off.
4. Re-open YONO SBI and record the result.
5. If the warning persists, the accessibility service is not the only cause.
   Investigate before drawing conclusions — candidate factors to check:
   - other enabled accessibility services on the device (YONO may flag *any*),
   - `SYSTEM_ALERT_WINDOW` still granted to Dictation even with no window drawn,
   - the app being sideloaded / debug-signed / not from the Play Store,
   - other overlay or accessibility apps installed.
6. Re-enable the service and confirm the bubble, visualizer, recording and
   accessibility-assisted insertion all work again.

Useful read-only checks while testing:

```bash
adb shell settings get secure enabled_accessibility_services
adb shell dumpsys accessibility | head -40
adb logcat -s OverlayDebug
```

