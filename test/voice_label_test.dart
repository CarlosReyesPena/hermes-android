import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/utils/voice_label.dart';

void main() {
  group('formatVoiceLabel', () {
    test('returns the locale alone when name equals locale', () {
      expect(formatVoiceLabel(name: 'en-US', locale: 'en-US'), 'en-US');
    });

    test('labels a female voice (female) without the male substring trap', () {
      // "female" contains "male" — the female branch must win, not (male).
      expect(
        formatVoiceLabel(name: 'en-US-female', locale: 'en-US'),
        'en-US (female)  [en-US-female]',
      );
    });

    test('labels a male voice (male)', () {
      expect(
        formatVoiceLabel(name: 'en-US-male', locale: 'en-US'),
        'en-US (male)  [en-US-male]',
      );
    });

    test('omits the gender tag when neither word is present', () {
      expect(
        formatVoiceLabel(name: 'Google US English', locale: 'en-US'),
        'en-US  [Google US English]',
      );
    });
  });
}
