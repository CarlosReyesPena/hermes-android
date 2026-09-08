import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/session_organizer_settings_card.dart';

void main() {
  testWidgets('automatic assignment and AI classification save independently', (
    tester,
  ) async {
    final saved = <SessionOrganizerSettings>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SessionOrganizerSettingsCard(
              initialSettings: const SessionOrganizerSettings(
                assignmentMode: 'dry-run',
                aiEnabled: false,
                provider: 'openrouter',
                model: 'model-a',
              ),
              providerModels: const {
                'openrouter': ['model-a'],
              },
              onSave: (settings) async => saved.add(settings),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Automatic project assignment'), findsOneWidget);
    expect(find.text('Use AI classification'), findsOneWidget);
    await tester.tap(find.byKey(const Key('automatic-assignment-switch')));
    await tester.pump();
    await tester.tap(find.text('Save organization settings'));
    await tester.pumpAndSettle();

    expect(saved.single.assignmentMode, 'auto');
    expect(saved.single.aiEnabled, isFalse);
  });

  testWidgets('AI curator can be enabled and its model selected', (
    tester,
  ) async {
    final saved = <SessionOrganizerSettings>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionOrganizerSettingsCard(
            initialSettings: const SessionOrganizerSettings(
              assignmentMode: 'dry-run',
              aiEnabled: false,
              provider: 'openrouter',
              model: 'model-a',
            ),
            providerModels: const {
              'openrouter': ['model-a', 'model-b'],
              'gemini': ['gemini-flash'],
            },
            onSave: (settings) async => saved.add(settings),
          ),
        ),
      ),
    );

    expect(find.text('Use AI classification'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ai-classification-switch')));
    await tester.pump();
    await tester.tap(find.text('model-a').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('model-b').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save organization settings'));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.aiEnabled, isTrue);
    expect(saved.single.provider, 'openrouter');
    expect(saved.single.model, 'model-b');
  });

  testWidgets('disabled AI curator keeps deterministic classification active', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionOrganizerSettingsCard(
            initialSettings: const SessionOrganizerSettings(
              assignmentMode: 'dry-run',
              aiEnabled: false,
              provider: 'openrouter',
              model: 'model-a',
            ),
            providerModels: const {
              'openrouter': ['model-a'],
            },
            onSave: (_) async {},
          ),
        ),
      ),
    );

    expect(
      find.text('Off — fast deterministic matching remains active.'),
      findsOneWidget,
    );
  });
}
