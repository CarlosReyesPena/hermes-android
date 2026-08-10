import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Delivers Android notifications when a gateway turn completes while the app
/// is backgrounded, mirroring the Hermes Desktop tray notification behaviour.
///
/// The service owns a single notification channel ("Hermes Turns") and exposes
/// one idempotent [ensureInitialized] method safe to call from any lifecycle
/// point (including before the Flutter engine binding is ready).
class TurnNotificationService {
  static const _channelId = 'hermes_turn_notifications';
  static const _channelName = 'Hermes Turns';
  static const _channelDescription =
      'Notifications for completed background turns';

  final FlutterLocalNotificationsPlugin _plugin;

  bool _initialized = false;

  TurnNotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// One-shot initialisation of the Hermes notification channel.
  ///
  /// Safe to call repeatedly — subsequent calls are no-ops.
  Future<void> ensureInitialized() async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(settings);
    _initialized = true;
  }

  /// Posts a notification when a gateway turn completes while the app is
  /// backgrounded.
  ///
  /// [turnSummary] is a short description (e.g. session title or prompt
  /// excerpt); [turnId] ensures the notification is stable and replaceable.
  Future<void> showTurnCompleted({
    required String turnSummary,
    required String turnId,
  }) async {
    if (!_initialized) return;

    final id = turnId.hashCode.abs() % 0x7FFFFFFF;

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      id,
      'Hermes response ready',
      turnSummary,
      details,
      payload: turnId,
    );
  }

  /// Cancels a specific turn notification.
  Future<void> cancelTurnCompleted(String turnId) async {
    if (!_initialized) return;
    final id = turnId.hashCode.abs() % 0x7FFFFFFF;
    await _plugin.cancel(id);
  }

  /// Removes all Hermes turn notifications.
  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }
}
