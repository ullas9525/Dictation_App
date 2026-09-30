import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_notes_app/main.dart';

/// Settings saves every change by itself, so it must not show anything to watch:
/// no save button and no "saved" tick in the top-right corner — while a change
/// still has to reach SharedPreferences on its own.
void main() {
  Future<void> pumpSettings(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the app bar is empty — no save button, no saved tick',
      (WidgetTester tester) async {
    await pumpSettings(tester);

    final AppBar appBar = tester.widget<AppBar>(find.byType(AppBar).first);
    expect(
      appBar.actions ?? <Widget>[],
      isEmpty,
      reason: 'Settings auto-saves, so its app bar must stay empty',
    );
    expect(find.byIcon(Icons.save), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsNothing,
    );
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('typing a key is stored after the debounce, with no save press',
      (WidgetTester tester) async {
    await pumpSettings(tester);

    await tester.enterText(find.byType(TextField).first, 'gsk_secret123');
    await tester.pump(); // keystroke: the debounce is armed, nothing written yet
    expect(
      (await SharedPreferences.getInstance()).getString('groq_api_key'),
      isNot('gsk_secret123'),
    );

    await tester.pump(const Duration(milliseconds: 400)); // debounce fires
    await tester.pumpAndSettle();

    expect(
      (await SharedPreferences.getInstance()).getString('groq_api_key'),
      'gsk_secret123',
    );
  });

  testWidgets('a change still in flight is flushed when Settings closes',
      (WidgetTester tester) async {
    await pumpSettings(tester);

    await tester.enterText(find.byType(TextField).first, 'gsk_leftopen');
    await tester.pump(); // debounce still pending

    await tester.pumpWidget(const SizedBox.shrink()); // leave the page
    await tester.pumpAndSettle();

    expect(
      (await SharedPreferences.getInstance()).getString('groq_api_key'),
      'gsk_leftopen',
    );
  });
}
