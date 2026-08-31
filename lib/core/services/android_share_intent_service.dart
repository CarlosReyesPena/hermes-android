import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Receives text/URLs sent to Hermes through Android's ACTION_SEND contract.
class AndroidShareIntentService {
  static const channelName = 'com.hermesagent.hermes_android/share';
  static const _channel = MethodChannel(channelName);

  final ValueNotifier<String?> pendingText = ValueNotifier<String?>(null);
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    try {
      _publish(await _channel.invokeMethod<String>('getInitialShare'));
    } on MissingPluginException {
      // Non-Android hosts have no share-intent bridge.
    }
  }

  String? takePending() {
    final value = pendingText.value;
    pendingText.value = null;
    return value;
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'shareText') {
      _publish(call.arguments as String?);
    }
  }

  void _publish(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return;
    pendingText.value = text;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    pendingText.dispose();
  }
}
