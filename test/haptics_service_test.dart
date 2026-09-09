import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/haptics_service.dart';

class _RecordingSink implements HapticsSink {
  final List<HermesHaptic> events = [];

  @override
  void trigger(HermesHaptic kind) => events.add(kind);
}

void main() {
  test('maps domain events to the right haptic kinds', () {
    final sink = _RecordingSink();
    final service = HapticsService(sink: sink);

    service.onTurnCompleted();
    service.onTurnFailed();
    service.onAttentionNeeded();
    service.onDestructiveConfirmation();

    expect(sink.events, const [
      HermesHaptic.completion,
      HermesHaptic.failure,
      HermesHaptic.attention,
      HermesHaptic.destructive,
    ]);
  });
}
