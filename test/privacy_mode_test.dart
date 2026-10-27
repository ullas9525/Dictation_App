// Tests for the explicit Privacy mode kill switch.
//
// Privacy mode must win over a stale "overlay enabled" value, persist both
// prefs for the native services, and leave the ordinary note UI untouched.
//
// Run with: flutter test test/privacy_mode_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_notes_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpSettings(
    WidgetTester tester, {
    Map<String, Object> values = const <String, Object>{},
  }) async {
    SharedPreferences.setMockInitialValues(values);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
              create: (_) => ThemeProvider()),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The Settings list is long; the overlay/privacy controls live near the
  /// bottom and are only built once they are scrolled into view.
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Privacy mode force-disables the overlay and persists both keys',
      (WidgetTester tester) async {
    await pumpSettings(tester, values: <String, Object>{
      'llm_providers': '[]',
      'overlay_enabled': true,
      'overlay_privacy_mode': false,
    });

    await scrollTo(tester, find.widgetWithText(SwitchListTile, 'Privacy mode'));

    final SwitchListTile privacyTile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Privacy mode'),
    );
    expect(privacyTile.value, isFalse);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Privacy mode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('overlay_privacy_mode'), isTrue);
    expect(prefs.getBool('overlay_enabled'), isFalse);

    final SwitchListTile enableTile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Enable floating bubble'),
    );
    expect(enableTile.value, isFalse);
    expect(enableTile.onChanged, isNull,
        reason: 'the bubble cannot be enabled while Privacy mode is on');
    await scrollTo(
        tester, find.textContaining('Floating bubble and overlay window'));
    expect(find.textContaining('Floating bubble and overlay window'),
        findsOneWidget);
  });

  testWidgets('a stale enabled + privacy pair is normalised on load',
      (WidgetTester tester) async {
    await pumpSettings(tester, values: <String, Object>{
      'llm_providers': '[]',
      'overlay_enabled': true,
      'overlay_privacy_mode': true,
    });

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('overlay_privacy_mode'), isTrue);
    expect(prefs.getBool('overlay_enabled'), isFalse,
        reason: 'Privacy mode must win over a stale enabled flag');

    await scrollTo(tester, find.widgetWithText(SwitchListTile, 'Privacy mode'));

    final SwitchListTile privacyTile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Privacy mode'),
    );
    expect(privacyTile.value, isTrue);
    await scrollTo(
        tester, find.textContaining('Floating bubble and overlay window'));
    expect(find.textContaining('Floating bubble and overlay window'),
        findsOneWidget);
  });

  testWidgets('the privacy disclosure covers permissions, data and revocation',
      (WidgetTester tester) async {
    await pumpSettings(tester, values: <String, Object>{
      'llm_providers': '[]',
    });

    await scrollTo(tester, find.text('Privacy & data'));
    expect(find.text('Privacy & data'), findsOneWidget);

    await tester.dragUntilVisible(
      find.textContaining('cannot guarantee compatibility with banking'),
      find.byType(Scrollable).first,
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot guarantee compatibility with banking'),
        findsOneWidget);
    expect(find.textContaining('Audio is sent to Groq'), findsOneWidget);
    // The disclosure must not claim Privacy mode disables accessibility.
    expect(
      find.textContaining('cannot turn off the accessibility service'),
      findsOneWidget,
    );
  });

  testWidgets('Privacy mode shows an accurate accessibility state and the '
      'only supported way to change it', (WidgetTester tester) async {
    await pumpSettings(tester, values: <String, Object>{
      'llm_providers': '[]',
      'overlay_privacy_mode': true,
    });

    await scrollTo(
      tester,
      find.widgetWithText(OutlinedButton, 'Manage accessibility permission'),
    );

    expect(
      find.widgetWithText(OutlinedButton, 'Manage accessibility permission'),
      findsOneWidget,
    );
    expect(
      find.text('Dictation accessibility service'),
      findsOneWidget,
    );
    // Widget tests run off-device, so the status is "unsupported" and the
    // panel must say so rather than pretend the service is disabled.
    expect(
      find.textContaining('Accessibility settings are Android-only'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Floating bubble and overlay window'),
      findsOneWidget,
    );
  });

  group('privacyAccessibilitySummary', () {
    test('reports a still-enabled accessibility service honestly', () {
      final String text = privacyAccessibilitySummary(
        supported: true,
        accessibilityEnabled: true,
      );
      expect(text, contains('Still ON'));
      expect(text, contains('banking apps'));
      // It must never claim the service was disabled.
      expect(text.toLowerCase(), isNot(contains('off —')));
    });

    test('reports a disabled accessibility service', () {
      expect(
        privacyAccessibilitySummary(supported: true, accessibilityEnabled: false),
        startsWith('Off'),
      );
    });

    test('is Android-only off-device', () {
      expect(
        privacyAccessibilitySummary(supported: false, accessibilityEnabled: true),
        'Accessibility settings are Android-only.',
      );
    });

    test('stillOn only when Android reports the service as enabled', () {
      expect(
        privacyAccessibilityStillOn(supported: true, accessibilityEnabled: true),
        isTrue,
      );
      expect(
        privacyAccessibilityStillOn(supported: true, accessibilityEnabled: false),
        isFalse,
      );
      expect(
        privacyAccessibilityStillOn(supported: false, accessibilityEnabled: true),
        isFalse,
      );
    });
  });
}
