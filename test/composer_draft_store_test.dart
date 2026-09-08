import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/composer_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('round-trips a draft for the same connection and chat', () async {
    final store = await ComposerDraftStore.open();
    await store.write(
      connectionId: 'conn-1',
      sessionId: 'chat-1',
      text: 'half-typed prompt',
    );

    expect(
      store.read(connectionId: 'conn-1', sessionId: 'chat-1'),
      'half-typed prompt',
    );
  });

  test('keeps drafts scoped per session', () async {
    final store = await ComposerDraftStore.open();
    await store.write(
      connectionId: 'conn-1',
      sessionId: 'chat-1',
      text: 'prompt a',
    );

    expect(store.read(connectionId: 'conn-1', sessionId: 'chat-2'), isNull);
  });

  test('keeps drafts scoped per connection', () async {
    final store = await ComposerDraftStore.open();
    await store.write(
      connectionId: 'conn-1',
      sessionId: 'shared-chat',
      text: 'prompt a',
    );

    expect(
      store.read(connectionId: 'conn-2', sessionId: 'shared-chat'),
      isNull,
    );
  });

  test('clear removes the draft after a successful send', () async {
    final store = await ComposerDraftStore.open();
    await store.write(
      connectionId: 'conn-1',
      sessionId: 'chat-1',
      text: 'prompt a',
    );

    await store.clear(connectionId: 'conn-1', sessionId: 'chat-1');

    expect(store.read(connectionId: 'conn-1', sessionId: 'chat-1'), isNull);
  });

  test('writing a blank value clears the draft', () async {
    final store = await ComposerDraftStore.open();
    await store.write(
      connectionId: 'conn-1',
      sessionId: 'chat-1',
      text: 'prompt a',
    );

    await store.write(connectionId: 'conn-1', sessionId: 'chat-1', text: '   ');

    expect(store.read(connectionId: 'conn-1', sessionId: 'chat-1'), isNull);
  });

  test('rejects a blank connection or session id', () async {
    final store = await ComposerDraftStore.open();

    expect(
      () => store.read(connectionId: '', sessionId: 'chat-1'),
      throwsArgumentError,
    );
    expect(
      () => store.read(connectionId: 'conn-1', sessionId: ''),
      throwsArgumentError,
    );
  });
}
