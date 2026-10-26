// Tests for KI-04: The Processing step must show an indeterminate loading
// indicator rather than a frozen 0% determinate ring.
//
// Run with: flutter test test/processing_stepper_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget pumpStepper({
    required ProcessingStep currentStep,
    double transcriptionProgress = 0.0,
    String transcriptionLabel = '',
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ProcessingStepper(
            currentStep: currentStep,
            transcriptionProgress: transcriptionProgress,
            transcriptionLabel: transcriptionLabel,
          ),
        ),
      ),
    );
  }

  group('ProcessingStepper', () {
    testWidgets('shows an indeterminate indicator during Processing when busy',
        (WidgetTester tester) async {
      await tester.pumpWidget(pumpStepper(
        currentStep: ProcessingStep.processing,
        transcriptionLabel: 'AI is busy processing...',
      ));

      final indicator = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator));
      // Null value means indeterminate (spinning) rather than a fixed 0%.
      expect(indicator.value, isNull);
    });

    testWidgets('shows the busy label below the stepper during Processing',
        (WidgetTester tester) async {
      await tester.pumpWidget(pumpStepper(
        currentStep: ProcessingStep.processing,
        transcriptionLabel: 'AI is busy processing...',
      ));

      expect(find.text('AI is busy processing...'), findsOneWidget);
    });

    testWidgets('does not show a label when not processing',
        (WidgetTester tester) async {
      await tester.pumpWidget(pumpStepper(
        currentStep: ProcessingStep.uploading,
        transcriptionLabel: '',
      ));

      expect(find.text('AI is busy processing...'), findsNothing);
    });

    testWidgets('shows a determinate value when the label is not "busy"',
        (WidgetTester tester) async {
      await tester.pumpWidget(pumpStepper(
        currentStep: ProcessingStep.processing,
        transcriptionProgress: 0.5,
        transcriptionLabel: 'Processing...',
      ));

      final indicator = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator));
      expect(indicator.value, 0.5);
    });
  });
}
