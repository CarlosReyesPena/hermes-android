/// A request-ID keyed clarification prompt emitted by Hermes.
class GatewayClarifyRequest {
  final String requestId;
  final String question;
  final List<String> choices;
  final bool multiSelect;

  const GatewayClarifyRequest({
    required this.requestId,
    required this.question,
    required this.choices,
    required this.multiSelect,
  });

  bool get hasChoices => choices.isNotEmpty;

  static GatewayClarifyRequest? fromEventData(Map<String, dynamic> data) {
    final requestId = data['request_id']?.toString().trim() ?? '';
    if (requestId.isEmpty) return null;

    final rawChoices = data['choices'];
    final choices = rawChoices is List
        ? rawChoices
              .whereType<String>()
              .where(
                (choice) =>
                    choice.trim().isNotEmpty &&
                    choice.length <= 200 &&
                    !choice.contains('\n') &&
                    !choice.contains('\r'),
              )
              .toList(growable: false)
        : const <String>[];
    final question = data['question']?.toString().trim() ?? '';

    return GatewayClarifyRequest(
      requestId: requestId,
      question: question.isEmpty
          ? 'Hermes needs more information to continue.'
          : question,
      choices: choices,
      multiSelect: data['multi_select'] == true && choices.isNotEmpty,
    );
  }
}
