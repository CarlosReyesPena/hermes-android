import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/session_search_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to local search so upgrades do not change behaviour', () async {
    final store = await SessionSearchPreferences.open();

    expect(
      store.readMode(connectionIdentity: 'https://gateway.example|/api|'),
      SessionSearchMode.local,
    );
  });

  test('restores the server mode for the same connection', () async {
    final store = await SessionSearchPreferences.open();
    await store.saveMode(
      connectionIdentity: 'https://gateway.example|/api|',
      mode: SessionSearchMode.server,
    );

    expect(
      store.readMode(connectionIdentity: 'https://gateway.example|/api|'),
      SessionSearchMode.server,
    );
  });

  test('keeps the search mode isolated per connection', () async {
    final store = await SessionSearchPreferences.open();
    await store.saveMode(
      connectionIdentity: 'connection-a',
      mode: SessionSearchMode.server,
    );

    expect(
      store.readMode(connectionIdentity: 'connection-b'),
      SessionSearchMode.local,
    );
  });

  test('clear restores the local default', () async {
    final store = await SessionSearchPreferences.open();
    await store.saveMode(
      connectionIdentity: 'connection-a',
      mode: SessionSearchMode.server,
    );
    await store.clear(connectionIdentity: 'connection-a');

    expect(
      store.readMode(connectionIdentity: 'connection-a'),
      SessionSearchMode.local,
    );
  });

  test('treats an unknown stored value as local rather than throwing', () {
    expect(
      SessionSearchModeCodec.fromStorage('semantic-v9'),
      SessionSearchMode.local,
    );
    expect(SessionSearchModeCodec.fromStorage(null), SessionSearchMode.local);
  });

  test('round-trips every mode through its storage value', () {
    for (final mode in SessionSearchMode.values) {
      expect(
        SessionSearchModeCodec.fromStorage(mode.storageValue),
        mode,
        reason: 'mode ${mode.name} must survive a save/read cycle',
      );
    }
  });
}
