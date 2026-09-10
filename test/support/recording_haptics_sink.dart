import 'package:hermes_android/core/services/haptics_service.dart';

/// In-memory [HapticsSink] used to characterize what a chat actually asks the
/// platform to vibrate, without touching `HapticFeedback`.
class RecordingHapticsSink implements HapticsSink {
  final List<HermesHaptic> events = <HermesHaptic>[];

  @override
  void trigger(HermesHaptic kind) => events.add(kind);
}
