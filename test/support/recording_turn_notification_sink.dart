import 'package:hermes_android/core/services/turn_notification_service.dart';

/// In-memory [TurnNotificationSink] used to characterize what Hermes actually
/// posts to Android, without touching the platform plugin.
class RecordingTurnNotificationSink implements TurnNotificationSink {
  final List<TurnNotification> shown = <TurnNotification>[];
  final List<int> cancelled = <int>[];

  int initializeCount = 0;
  int cancelAllCount = 0;
  int permissionRequestCount = 0;

  /// The tap callback the service handed [initialize], so a test can fire it
  /// the way the platform would when the user selects a notification.
  void Function(String? payload)? onDidReceiveNotificationResponse;

  /// The payload [getLaunchPayload] returns, standing in for the platform's
  /// cold-start launch details.
  String? launchPayload;

  /// When set, [getLaunchPayload] throws it — mirroring a platform channel
  /// that cannot report launch details.
  Object? launchPayloadError;

  /// Result [requestPermission] returns: true granted, false denied, null when
  /// the platform has no runtime notification gate (iOS, Android < 13).
  bool? permissionResult;

  /// When set, [requestPermission] throws it.
  Object? permissionError;

  /// When set, [initialize] throws it — mirroring a platform channel that is
  /// unavailable (test environment, missing plugin registration).
  Object? initializeError;

  @override
  Future<void> initialize({
    void Function(String? payload)? onDidReceiveNotificationResponse,
  }) async {
    initializeCount++;
    this.onDidReceiveNotificationResponse = onDidReceiveNotificationResponse;
    final error = initializeError;
    if (error != null) throw error;
  }

  @override
  Future<String?> getLaunchPayload() async {
    final error = launchPayloadError;
    if (error != null) throw error;
    return launchPayload;
  }

  /// Simulates the user tapping a notification carrying [payload].
  void fireTap(String? payload) =>
      onDidReceiveNotificationResponse?.call(payload);

  @override
  Future<bool?> requestPermission() async {
    permissionRequestCount++;
    final error = permissionError;
    if (error != null) throw error;
    return permissionResult;
  }

  @override
  Future<void> show(TurnNotification notification) async {
    shown.add(notification);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCount++;
  }
}
