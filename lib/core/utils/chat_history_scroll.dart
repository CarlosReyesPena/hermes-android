/// Pure history and scroll rules shared by [ChatScreen] and its tests.
List<Map<String, dynamic>> buildRestChatHistory(
  Iterable<Map<String, dynamic>> messages,
) {
  return [
    for (final message in messages)
      {'role': message['role'] ?? 'user', 'content': message['content'] ?? ''},
  ];
}

/// Stable namespace for a saved position in one connection and one session.
class ChatScrollPositionKey {
  final String connectionIdentity;
  final String sessionId;

  const ChatScrollPositionKey._(this.connectionIdentity, this.sessionId);

  factory ChatScrollPositionKey.fromConnection({
    required String connectionId,
    required String fallbackConnectionIdentity,
    required String sessionId,
  }) {
    final stableConnectionId = connectionId.trim();
    return ChatScrollPositionKey._(
      stableConnectionId.isNotEmpty
          ? 'id:$stableConnectionId'
          : 'fallback:${fallbackConnectionIdentity.trim()}',
      sessionId,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ChatScrollPositionKey &&
        other.connectionIdentity == connectionIdentity &&
        other.sessionId == sessionId;
  }

  @override
  int get hashCode => Object.hash(connectionIdentity, sessionId);
}

/// A one-frame scroll request for a saved offset or the current bottom.
class ChatScrollTarget {
  final double offset;
  final bool isBottom;

  const ChatScrollTarget.saved(this.offset) : isBottom = false;

  const ChatScrollTarget.bottom() : offset = 0, isBottom = true;
}

/// Keeps initial-position restoration separate from streaming auto-follow.
class ChatScrollCoordinator {
  final double nearBottomThreshold;
  bool _initialRestoreConsumed = false;
  bool _streaming = false;
  bool _followStreaming = false;

  ChatScrollCoordinator({this.nearBottomThreshold = 200});

  bool get initialRestoreConsumed => _initialRestoreConsumed;
  bool get shouldFollowStreaming => _streaming && _followStreaming;

  bool isNearBottom({required double pixels, required double maxScrollExtent}) {
    return pixels >= maxScrollExtent - nearBottomThreshold;
  }

  /// Returns the initial saved position (or bottom) exactly once.
  ChatScrollTarget? consumeInitialRestore(double? savedOffset) {
    if (_initialRestoreConsumed) return null;
    _initialRestoreConsumed = true;
    if (savedOffset == null || !savedOffset.isFinite) {
      return const ChatScrollTarget.bottom();
    }
    return ChatScrollTarget.saved(
      savedOffset.clamp(0, double.infinity).toDouble(),
    );
  }

  void beginStreaming({required bool isNearBottom}) {
    _streaming = true;
    _followStreaming = isNearBottom;
  }

  /// Only direct user scrolling changes the sticky streaming-follow choice.
  void updateFromUserScroll({required bool isNearBottom}) {
    if (!_streaming) return;
    _followStreaming = isNearBottom;
  }

  ChatScrollTarget? streamingContentChanged() {
    return shouldFollowStreaming ? const ChatScrollTarget.bottom() : null;
  }

  /// Completes streaming without consulting or replaying the saved position.
  ChatScrollTarget? endStreaming() {
    final target = shouldFollowStreaming
        ? const ChatScrollTarget.bottom()
        : null;
    _streaming = false;
    _followStreaming = false;
    return target;
  }

  void cancelStreaming() {
    _streaming = false;
    _followStreaming = false;
  }
}
