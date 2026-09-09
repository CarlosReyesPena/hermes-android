/// Canonical formatter for TTS voice labels in the Settings Voice picker.
///
/// Extracted from the private `_VoicePickerState._voiceLabel` so the wording
/// is testable and shared, following the app-wide "one formatter" rule.
library;

/// Formats a TTS voice as `locale (gender)  [name]`.
///
/// Rules:
/// - When [name] equals [locale] (the `getLanguages` fallback), the label is
///   just the locale — no redundant gender or bracket suffix.
/// - Otherwise the gender is inferred from [name]: `(female)` before `(male)`
///   because `"female"` contains `"male"` as a substring and must not be
///   mislabelled. No gender tag when neither word is present.
String formatVoiceLabel({required String name, required String locale}) {
  if (name == locale) return locale;
  final gender = name.toLowerCase().contains('female')
      ? '(female)'
      : name.toLowerCase().contains('male')
      ? '(male)'
      : '';
  final genderPart = gender.isEmpty ? '' : ' $gender';
  return '$locale$genderPart  [$name]';
}
