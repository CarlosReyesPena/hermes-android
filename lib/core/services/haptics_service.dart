import 'package:flutter/services.dart';

/// The kind of tactile feedback a chat event deserves.
///
/// Describing the event as data keeps the mapping testable and leaves the
/// platform-specific call in one place.
enum HermesHaptic {
  /// A turn finished with an answer (light confirmation).
  completion,

  /// A turn failed and needs attention (strong, distinct from completion).
  failure,

  /// An approval, clarification, secret, or sudo request is waiting (urgent).
  attention,

  /// A destructive confirmation is about to run (warning).
  destructive,
}

/// The platform seam [HapticsService] vibrates through.
///
/// The production implementation is [PluginHapticsSink]; tests supply a
/// recording double so haptic behaviour can be verified without a platform
/// channel.
abstract class HapticsSink {
  void trigger(HermesHaptic kind);
}

/// Default sink backed by Flutter's `HapticFeedback`.
class PluginHapticsSink implements HapticsSink {
  const PluginHapticsSink();

  @override
  void trigger(HermesHaptic kind) {
    switch (kind) {
      case HermesHaptic.completion:
        HapticFeedback.lightImpact();
      case HermesHaptic.failure:
        HapticFeedback.heavyImpact();
      case HermesHaptic.attention:
        HapticFeedback.mediumImpact();
      case HermesHaptic.destructive:
        HapticFeedback.heavyImpact();
    }
  }
}

/// Centralises the chat's tactile feedback.
///
/// The mapping from event to [HermesHaptic] lives here, so screens only call
/// the domain-named methods and never reach for `HapticFeedback` directly.
class HapticsService {
  final HapticsSink _sink;

  HapticsService({HapticsSink? sink})
    : _sink = sink ?? const PluginHapticsSink();

  void onTurnCompleted() => _sink.trigger(HermesHaptic.completion);

  void onTurnFailed() => _sink.trigger(HermesHaptic.failure);

  void onAttentionNeeded() => _sink.trigger(HermesHaptic.attention);

  void onDestructiveConfirmation() => _sink.trigger(HermesHaptic.destructive);
}
