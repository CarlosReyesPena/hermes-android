import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/android_share_intent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidShareIntentService.channelName);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('initializes from a cold-start share and consumes it once', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getInitialShare');
          return '  https://example.com/article  ';
        });

    final service = AndroidShareIntentService();
    await service.initialize();

    expect(service.pendingText.value, 'https://example.com/article');
    expect(service.takePending(), 'https://example.com/article');
    expect(service.takePending(), isNull);
  });

  test('receives a warm share from Android', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    final service = AndroidShareIntentService();
    await service.initialize();

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            const MethodCall('shareText', 'Read this later'),
          ),
          (_) {},
        );

    expect(service.takePending(), 'Read this later');
  });
}
