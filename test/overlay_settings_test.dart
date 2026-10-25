// Tests for the floating-dictation settings helpers.
//
// These are deliberately pure: the native bubble is Android-only, so the
// parsing/serialisation used by both the Settings UI and the native prefs is
// what can be verified on a host machine.
//
// Run with: flutter test test/overlay_settings_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_app/main.dart';

void main() {
  group('transcript format', () {
    test('unknown or missing values default to polished', () {
      expect(transcriptFormatFromPref(null), TranscriptFormat.polished);
      expect(transcriptFormatFromPref(''), TranscriptFormat.polished);
      expect(transcriptFormatFromPref('translated'), TranscriptFormat.polished);
    });

    test('every stored value round-trips', () {
      for (final TranscriptFormat format in TranscriptFormat.values) {
        expect(transcriptFormatFromPref(format.name), format);
      }
    });

    test('labels used by Settings and the result chips', () {
      expect(TranscriptFormat.raw.settingLabel, 'Raw transcript');
      expect(TranscriptFormat.clean.settingLabel, 'Clean transcript');
      expect(TranscriptFormat.polished.settingLabel, 'Polished note');
      expect(TranscriptFormat.raw.label, 'Raw');
      expect(TranscriptFormat.clean.label, 'Clean');
      expect(TranscriptFormat.polished.label, 'Polished');
    });
  });

  group('target apps', () {
    test('empty input falls back to WhatsApp', () {
      expect(parseOverlayTargetApps(null), <String>[defaultOverlayTargetApps]);
      expect(parseOverlayTargetApps(''), <String>[defaultOverlayTargetApps]);
      expect(parseOverlayTargetApps(' , '), <String>[defaultOverlayTargetApps]);
    });

    test('parsing trims blanks and removes duplicates while keeping order', () {
      expect(
        parseOverlayTargetApps(' com.whatsapp , com.example.app,com.whatsapp, * '),
        <String>['com.whatsapp', 'com.example.app', '*'],
      );
    });

    test('serialising normalises and never writes an empty list', () {
      expect(
        overlayTargetAppsValue(<String>[' com.whatsapp ', 'com.whatsapp', '']),
        'com.whatsapp',
      );
      expect(overlayTargetAppsValue(<String>[]), defaultOverlayTargetApps);
      expect(
        overlayTargetAppsValue(<String>['com.whatsapp', '*']),
        'com.whatsapp,*',
      );
    });

    test('serialised values parse back identically', () {
      final List<String> apps = <String>['com.whatsapp', 'com.example.app'];
      expect(parseOverlayTargetApps(overlayTargetAppsValue(apps)), apps);
    });

    test('package names are validated; * is the only wildcard', () {
      expect(isValidOverlayTargetApp('com.whatsapp'), isTrue);
      expect(isValidOverlayTargetApp('com.example.my_app2'), isTrue);
      expect(isValidOverlayTargetApp('*'), isTrue);
      expect(isValidOverlayTargetApp('whatsapp'), isFalse);
      expect(isValidOverlayTargetApp('com.whatsapp '), isTrue);
      expect(isValidOverlayTargetApp('com..app'), isFalse);
      expect(isValidOverlayTargetApp('com.whatsapp.extra'), isTrue);
      expect(isValidOverlayTargetApp('com.whatsapp/evil'), isFalse);
      expect(isValidOverlayTargetApp(''), isFalse);
    });

    test('friendly labels for the chips', () {
      expect(overlayTargetAppLabel('com.whatsapp'), 'WhatsApp');
      expect(overlayTargetAppLabel('*'), 'Any app');
      expect(overlayTargetAppLabel('com.example.app'), 'com.example.app');
    });
  });

  group('prefs contract', () {
    test('keys are the exact strings the native service reads', () {
      // DictationAccessibilityService reads
      // FlutterSharedPreferences -> "flutter." + these keys.
      expect(OverlayPrefs.enabled, 'overlay_enabled');
      expect(OverlayPrefs.targetFormat, 'overlay_target_format');
      expect(OverlayPrefs.targetApps, 'overlay_target_apps');
    });
  });

  group('overlay status', () {
    test('ready only when supported and both grants exist', () {
      expect(
        const OverlayStatus(
          canDrawOverlays: true,
          accessibilityEnabled: true,
        ).ready,
        isTrue,
      );
      expect(
        const OverlayStatus(
          canDrawOverlays: true,
          accessibilityEnabled: false,
        ).ready,
        isFalse,
      );
      expect(
        const OverlayStatus(
          canDrawOverlays: false,
          accessibilityEnabled: true,
        ).ready,
        isFalse,
      );
      expect(OverlayStatus.unsupported.ready, isFalse);
    });
  });
}
