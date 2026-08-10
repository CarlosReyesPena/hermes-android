import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_clarify.dart';
import 'package:hermes_android/core/widgets/gateway_clarify_dialog.dart';

void main() {
  group('GatewayClarifyRequest', () {
    test(
      'parses the official question and normalizes choices like Desktop',
      () {
        final request = GatewayClarifyRequest.fromEventData({
          'request_id': 'clarify-123',
          'question': 'Which interface?',
          'choices': [
            'Compact',
            '',
            42,
            'two\nlines',
            'Detailed',
            List.filled(201, 'x').join(),
          ],
        });

        expect(request, isNotNull);
        expect(request!.requestId, 'clarify-123');
        expect(request.question, 'Which interface?');
        expect(request.choices, ['Compact', 'Detailed']);
        expect(request.multiSelect, isFalse);
      },
    );

    test('honors multi_select only when usable choices exist', () {
      final multiple = GatewayClarifyRequest.fromEventData({
        'request_id': 'clarify-multi',
        'question': 'Choose several',
        'choices': ['Compact', 'Detailed'],
        'multi_select': true,
      });
      final freeText = GatewayClarifyRequest.fromEventData({
        'request_id': 'clarify-free',
        'question': 'Describe it',
        'multi_select': true,
      });

      expect(multiple!.multiSelect, isTrue);
      expect(freeText!.multiSelect, isFalse);
    });

    test('ignores a request without request_id', () {
      expect(
        GatewayClarifyRequest.fromEventData({
          'question': 'Missing correlation ID',
        }),
        isNull,
      );
    });
  });

  group('GatewayClarifyDialog', () {
    testWidgets('stages a choice and sends it only after Continue', (
      tester,
    ) async {
      String? sentAnswer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GatewayClarifyDialog(
              request: GatewayClarifyRequest.fromEventData({
                'request_id': 'clarify-123',
                'question': 'Which interface?',
                'choices': ['Compact', 'Balanced'],
              })!,
              onRespond: (answer) async => sentAnswer = answer,
            ),
          ),
        ),
      );

      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('clarify-continue')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('clarify-choice-1')));
      await tester.pump();
      expect(sentAnswer, isNull);

      await tester.tap(find.byKey(const Key('clarify-continue')));
      await tester.pumpAndSettle();
      expect(sentAnswer, 'Balanced');
    });

    testWidgets('combines multiple choices in source order with Other', (
      tester,
    ) async {
      String? sentAnswer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GatewayClarifyDialog(
              request: GatewayClarifyRequest.fromEventData({
                'request_id': 'clarify-multi',
                'question': 'Choose several',
                'choices': ['Compact', 'Balanced', 'Detailed'],
                'multi_select': true,
              })!,
              onRespond: (answer) async => sentAnswer = answer,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('clarify-choice-2')));
      await tester.tap(find.byKey(const Key('clarify-choice-0')));
      await tester.enterText(
        find.byKey(const Key('clarify-other-field')),
        'Large text',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('clarify-continue')));
      await tester.pumpAndSettle();

      expect(sentAnswer, 'Compact, Detailed, Large text');
    });

    testWidgets('Skip sends the official empty answer', (tester) async {
      String? sentAnswer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GatewayClarifyDialog(
              request: GatewayClarifyRequest.fromEventData({
                'request_id': 'clarify-free',
                'question': 'Describe the desired interface',
              })!,
              onRespond: (answer) async => sentAnswer = answer,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('clarify-skip')));
      await tester.pumpAndSettle();
      expect(sentAnswer, '');
    });

    testWidgets('keeps the dialog open with a generic transport error', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GatewayClarifyDialog(
              request: GatewayClarifyRequest.fromEventData({
                'request_id': 'clarify-error',
                'question': 'What should Hermes do?',
              })!,
              onRespond: (_) async => throw Exception('raw gateway detail'),
            ),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('clarify-other-field')),
        'Try the mobile layout',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('clarify-continue')));
      await tester.pumpAndSettle();

      final error = tester.widget<Text>(find.byKey(const Key('clarify-error')));
      expect(error.data, isNot(contains('raw gateway detail')));
      expect(find.byKey(const Key('clarify-question')), findsOneWidget);
    });
  });
}
