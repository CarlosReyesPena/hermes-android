// Chat screen with real-time streaming via REST API.
// Uses REST endpoints: POST /api/sessions/{id}/chat and
// GET /api/sessions/{id}/messages.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/connection_manager.dart';
import '../services/chat_model_override_store.dart';
import '../services/desktop_gateway_client.dart';
import '../services/ws_client.dart';
import '../models/gateway_activity.dart';
import '../models/gateway_approval.dart';
import '../models/gateway_clarify.dart';
import '../models/gateway_insight.dart';
import '../models/gateway_sensitive_prompt.dart';
import '../utils/message_content.dart';
import '../utils/responsive.dart';
import '../widgets/gateway_activity_card.dart';
import '../widgets/gateway_approval_dialog.dart';
import '../widgets/gateway_clarify_dialog.dart';
import '../widgets/gateway_insight_card.dart';
import '../widgets/gateway_sensitive_prompt_dialog.dart';

const _maxInlineImageBytes = 680 * 1024;
const _maxRemoteFileBytes = 16 * 1024 * 1024;
const _maxRemoteAttachments = 10;

class _PendingImage {
  final Uint8List bytes;
  final String dataUrl;
  final String name;

  const _PendingImage({
    required this.bytes,
    required this.dataUrl,
    required this.name,
  });
}

enum _AttachmentStatus { ready, uploading, attached, failed }

class _PendingFile {
  final Uint8List bytes;
  final String dataUrl;
  final String name;
  final bool isImage;
  _AttachmentStatus status = _AttachmentStatus.ready;
  String? refText;
  String? error;

  _PendingFile({
    required this.bytes,
    required this.dataUrl,
    required this.name,
    this.isImage = false,
  });
}

class _ModelChoice {
  final String provider;
  final String model;

  const _ModelChoice({required this.provider, required this.model});
}

class _ModelSelection {
  final _ModelChoice choice;
  final String reasoningEffort;

  const _ModelSelection({required this.choice, required this.reasoningEffort});
}

const _reasoningEffortLabels = <String, String>{
  'none': 'Off (no thinking)',
  'minimal': 'Minimal',
  'low': 'Low',
  'medium': 'Medium',
  'high': 'High',
  'xhigh': 'Extra High',
  'max': 'Max',
  'ultra': 'Ultra',
};

class _GatewayReasoningDisplay {
  final String text;
  final bool initiallyExpanded;

  const _GatewayReasoningDisplay(this.text, this.initiallyExpanded);
}

enum _ResponseTransport { none, rest, desktop }

class _PendingSensitivePrompt {
  final GatewaySensitivePromptRequest request;
  final int responseGeneration;

  const _PendingSensitivePrompt(this.request, this.responseGeneration);
}

class _PendingClarifyPrompt {
  final GatewayClarifyRequest request;
  final int responseGeneration;

  const _PendingClarifyPrompt(this.request, this.responseGeneration);
}

class ChatScreen extends StatefulWidget {
  final SavedConnection connection;
  final Session session;

  const ChatScreen({
    required this.connection,
    required this.session,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _messages = [];
  final List<GatewayToolActivity> _toolActivities = [];
  final List<GatewaySubagentActivity> _subagentActivities = [];
  final Map<String, GatewayNotification> _gatewayNotifications = {};
  final Map<String, Timer> _notificationTimers = {};
  late final List<GatewayNotice> _gatewayNotices;
  bool _loading = true;
  String? _error;
  late final ApiClient _client;
  late final GatewayChatClient _gateway;
  late final Future<ChatModelOverrideStore> _chatModelStore;
  late final Future<void> _sessionModelRestore;
  DesktopGatewayClient? _desktopGateway;
  DesktopConnectionState _desktopConnectionState =
      DesktopConnectionState.disconnected;

  // Chat sending state
  final _textController = TextEditingController();
  final _imagePicker = ImagePicker();
  _PendingImage? _pendingImage;
  final List<_PendingFile> _pendingFiles = [];
  String? _sessionModel;
  String? _sessionProvider;
  String? _sessionReasoningEffort;
  bool _sessionModelOverride = false;
  bool _loadingModelOptions = false;
  bool _changingModel = false;
  bool _sending = false;
  bool _streaming = false;
  GatewayTurnStatus? _gatewayTurnStatus;
  _ResponseTransport _activeResponseTransport = _ResponseTransport.none;
  int _responseGeneration = 0;
  bool _approvalDialogOpen = false;
  final List<_PendingSensitivePrompt> _sensitivePromptQueue = [];
  final Set<String> _expiredSensitivePromptIds = {};
  _PendingSensitivePrompt? _activeSensitivePrompt;
  bool _sensitivePromptRouteOpen = false;
  final List<_PendingClarifyPrompt> _clarifyPromptQueue = [];
  _PendingClarifyPrompt? _activeClarifyPrompt;

  // Voice input / spoken replies
  final SpeechToText _speechToText = SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();
  bool _speechAvailable = false;
  bool _listening = false;
  bool _voiceReplyEnabled = true;
  bool _awaitingVoiceReply = false;
  String? _voiceStatus;
  String? _sttLocaleId;

  // Verbose mode
  bool _verboseMode = false;

  // Scroll management
  final _scrollController = ScrollController();
  bool _showScrollToBottom = false;
  double _lastPixels = 0;
  static final Map<String, double> _savedPositions = {};
  static final Map<String, List<GatewayNotice>> _savedGatewayNotices = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
      pathPrefix: widget.connection.gatewayPrefix ?? '',
    );
    _gateway = GatewayChatClient(_client);
    _gatewayNotices = List<GatewayNotice>.from(
      _savedGatewayNotices[_gatewayNoticeIdentity] ?? const [],
    );
    _chatModelStore = ChatModelOverrideStore.open();
    _sessionModelRestore = _restoreSessionModelOverride();
    if (widget.connection.desktopGatewayUrl?.trim().isNotEmpty == true) {
      try {
        _desktopGateway = DesktopGatewayClient.fromConnection(
          widget.connection,
        );
        _desktopGateway!.setAsyncEventListener(_handleDesktopAsyncEvent);
        _desktopGateway!.setConnectionListener((state) {
          if (mounted) setState(() => _desktopConnectionState = state);
        });
        unawaited(_ensureDesktopSession());
      } on ArgumentError {
        // The regular mobile chat remains usable; selection surfaces the
        // actionable configuration error when Desktop attachments are needed.
        _desktopGateway = null;
      }
    }
    _fetchMessages();
    _loadVerboseMode();
    _initVoice();
    _recoverLostImage();
    _scrollController.addListener(_onScroll);
  }

  String get _chatModelConnectionIdentity =>
      '${widget.connection.baseUrl}|'
      '${widget.connection.gatewayPrefix ?? ''}|'
      '${widget.connection.desktopGatewayUrl ?? ''}';

  String get _gatewayNoticeIdentity =>
      '$_chatModelConnectionIdentity|${widget.session.id}';

  Future<void> _restoreSessionModelOverride() async {
    final store = await _chatModelStore;
    final override = store.read(
      connectionIdentity: _chatModelConnectionIdentity,
      sessionId: widget.session.id,
    );
    if (!mounted || override == null) return;
    setState(() {
      _sessionModel = override.model;
      _sessionProvider = override.provider;
      _sessionReasoningEffort = override.reasoningEffort;
      _sessionModelOverride = true;
    });
  }

  Future<void> _loadVerboseMode() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _verboseMode = prefs.getBool('verbose_mode') ?? false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _savedPositions[widget.session.id] = _lastPixels;
    _savedGatewayNotices[_gatewayNoticeIdentity] = List.unmodifiable(
      _gatewayNotices,
    );
    _speechToText.cancel();
    _flutterTts.stop();
    for (final timer in _notificationTimers.values) {
      timer.cancel();
    }
    _client.close();
    _desktopGateway?.setAsyncEventListener(null);
    _desktopGateway?.close();
    _textController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _desktopGateway != null) {
      unawaited(_ensureDesktopSession());
    }
  }

  Future<void> _ensureDesktopSession() async {
    final gateway = _desktopGateway;
    if (gateway == null) return;
    try {
      await gateway.ensureSession(widget.session.id);
    } catch (_) {
      // The composer remains available. The next send retries with a fresh
      // single-use ticket and surfaces an actionable error if it still fails.
    }
  }

  void _editAndResend(String text) {
    _textController
      ..text = text
      ..selection = TextSelection.collapsed(offset: text.length);
    FocusScope.of(context).nextFocus();
  }

  Future<void> _retryPrompt(String text) async {
    if (_sending || _streaming || text.trim().isEmpty) return;
    _editAndResend(text);
    await _sendMessage();
  }

  Future<void> _exportConversation() async {
    final buffer = StringBuffer('# ${widget.session.title}\n\n');
    for (final message in _messages) {
      final role = message['role']?.toString();
      if (role != 'user' && role != 'assistant') continue;
      final content = stripToolResultText(
        messageContentToText(message['content']),
      ).trim();
      if (content.isEmpty) continue;
      buffer
        ..writeln(role == 'user' ? '## You' : '## Hermes')
        ..writeln()
        ..writeln(content)
        ..writeln();
    }
    await SharePlus.instance.share(
      ShareParams(
        subject: widget.session.title,
        text: buffer.toString().trim(),
      ),
    );
  }

  Future<void> _initVoice({bool requestSpeechPermission = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final voiceName = prefs.getString('voice_name');
      final voiceLocale = prefs.getString('voice_locale');

      if (voiceName != null && voiceName.isNotEmpty) {
        if (voiceName == voiceLocale) {
          await _flutterTts.setLanguage(voiceName);
        } else {
          await _flutterTts.setVoice({
            'name': voiceName,
            'locale': voiceLocale ?? '',
          });
        }
        _sttLocaleId = voiceLocale?.replaceAll('-', '_');
      } else {
        _sttLocaleId = null;
      }
      await _flutterTts.setSpeechRate(0.48);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);

      if (!requestSpeechPermission && !await _speechToText.hasPermission) {
        if (!mounted) return;
        setState(() {
          _speechAvailable = false;
          _voiceStatus = null;
        });
        return;
      }

      final available = await _speechToText.initialize(
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
      );
      if (!mounted) return;
      setState(() {
        _speechAvailable = available;
        _voiceStatus = available ? null : 'Speech recognition is unavailable';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _speechAvailable = false;
        _voiceStatus = 'Voice setup failed: $e';
      });
    }
  }

  void _handleSpeechStatus(String status) {
    if (!mounted) return;
    final listening = status == 'listening';
    setState(() {
      _listening = listening;
      if (!listening && status == 'done') {
        _voiceStatus = null;
      }
    });
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    if (!mounted) return;
    setState(() {
      _listening = false;
      _voiceStatus = error.errorMsg;
    });
  }

  Future<void> _toggleVoiceInput() async {
    if (_streaming || _sending || _loading) return;
    if (_listening) {
      await _speechToText.stop();
      if (!mounted) return;
      setState(() => _listening = false);
      return;
    }

    if (!_speechAvailable) {
      await _initVoice(requestSpeechPermission: true);
      if (!_speechAvailable) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _voiceStatus ?? 'Speech recognition is unavailable',
              ),
            ),
          );
        }
        return;
      }
    }

    await _flutterTts.stop();
    if (!mounted) return;
    setState(() => _voiceStatus = 'Listening…');
    await _speechToText.listen(
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        localeId: _sttLocaleId,
      ),
      onResult: _handleSpeechResult,
    );
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    final recognised = result.recognizedWords.trim();
    if (recognised.isEmpty || !mounted) return;
    setState(() {
      _textController.text = recognised;
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    });
    if (result.finalResult) {
      _sendMessage(speakResponse: true);
    }
  }

  Future<void> _speakAssistantText(String text) async {
    if (!_voiceReplyEnabled) return;
    await _readAssistantText(text);
  }

  Future<void> _readAssistantText(String text, {bool announce = false}) async {
    final spokenText = text.trim();
    if (spokenText.isEmpty) return;
    if (announce && mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Reading response aloud'),
            duration: Duration(seconds: 2),
          ),
        );
    }
    try {
      await _flutterTts.stop();
      await _flutterTts.speak(spokenText);
    } catch (_) {
      if (!announce || !mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Read aloud is unavailable on this device'),
            duration: Duration(seconds: 3),
          ),
        );
    }
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      _lastPixels = _scrollController.position.pixels;
    }
    final atBottom =
        _scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200;
    if (atBottom != !_showScrollToBottom && _streaming) {
      setState(() => _showScrollToBottom = !atBottom);
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _fetchMessages() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final messages = await _client.getMessages(widget.session.id);
      if (!mounted) return;
      _extractToolMessages(messages);
      setState(() {
        _messages = messages;
        _loading = false;
      });
      final saved = _savedPositions[widget.session.id];
      if (saved != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              saved.clamp(0.0, _scrollController.position.maxScrollExtent),
            );
          }
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      final errStr = e.toString();
      if (errStr.contains('404') || errStr.contains('not found')) {
        setState(() {
          _messages = [];
          _loading = false;
        });
        return;
      }
      setState(() {
        _error = errStr;
        _loading = false;
      });
    }
  }

  void _extractToolMessages(List<Map<String, dynamic>> messages) {
    _toolActivities.clear();
    for (final msg in messages) {
      if (!isToolResultMessage(msg)) continue;

      final name =
          (msg['name'] as String?) ??
          (msg['tool_name'] as String?) ??
          (msg['toolCallName'] as String?) ??
          '';
      final toolCallId = (msg['tool_call_id'] as String?) ?? '';
      final content = messageContentToText(msg['content']);

      String toolName = name.isNotEmpty ? name : '';
      if (toolName.isEmpty && content.isNotEmpty) {
        final match = RegExp(r'source="([^"]+)"').firstMatch(content);
        if (match != null) toolName = match.group(1)!;
      }
      if (toolName.isEmpty) toolName = 'tool';

      _toolActivities.add(
        GatewayToolActivity(
          toolId: toolCallId.isEmpty ? null : toolCallId,
          name: toolName,
          phase: GatewayToolActivityPhase.completed,
        ),
      );
    }
  }

  Future<void> _showAttachmentPicker() async {
    if (_loading || _streaming || _sending) return;

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose image'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Choose file'),
              subtitle: const Text(
                'Documents, archives, audio, video, or data',
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final image = await _imagePicker.pickImage(
        source: source,
        imageQuality: 75,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (image == null) return;

      await _preparePickedImage(image);
    } catch (_) {
      _showAttachmentError('Unable to prepare this image. Try another one.');
    }
  }

  Future<void> _recoverLostImage() async {
    final response = await _imagePicker.retrieveLostData();
    if (response.isEmpty) return;

    final files = response.files;
    if (files == null || files.isEmpty) {
      _showAttachmentError('Image selection was interrupted. Try again.');
      return;
    }

    await _preparePickedImage(files.first);
  }

  Future<void> _preparePickedImage(XFile image) async {
    try {
      final mimeType = _imageMimeType(image.path, image.mimeType);
      if (mimeType == null) {
        _showAttachmentError('Choose a JPEG, PNG, or WEBP image.');
        return;
      }

      final bytes = await image.readAsBytes();
      if (bytes.length > _maxInlineImageBytes) {
        _showAttachmentError(
          'Image is too large after compression. Choose a smaller image.',
        );
        return;
      }
      if (!mounted) return;

      setState(() {
        _pendingImage = _PendingImage(
          bytes: bytes,
          dataUrl: 'data:$mimeType;base64,${base64Encode(bytes)}',
          name: image.name,
        );
      });
    } catch (_) {
      _showAttachmentError('Unable to prepare this image. Try another one.');
    }
  }

  Future<void> _pickFile() async {
    if (_desktopGateway == null) {
      _showAttachmentError(
        'Configure a valid Desktop Gateway URL before attaching files.',
      );
      return;
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: true,
      );
      final files = result?.files ?? const [];
      if (files.isEmpty) return;
      final available = _maxRemoteAttachments - _pendingFiles.length;
      if (available <= 0) {
        _showAttachmentError(
          'You can attach up to $_maxRemoteAttachments files.',
        );
        return;
      }
      final prepared = <_PendingFile>[];
      var rejected = 0;
      for (final file in files.take(available)) {
        final bytes = file.bytes;
        if (bytes == null ||
            bytes.isEmpty ||
            bytes.length > _maxRemoteFileBytes ||
            _isSensitiveFileName(file.name)) {
          rejected++;
          continue;
        }
        prepared.add(
          _PendingFile(
            bytes: bytes,
            dataUrl:
                'data:application/octet-stream;base64,${base64Encode(bytes)}',
            name: file.name,
          ),
        );
      }
      if (!mounted) return;
      setState(() => _pendingFiles.addAll(prepared));
      if (files.length > available || rejected > 0) {
        _showAttachmentError(
          '${files.length - prepared.length} file(s) skipped: limit, size, unreadable, or sensitive filename.',
        );
      }
    } catch (_) {
      _showAttachmentError('Unable to prepare this file. Try another one.');
    }
  }

  bool _isSensitiveFileName(String fileName) {
    final lower = fileName.trim().toLowerCase();
    if (lower.isEmpty) return true;
    if (lower == '.env' ||
        (lower.startsWith('.env.') &&
            !const {
              'dist',
              'example',
              'sample',
              'template',
            }.contains(lower.substring('.env.'.length)))) {
      return true;
    }
    if (lower == '.npmrc' || lower == '.netrc' || lower == '.pypirc') {
      return true;
    }
    if (lower.endsWith('.kdbx') ||
        lower.endsWith('.p12') ||
        lower.endsWith('.pem') ||
        lower.endsWith('.pfx')) {
      return true;
    }
    return RegExp(r'^id_(rsa|dsa|ecdsa|ed25519)(?:\..+)?$').hasMatch(lower);
  }

  void _showAttachmentError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.orange),
    );
  }

  String? _imageMimeType(String path, String? declaredMimeType) {
    if (declaredMimeType == 'image/jpeg' ||
        declaredMimeType == 'image/png' ||
        declaredMimeType == 'image/webp') {
      return declaredMimeType;
    }

    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.jpg') || lowerPath.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lowerPath.endsWith('.png')) return 'image/png';
    if (lowerPath.endsWith('.webp')) return 'image/webp';
    return null;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  Future<void> _showModelSelector() async {
    final desktopGateway = _desktopGateway;
    if (desktopGateway == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Configure Desktop Gateway URL and Dashboard credentials to choose a chat model.',
          ),
        ),
      );
      return;
    }

    setState(() => _loadingModelOptions = true);
    try {
      final results = await Future.wait([
        desktopGateway.getModelInfo(),
        desktopGateway.getModelOptions(),
      ]);
      if (!mounted) return;
      final modelInfo = results[0];
      final choices = _parseModelChoices(results[1]);
      if (choices.isEmpty) {
        throw StateError(
          'The active profile did not return any selectable models.',
        );
      }

      var currentEffort =
          _sessionReasoningEffort ??
          WsClient.normalizeReasoningEffort(modelInfo['reasoning_effort']);
      try {
        currentEffort = await desktopGateway.getSessionReasoning(
          widget.session.id,
        );
      } catch (_) {
        // Older gateways may not expose session-scoped config.get. The model
        // selector remains usable with the profile/default effort.
      }
      if (!mounted) return;

      var selectedChoice = choices.firstWhere(
        (choice) =>
            choice.model == (_sessionModel ?? widget.session.model) &&
            (_sessionProvider == null || choice.provider == _sessionProvider),
        orElse: () => choices.first,
      );
      var selectedEffort = currentEffort;
      final selection = await showModalBottomSheet<_ModelSelection>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) => SafeArea(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 640),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: const Text('Model and thinking for this chat'),
                    subtitle: Text(
                      'Profile default: ${modelInfo['model'] ?? 'unknown'}'
                      '${modelInfo['provider'] == null ? '' : ' • ${modelInfo['provider']}'}',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Thinking effort',
                        border: OutlineInputBorder(),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: selectedEffort,
                          items: _reasoningEffortLabels.entries
                              .map(
                                (entry) => DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(entry.value),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (value) {
                            if (value == null) return;
                            setSheetState(() => selectedEffort = value);
                          },
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: choices.length,
                      itemBuilder: (context, index) {
                        final choice = choices[index];
                        final selected =
                            choice.model == selectedChoice.model &&
                            choice.provider == selectedChoice.provider;
                        return ListTile(
                          leading: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.smart_toy_outlined,
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          title: Text(choice.model),
                          subtitle: Text(choice.provider),
                          onTap: () =>
                              setSheetState(() => selectedChoice = choice),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.pop(
                            sheetContext,
                            _ModelSelection(
                              choice: selectedChoice,
                              reasoningEffort: selectedEffort,
                            ),
                          ),
                          child: const Text('Apply to this chat'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      if (selection != null && mounted) {
        await _setSessionModel(selection);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load models for this profile: $error'),
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingModelOptions = false);
    }
  }

  List<_ModelChoice> _parseModelChoices(Map<String, dynamic> options) {
    final providers = options['providers'];
    if (providers is! List) return const [];
    final choices = <_ModelChoice>[];
    for (final rawProvider in providers) {
      if (rawProvider is! Map) continue;
      final provider =
          (rawProvider['slug'] ?? rawProvider['id'])?.toString().trim() ?? '';
      final models = rawProvider['models'];
      if (provider.isEmpty || models is! List) continue;
      for (final rawModel in models) {
        final model = rawModel is String
            ? rawModel.trim()
            : rawModel is Map
            ? (rawModel['id'] ?? rawModel['model'] ?? rawModel['name'])
                      ?.toString()
                      .trim() ??
                  ''
            : '';
        if (model.isNotEmpty) {
          choices.add(_ModelChoice(provider: provider, model: model));
        }
      }
    }
    return choices;
  }

  Future<void> _setSessionModel(_ModelSelection selection) async {
    final desktopGateway = _desktopGateway;
    if (desktopGateway == null || _changingModel) return;
    final choice = selection.choice;
    setState(() => _changingModel = true);
    try {
      await desktopGateway.setSessionModel(
        sessionId: widget.session.id,
        provider: choice.provider,
        model: choice.model,
      );
      await desktopGateway.setSessionReasoning(
        sessionId: widget.session.id,
        effort: selection.reasoningEffort,
      );
      final store = await _chatModelStore;
      await store.save(
        connectionIdentity: _chatModelConnectionIdentity,
        sessionId: widget.session.id,
        provider: choice.provider,
        model: choice.model,
        reasoningEffort: selection.reasoningEffort,
      );
      if (!mounted) return;
      setState(() {
        _sessionModel = choice.model;
        _sessionProvider = choice.provider;
        _sessionReasoningEffort = selection.reasoningEffort;
        _sessionModelOverride = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${choice.model} • ${_reasoningEffortLabels[selection.reasoningEffort]} '
            'now apply only to this chat.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Model was not changed: $error')));
    } finally {
      if (mounted) setState(() => _changingModel = false);
    }
  }

  /// Send message via SSE streaming (Gateway API Server).
  Future<void> _sendMessage({bool speakResponse = false}) async {
    final text = _textController.text.trim();
    final pendingImage = _pendingImage;
    if (text.isEmpty && pendingImage == null && _pendingFiles.isEmpty) return;
    if (_sending || _streaming) return;
    await _sessionModelRestore;
    if (!mounted) return;

    // A remote-gateway profile uses one transport for every prompt. Images and
    // arbitrary files are both attached with the official `file.attach` RPC.
    if (_desktopGateway != null) {
      final attachments = List<_PendingFile>.from(_pendingFiles);
      if (pendingImage != null) {
        attachments.insert(
          0,
          _PendingFile(
            bytes: pendingImage.bytes,
            dataUrl: pendingImage.dataUrl,
            name: pendingImage.name,
            isImage: true,
          ),
        );
      }
      await _sendDesktopGatewayMessage(
        text: text,
        pendingFiles: attachments,
        speakResponse: speakResponse,
      );
      return;
    }

    final localContent = pendingImage == null
        ? text
        : <Map<String, dynamic>>[
            if (text.isNotEmpty) {'type': 'text', 'text': text},
            {
              'type': 'image_url',
              'image_url': {'url': pendingImage.dataUrl},
            },
          ];

    _textController.text = '';
    _awaitingVoiceReply = speakResponse && _voiceReplyEnabled;
    final responseGeneration = ++_responseGeneration;
    _activeResponseTransport = _ResponseTransport.rest;

    // Build conversation history for SSE request
    final history = <Map<String, dynamic>>[];
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      history.add({'role': m['role'] ?? 'user', 'content': m['content'] ?? ''});
    }

    setState(() {
      _sending = true;
      _streaming = true;
      _gatewayTurnStatus = const GatewayTurnStatus(
        kind: 'starting',
        text: 'Starting Hermes…',
      );
      _showScrollToBottom = false;
      _pendingImage = null;
      _messages.add({'role': 'user', 'content': localContent});
      // Insert a placeholder streaming message
      _messages.add({'role': 'assistant', 'content': ''});
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    // Accumulate tokens into the streaming placeholder
    await _gateway.sendMessageStreaming(
      message: text,
      sessionId: widget.session.id,
      history: history,
      imageDataUrl: pendingImage?.dataUrl,
      onToken: (token) {
        if (!mounted || responseGeneration != _responseGeneration) return;
        setState(() {
          if (_messages.isNotEmpty && _messages.last['role'] == 'assistant') {
            _messages.last['content'] =
                (_messages.last['content'] as String) + token;
          }
        });
      },
      onToolProgress: (progress) {
        if (!mounted || responseGeneration != _responseGeneration) return;
        _upsertToolProgress(progress);
      },
      onDone: () async {
        if (!mounted || responseGeneration != _responseGeneration) return;
        // Refresh messages to get the final server-side state
        try {
          final messages = await _client.getMessages(widget.session.id);
          if (!mounted || responseGeneration != _responseGeneration) return;
          _extractToolMessages(messages);
          setState(() {
            _messages = messages;
            _streaming = false;
            _sending = false;
            _gatewayTurnStatus = null;
            _activeResponseTransport = _ResponseTransport.none;
            _showScrollToBottom = false;
          });
          if (_awaitingVoiceReply) {
            _awaitingVoiceReply = false;
            final assistant = messages.reversed.firstWhere(
              (message) => message['role'] == 'assistant',
              orElse: () => const <String, dynamic>{},
            );
            final assistantText = assistant['content']?.toString();
            if (assistantText != null) {
              await _speakAssistantText(assistantText);
            }
          }
          final saved = _savedPositions[widget.session.id];
          if (saved != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollController.hasClients) {
                _scrollController.jumpTo(
                  saved.clamp(0.0, _scrollController.position.maxScrollExtent),
                );
              }
            });
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollController.hasClients) {
                _scrollController.jumpTo(
                  _scrollController.position.maxScrollExtent,
                );
              }
            });
          }
        } catch (e) {
          if (!mounted || responseGeneration != _responseGeneration) return;
          setState(() {
            _streaming = false;
            _sending = false;
            _gatewayTurnStatus = null;
            _activeResponseTransport = _ResponseTransport.none;
          });
        }
      },
      onError: (error) {
        if (!mounted || responseGeneration != _responseGeneration) return;
        // Remove the placeholder assistant message
        setState(() {
          if (_messages.isNotEmpty && _messages.last['role'] == 'assistant') {
            _messages.removeLast();
          }
        });
        _handleSendError(error, removePendingUserMessage: true);
      },
    );
  }

  Future<void> _sendDesktopGatewayMessage({
    required String text,
    required List<_PendingFile> pendingFiles,
    required bool speakResponse,
  }) async {
    final desktopGateway = _desktopGateway;
    if (desktopGateway == null) {
      _showAttachmentError(
        'Desktop Gateway is not configured for this connection.',
      );
      return;
    }

    _awaitingVoiceReply = speakResponse && _voiceReplyEnabled;
    final responseGeneration = ++_responseGeneration;
    _activeResponseTransport = _ResponseTransport.desktop;
    var turnAdded = false;

    setState(() {
      _sending = true;
      _gatewayTurnStatus = const GatewayTurnStatus(
        kind: 'upload',
        text: 'Preparing attachments…',
      );
      _showScrollToBottom = false;
    });

    try {
      await _applySessionModelOverride(desktopGateway);
      if (!mounted || responseGeneration != _responseGeneration) return;
      for (var index = 0; index < pendingFiles.length; index++) {
        final pendingFile = pendingFiles[index];
        if (pendingFile.refText?.isNotEmpty == true) continue;
        setState(() {
          pendingFile.status = _AttachmentStatus.uploading;
          pendingFile.error = null;
          _gatewayTurnStatus = GatewayTurnStatus(
            kind: 'upload',
            text:
                'Uploading ${index + 1}/${pendingFiles.length}: ${pendingFile.name}',
          );
        });
        try {
          final attachment = await desktopGateway.attachFile(
            sessionId: widget.session.id,
            name: pendingFile.name,
            dataUrl: pendingFile.dataUrl,
          );
          if (!mounted || responseGeneration != _responseGeneration) return;
          setState(() {
            pendingFile.refText = attachment.refText;
            pendingFile.status = _AttachmentStatus.attached;
          });
        } catch (error) {
          if (!mounted || responseGeneration != _responseGeneration) return;
          setState(() {
            pendingFile.status = _AttachmentStatus.failed;
            pendingFile.error = error.toString();
          });
          rethrow;
        }
      }
      final refs = pendingFiles
          .map((attachment) => attachment.refText)
          .whereType<String>()
          .where((ref) => ref.isNotEmpty)
          .join('\n');
      final prompt = [
        text,
        refs,
      ].where((part) => part.trim().isNotEmpty).join('\n\n');
      final attachmentLabels = pendingFiles
          .map((attachment) => '[Attached file: ${attachment.name}]')
          .join('\n');
      final localContent = [
        text,
        attachmentLabels,
      ].where((part) => part.trim().isNotEmpty).join('\n\n');
      _textController.clear();
      setState(() {
        _streaming = true;
        _gatewayTurnStatus = const GatewayTurnStatus(
          kind: 'starting',
          text: 'Starting Hermes…',
        );
        _pendingImage = null;
        _pendingFiles.clear();
        _messages.add({'role': 'user', 'content': localContent});
        _messages.add({'role': 'assistant', 'content': ''});
        turnAdded = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      await desktopGateway.submitPrompt(
        sessionId: widget.session.id,
        text: prompt,
        onEvent: (event) =>
            _handleDesktopGatewayEvent(event, responseGeneration),
      );
      if (!mounted || responseGeneration != _responseGeneration) return;
      setState(() {
        _streaming = false;
        _sending = false;
        _gatewayTurnStatus = null;
        _activeResponseTransport = _ResponseTransport.none;
        _showScrollToBottom = false;
      });
      if (_awaitingVoiceReply) {
        _awaitingVoiceReply = false;
        final assistantText = _messages.isNotEmpty
            ? _messages.last['content']?.toString()
            : null;
        if (assistantText != null && assistantText.isNotEmpty) {
          await _speakAssistantText(assistantText);
        }
      }
    } catch (error) {
      if (!mounted || responseGeneration != _responseGeneration) return;
      if (turnAdded) {
        setState(() {
          if (_messages.isNotEmpty &&
              _messages.last['role'] == 'assistant' &&
              (_messages.last['content']?.toString().isEmpty ?? true)) {
            _messages.removeLast();
          }
          if (_messages.isNotEmpty && _messages.last['role'] == 'user') {
            _messages.removeLast();
          }
          _textController.text = text;
          _pendingImage = null;
          _pendingFiles
            ..clear()
            ..addAll(pendingFiles);
        });
      }
      _handleSendError(error);
    }
  }

  void _handleDesktopGatewayEvent(StreamEvent event, int responseGeneration) {
    if (!mounted || responseGeneration != _responseGeneration) return;
    final reasoning = GatewayReasoningUpdate.fromGatewayEvent(
      event.type,
      event.data,
    );
    if (reasoning != null) {
      setState(() {
        _gatewayTurnStatus = null;
        final assistant = _lastAssistantMessage();
        if (assistant == null) return;
        final current = assistant['_gateway_reasoning']?.toString() ?? '';
        assistant['_gateway_reasoning'] = reasoning.applyTo(current);
        assistant['_gateway_reasoning_verbose'] = reasoning.verbose;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      return;
    }
    final turnStatus = GatewayTurnStatus.fromGatewayEvent(
      event.type,
      event.data,
    );
    if (turnStatus != null) {
      setState(() => _gatewayTurnStatus = turnStatus);
      return;
    }
    if (event.type == 'approval.request') {
      _showGatewayApproval(event.data, responseGeneration);
      return;
    }
    if (event.type == 'clarify.request') {
      _queueClarifyPrompt(event.data, responseGeneration);
      return;
    }
    if (event.type == 'sudo.request' || event.type == 'secret.request') {
      _queueSensitivePrompt(event, responseGeneration);
      return;
    }
    if (event.type == 'sudo.expire' || event.type == 'secret.expire') {
      _expireSensitivePrompt(event);
      return;
    }
    if (event.type == 'message.delta') {
      final token = event.data['text']?.toString() ?? '';
      if (token.isEmpty) return;
      setState(() {
        _gatewayTurnStatus = null;
        final assistant = _lastAssistantMessage();
        if (assistant == null) return;
        assistant['content'] = '${assistant['content'] ?? ''}$token';
      });
      return;
    }
    if (event.type == 'message.interim') {
      final interim = event.data['text']?.toString() ?? '';
      setState(() {
        _gatewayTurnStatus = null;
        final assistant = _lastAssistantMessage();
        if (assistant == null) return;
        final transition = GatewayInterimTransition.resolve(
          currentText: assistant['content']?.toString() ?? '',
          interimText: interim,
          alreadyStreamed: event.data['already_streamed'] == true,
        );
        assistant['content'] = transition.sealedText;
        if (transition.startsNewMessage) {
          assistant['_gateway_interim'] = true;
          _messages.add({'role': 'assistant', 'content': ''});
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      return;
    }
    if (event.type == 'message.complete') {
      final completeText =
          event.data['rendered']?.toString() ??
          event.data['text']?.toString() ??
          '';
      if (completeText.isNotEmpty) {
        setState(() {
          final assistant = _lastAssistantMessage();
          if (assistant != null) assistant['content'] = completeText;
        });
      }
      return;
    }
    if (event.type.startsWith('tool.')) {
      _upsertToolProgress(event.data, eventType: event.type);
      return;
    }
    if (event.type.startsWith('subagent.')) {
      _upsertSubagent(event.type, event.data);
    }
  }

  Map<String, dynamic>? _lastAssistantMessage() {
    for (var index = _messages.length - 1; index >= 0; index--) {
      if (_messages[index]['role'] == 'assistant') return _messages[index];
    }
    return null;
  }

  void _handleDesktopAsyncEvent(String mobileSessionId, StreamEvent event) {
    if (!mounted || mobileSessionId != widget.session.id) return;
    if (event.type == 'notification.show') {
      final notification = GatewayNotification.fromEventData(event.data);
      if (notification == null) return;
      _notificationTimers.remove(notification.key)?.cancel();
      setState(() => _gatewayNotifications[notification.key] = notification);
      if (notification.ttl case final ttl?) {
        _notificationTimers[notification.key] = Timer(ttl, () {
          if (!mounted) return;
          setState(() => _gatewayNotifications.remove(notification.key));
          _notificationTimers.remove(notification.key);
        });
      }
      return;
    }
    if (event.type == 'notification.clear') {
      final key = event.data['key']?.toString().trim();
      setState(() {
        if (key == null || key.isEmpty) {
          _gatewayNotifications.clear();
          for (final timer in _notificationTimers.values) {
            timer.cancel();
          }
          _notificationTimers.clear();
        } else {
          _gatewayNotifications.remove(key);
          _notificationTimers.remove(key)?.cancel();
        }
      });
      return;
    }
    if (event.type.startsWith('subagent.')) {
      _upsertSubagent(event.type, event.data);
      return;
    }
    final notice = GatewayNotice.fromGatewayEvent(event.type, event.data);
    if (notice == null) return;
    if (_gatewayNotices.any((item) => item.identity == notice.identity)) return;
    setState(() {
      _gatewayNotices.add(notice);
      if (_gatewayNotices.length > 20) _gatewayNotices.removeAt(0);
      _savedGatewayNotices[_gatewayNoticeIdentity] = List.unmodifiable(
        _gatewayNotices,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _upsertSubagent(String eventType, Map<String, dynamic> data) {
    final update = GatewaySubagentActivity.fromGatewayEvent(eventType, data);
    if (update == null || !mounted) return;
    setState(() {
      final index = _subagentActivities.indexWhere(
        (activity) => activity.id == update.id,
      );
      if (index < 0) {
        _subagentActivities.add(update);
      } else {
        _subagentActivities[index] = _subagentActivities[index].merge(update);
      }
      if (!update.isComplete) {
        _gatewayTurnStatus = GatewayTurnStatus(
          kind: 'subagent',
          text: 'Delegated task: ${update.goal}',
        );
      }
    });
  }

  void _showGatewayApproval(
    Map<String, dynamic> eventData,
    int responseGeneration,
  ) {
    if (_approvalDialogOpen) return;
    final request = GatewayApprovalRequest.fromEventData(eventData);
    _approvalDialogOpen = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || responseGeneration != _responseGeneration) {
        _approvalDialogOpen = false;
        return;
      }
      final desktopGateway = _desktopGateway;
      if (desktopGateway == null) {
        _approvalDialogOpen = false;
        return;
      }

      final responded = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => GatewayApprovalDialog(
          request: request,
          onRespond: (choice) => desktopGateway.respondToApproval(
            sessionId: widget.session.id,
            choice: choice.wireValue,
          ),
        ),
      );
      _approvalDialogOpen = false;
      _drainClarifyPromptQueue();
      _drainSensitivePromptQueue();

      // System Back is treated as a denial. This prevents a dismissed mobile
      // dialog from leaving the gateway turn blocked indefinitely.
      if (responded != true &&
          mounted &&
          responseGeneration == _responseGeneration) {
        try {
          await desktopGateway.respondToApproval(
            sessionId: widget.session.id,
            choice: GatewayApprovalChoice.deny.wireValue,
          );
        } catch (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not deny the command: $error'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    });
  }

  void _queueSensitivePrompt(StreamEvent event, int responseGeneration) {
    final kind = event.type == 'sudo.request'
        ? GatewaySensitivePromptKind.sudo
        : GatewaySensitivePromptKind.secret;
    final request = GatewaySensitivePromptRequest.fromEventData(
      kind: kind,
      data: event.data,
    );
    if (request == null) return;
    final duplicate =
        _expiredSensitivePromptIds.contains(request.requestId) ||
        _activeSensitivePrompt?.request.requestId == request.requestId ||
        _sensitivePromptQueue.any(
          (pending) => pending.request.requestId == request.requestId,
        );
    if (duplicate) return;
    _sensitivePromptQueue.add(
      _PendingSensitivePrompt(request, responseGeneration),
    );
    _drainSensitivePromptQueue();
  }

  void _drainSensitivePromptQueue() {
    if (!mounted ||
        _approvalDialogOpen ||
        _activeClarifyPrompt != null ||
        _activeSensitivePrompt != null ||
        _sensitivePromptQueue.isEmpty) {
      return;
    }
    final pending = _sensitivePromptQueue.removeAt(0);
    _activeSensitivePrompt = pending;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          pending.responseGeneration != _responseGeneration ||
          _expiredSensitivePromptIds.contains(pending.request.requestId) ||
          _activeSensitivePrompt?.request.requestId !=
              pending.request.requestId) {
        _expiredSensitivePromptIds.remove(pending.request.requestId);
        _activeSensitivePrompt = null;
        _drainSensitivePromptQueue();
        return;
      }
      final desktopGateway = _desktopGateway;
      if (desktopGateway == null) {
        _activeSensitivePrompt = null;
        _drainSensitivePromptQueue();
        return;
      }

      _sensitivePromptRouteOpen = true;
      final result = await showDialog<GatewaySensitivePromptDialogResult>(
        context: context,
        barrierDismissible: true,
        builder: (_) => GatewaySensitivePromptDialog(
          request: pending.request,
          onRespond: (value) => switch (pending.request.kind) {
            GatewaySensitivePromptKind.sudo => desktopGateway.respondToSudo(
              requestId: pending.request.requestId,
              password: value,
            ),
            GatewaySensitivePromptKind.secret => desktopGateway.respondToSecret(
              requestId: pending.request.requestId,
              value: value,
            ),
          },
        ),
      );
      _sensitivePromptRouteOpen = false;
      _expiredSensitivePromptIds.remove(pending.request.requestId);

      if (_activeSensitivePrompt?.request.requestId ==
          pending.request.requestId) {
        _activeSensitivePrompt = null;
      }
      if (result == null &&
          mounted &&
          pending.responseGeneration == _responseGeneration) {
        try {
          switch (pending.request.kind) {
            case GatewaySensitivePromptKind.sudo:
              await desktopGateway.respondToSudo(
                requestId: pending.request.requestId,
                password: '',
              );
              break;
            case GatewaySensitivePromptKind.secret:
              await desktopGateway.respondToSecret(
                requestId: pending.request.requestId,
                value: '',
              );
              break;
          }
        } catch (_) {
          // The request may have expired while the route was closing. Never
          // include a sensitive value in an error message or diagnostic.
        }
      }
      _drainClarifyPromptQueue();
      _drainSensitivePromptQueue();
    });
  }

  void _expireSensitivePrompt(StreamEvent event) {
    final requestId = event.data['request_id']?.toString().trim() ?? '';
    if (requestId.isEmpty) return;
    _expiredSensitivePromptIds.add(requestId);
    _sensitivePromptQueue.removeWhere(
      (pending) => pending.request.requestId == requestId,
    );
    if (_activeSensitivePrompt?.request.requestId == requestId &&
        _sensitivePromptRouteOpen) {
      Navigator.of(
        context,
        rootNavigator: true,
      ).pop(GatewaySensitivePromptDialogResult.expired);
    } else if (_activeSensitivePrompt?.request.requestId != requestId) {
      _expiredSensitivePromptIds.remove(requestId);
    }
  }

  void _queueClarifyPrompt(
    Map<String, dynamic> eventData,
    int responseGeneration,
  ) {
    final request = GatewayClarifyRequest.fromEventData(eventData);
    if (request == null) return;
    final duplicate =
        _activeClarifyPrompt?.request.requestId == request.requestId ||
        _clarifyPromptQueue.any(
          (pending) => pending.request.requestId == request.requestId,
        );
    if (duplicate) return;

    _clarifyPromptQueue.add(_PendingClarifyPrompt(request, responseGeneration));
    _drainClarifyPromptQueue();
  }

  void _drainClarifyPromptQueue() {
    if (!mounted ||
        _approvalDialogOpen ||
        _activeSensitivePrompt != null ||
        _activeClarifyPrompt != null ||
        _clarifyPromptQueue.isEmpty) {
      return;
    }
    final pending = _clarifyPromptQueue.removeAt(0);
    _activeClarifyPrompt = pending;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          pending.responseGeneration != _responseGeneration ||
          _activeClarifyPrompt?.request.requestId !=
              pending.request.requestId) {
        _activeClarifyPrompt = null;
        _drainSensitivePromptQueue();
        _drainClarifyPromptQueue();
        return;
      }
      final desktopGateway = _desktopGateway;
      if (desktopGateway == null) {
        _activeClarifyPrompt = null;
        _drainSensitivePromptQueue();
        _drainClarifyPromptQueue();
        return;
      }

      final responded = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (_) => GatewayClarifyDialog(
          request: pending.request,
          onRespond: (answer) => desktopGateway.respondToClarify(
            requestId: pending.request.requestId,
            answer: answer,
          ),
        ),
      );
      if (_activeClarifyPrompt?.request.requestId ==
          pending.request.requestId) {
        _activeClarifyPrompt = null;
      }

      // System Back or a barrier dismiss maps to the official empty answer,
      // matching Hermes Desktop's Skip behavior.
      if (responded != true &&
          mounted &&
          pending.responseGeneration == _responseGeneration) {
        try {
          await desktopGateway.respondToClarify(
            requestId: pending.request.requestId,
            answer: '',
          );
        } catch (_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not skip the Hermes question.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
      _drainSensitivePromptQueue();
      _drainClarifyPromptQueue();
    });
  }

  Future<void> _stopResponse() async {
    if (!_streaming) return;

    final transport = _activeResponseTransport;
    ++_responseGeneration;
    setState(() {
      _streaming = false;
      _sending = false;
      _gatewayTurnStatus = null;
      _awaitingVoiceReply = false;
      _activeResponseTransport = _ResponseTransport.none;
      if (_messages.isNotEmpty &&
          _messages.last['role'] == 'assistant' &&
          (_messages.last['content']?.toString().isEmpty ?? true)) {
        _messages.removeLast();
      }
    });

    try {
      final interrupted = switch (transport) {
        _ResponseTransport.rest => await _gateway.cancelActiveMessage(),
        _ResponseTransport.desktop =>
          await _desktopGateway?.interruptPrompt(
                sessionId: widget.session.id,
              ) ??
              false,
        _ResponseTransport.none => false,
      };
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            interrupted
                ? 'Response stopped.'
                : 'Response closed locally; no active gateway turn was found.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Response closed locally; gateway stop failed: $error'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  void _handleSendError(Object e, {bool removePendingUserMessage = false}) {
    setState(() {
      _sending = false;
      _streaming = false;
      _gatewayTurnStatus = null;
      _activeResponseTransport = _ResponseTransport.none;
      _awaitingVoiceReply = false;
      if (removePendingUserMessage &&
          _messages.isNotEmpty &&
          _messages.last['role'] == 'user') {
        _messages.removeLast();
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Send failed: $e'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  void _upsertToolProgress(
    Map<String, dynamic> progress, {
    String eventType = 'tool.start',
  }) {
    final update = GatewayToolActivity.fromGatewayEvent(eventType, progress);
    if (update == null) return;
    setState(() {
      var idx = update.toolId == null
          ? -1
          : _toolActivities.indexWhere(
              (activity) => activity.toolId == update.toolId,
            );
      if (idx < 0) {
        idx = _toolActivities.lastIndexWhere(
          (activity) =>
              !activity.isTerminal &&
              activity.name.toLowerCase() == update.name.toLowerCase(),
        );
      }
      if (idx >= 0) {
        _toolActivities[idx] = _toolActivities[idx].merge(update);
      } else {
        _toolActivities.add(update);
      }
      _gatewayTurnStatus = GatewayTurnStatus(
        kind: 'tool',
        text: update.isTerminal
            ? '${update.displayName}: ${update.statusLabel.toLowerCase()}'
            : 'Using ${update.displayName}…',
      );
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _desktopGateway == null
                        ? (_loading
                              ? Colors.orange
                              : _error == null
                              ? Colors.green
                              : Theme.of(context).colorScheme.error)
                        : switch (_desktopConnectionState) {
                            DesktopConnectionState.connected => Colors.green,
                            DesktopConnectionState.connecting ||
                            DesktopConnectionState.reconnecting =>
                              Colors.orange,
                            DesktopConnectionState.disconnected => Theme.of(
                              context,
                            ).colorScheme.error,
                          },
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '${widget.connection.label} • ${_desktopGateway == null ? (_loading
                              ? 'connecting'
                              : _error == null
                              ? 'connected'
                              : 'offline') : _desktopConnectionState.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (_streaming)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Responding…', style: TextStyle(fontSize: 13)),
                ],
              ),
            )
          else
            PopupMenuButton<String>(
              tooltip: 'Chat actions',
              onSelected: (action) {
                if (action == 'refresh') _fetchMessages();
                if (action == 'export') _exportConversation();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'refresh',
                  child: ListTile(
                    leading: Icon(Icons.refresh),
                    title: Text('Refresh'),
                  ),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: ListTile(
                    leading: Icon(Icons.ios_share_outlined),
                    title: Text('Export / share'),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: Responsive.isTablet(context) ? 800 : double.infinity,
          ),
          child: Column(
            children: [
              for (final notification in _gatewayNotifications.values)
                _buildGatewayNotification(notification),
              Expanded(child: _buildBody()),
              _buildInputBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGatewayNotification(GatewayNotification notification) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (notification.level) {
      GatewayNotificationLevel.success => Colors.green,
      GatewayNotificationLevel.warning => Colors.orange,
      GatewayNotificationLevel.error => scheme.error,
      GatewayNotificationLevel.info => scheme.primary,
    };
    return MaterialBanner(
      backgroundColor: color.withValues(alpha: 0.12),
      leading: Icon(Icons.notifications_outlined, color: color),
      content: SelectionArea(child: Text(notification.text)),
      actions: [
        TextButton(
          onPressed: () {
            _notificationTimers.remove(notification.key)?.cancel();
            setState(() => _gatewayNotifications.remove(notification.key));
          },
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(blurRadius: 4, color: Colors.black.withValues(alpha: 0.1)),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_gatewayTurnStatus != null && (_sending || _streaming))
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(4, 2, 4, 2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.secondaryContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _gatewayTurnStatus!.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                child: TextButton.icon(
                  onPressed:
                      (_sending ||
                          _streaming ||
                          _loadingModelOptions ||
                          _changingModel)
                      ? null
                      : _showModelSelector,
                  icon: _loadingModelOptions || _changingModel
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.tune, size: 18),
                  label: Text(
                    '${_sessionModel ?? widget.session.model} • '
                    '${_sessionModelOverride ? 'this chat' : 'profile default'}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            if (_pendingImage != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _pendingImage!.bytes,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Image ready to send'),
                          Text(
                            _pendingImage!.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Remove image',
                      onPressed: () => setState(() => _pendingImage = null),
                    ),
                  ],
                ),
              ),
            if (_pendingFiles.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    for (final attachment in _pendingFiles)
                      ListTile(
                        dense: true,
                        leading: switch (attachment.status) {
                          _AttachmentStatus.uploading => const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          _AttachmentStatus.attached => const Icon(
                            Icons.check_circle_outline,
                            color: Colors.green,
                          ),
                          _AttachmentStatus.failed => Icon(
                            Icons.error_outline,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          _AttachmentStatus.ready => const Icon(
                            Icons.description_outlined,
                          ),
                        },
                        title: Text(
                          attachment.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          attachment.status == _AttachmentStatus.failed
                              ? 'Upload failed • tap retry'
                              : '${_formatFileSize(attachment.bytes.length)} • ${attachment.status.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: attachment.status == _AttachmentStatus.failed
                            ? IconButton(
                                icon: const Icon(Icons.refresh),
                                tooltip: 'Retry upload',
                                onPressed: _sending
                                    ? null
                                    : () => _sendMessage(),
                              )
                            : IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Remove file',
                                onPressed: _sending
                                    ? null
                                    : () => setState(
                                        () => _pendingFiles.remove(attachment),
                                      ),
                              ),
                      ),
                  ],
                ),
              ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: (!_loading && !_streaming && !_sending)
                      ? _showAttachmentPicker
                      : null,
                  tooltip: 'Attach image or file',
                ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: InputDecoration(
                      hintText: 'Type a message…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      isDense: true,
                    ),
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.send,
                    enabled: !_loading && !_streaming,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  icon: Icon(_listening ? Icons.mic_off : Icons.mic),
                  color: _listening
                      ? Theme.of(context).colorScheme.error
                      : null,
                  onPressed: (!_loading && !_streaming && !_sending)
                      ? _toggleVoiceInput
                      : null,
                  tooltip: _listening ? 'Stop listening' : 'Speak to Hermes',
                ),
                IconButton(
                  icon: Icon(
                    _voiceReplyEnabled ? Icons.volume_up : Icons.volume_off,
                  ),
                  onPressed: () {
                    setState(() => _voiceReplyEnabled = !_voiceReplyEnabled);
                    if (!_voiceReplyEnabled) {
                      _flutterTts.stop();
                    }
                  },
                  tooltip: _voiceReplyEnabled
                      ? 'Spoken replies on'
                      : 'Spoken replies off',
                ),
                const SizedBox(width: 4),
                CircleAvatar(
                  child: _streaming
                      ? IconButton(
                          icon: const Icon(Icons.stop_rounded, size: 20),
                          onPressed: _stopResponse,
                          tooltip: 'Stop response',
                        )
                      : IconButton(
                          icon: const Icon(Icons.send, size: 20),
                          onPressed: _sendMessage,
                          tooltip: 'Send',
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                'Failed to load messages',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _fetchMessages,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Build display list: consecutive tool messages grouped into cards,
    // interleaved with user/assistant bubbles.
    final toolQueue = List<GatewayToolActivity>.from(_toolActivities);
    final displayMessages = <dynamic>[];
    final currentGroup = <GatewayToolActivity>[];
    String? lastUserPrompt;

    for (final msg in _messages) {
      final role = (msg['role'] as String?) ?? 'assistant';
      if (isToolResultMessage(msg)) {
        if (toolQueue.isNotEmpty) {
          currentGroup.add(toolQueue.removeAt(0));
        }
        continue;
      }
      if (role != 'user' && role != 'assistant') continue;
      final content = stripToolResultText(messageContentToText(msg['content']));
      final reasoning = msg['_gateway_reasoning']?.toString() ?? '';
      if (content.isEmpty && reasoning.trim().isEmpty) continue;

      if (currentGroup.isNotEmpty) {
        displayMessages.add(currentGroup.toList());
        currentGroup.clear();
      }
      if (role == 'assistant' && reasoning.trim().isNotEmpty) {
        displayMessages.add(
          _GatewayReasoningDisplay(
            reasoning,
            _verboseMode || msg['_gateway_reasoning_verbose'] == true,
          ),
        );
      }
      if (content.isNotEmpty) {
        if (role == 'user') lastUserPrompt = content;
        displayMessages.add({
          ...msg,
          '_display_content': content,
          if (role == 'assistant' && lastUserPrompt != null)
            '_retry_prompt': lastUserPrompt,
        });
      }
    }
    if (currentGroup.isNotEmpty) {
      displayMessages.add(currentGroup.toList());
    }

    // Tools from SSE events that arrived during streaming but haven't been
    // matched to server messages yet — show them as a card.
    if (toolQueue.isNotEmpty) {
      displayMessages.add(toolQueue.toList());
    }
    if (_subagentActivities.isNotEmpty) {
      displayMessages.add(
        List<GatewaySubagentActivity>.from(_subagentActivities),
      );
    }
    displayMessages.addAll(_gatewayNotices);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: displayMessages.length,
      itemBuilder: (context, index) {
        final item = displayMessages[index];

        if (item is List<GatewayToolActivity>) {
          return GatewayActivityCard(activities: item, verbose: _verboseMode);
        }
        if (item is List<GatewaySubagentActivity>) {
          return GatewaySubagentCard(activities: item);
        }
        if (item is _GatewayReasoningDisplay) {
          return GatewayReasoningCard(
            text: item.text,
            initiallyExpanded: item.initiallyExpanded,
          );
        }
        if (item is GatewayNotice) {
          return GatewayNoticeCard(notice: item);
        }

        final msg = item as Map<String, dynamic>;
        final role = (msg['role'] as String?) ?? 'assistant';
        final content =
            (msg['_display_content'] as String?) ??
            stripToolResultText(messageContentToText(msg['content']));
        final isUser = role == 'user';

        return MessageBubble(
          content: content,
          isUser: isUser,
          verbose: _verboseMode,
          metadata: msg,
          onReadAloud: isUser
              ? null
              : () => _readAssistantText(content, announce: true),
          onEdit: isUser ? () => _editAndResend(content) : null,
          onRetry: isUser
              ? null
              : () => _retryPrompt(msg['_retry_prompt']?.toString() ?? ''),
        );
      },
    );
  }

  Future<void> _applySessionModelOverride(
    DesktopGatewayClient desktopGateway,
  ) async {
    final provider = _sessionProvider;
    final model = _sessionModel;
    if (!_sessionModelOverride || provider == null || model == null) return;
    await desktopGateway.setSessionModel(
      sessionId: widget.session.id,
      provider: provider,
      model: model,
    );
    final effort = _sessionReasoningEffort;
    if (effort != null) {
      await desktopGateway.setSessionReasoning(
        sessionId: widget.session.id,
        effort: effort,
      );
    }
  }
}

class MessageBubble extends StatelessWidget {
  final String content;
  final bool isUser;
  final bool verbose;
  final Map<String, dynamic> metadata;
  final Future<void> Function()? onReadAloud;
  final VoidCallback? onEdit;
  final Future<void> Function()? onRetry;

  const MessageBubble({
    super.key,
    required this.content,
    required this.isUser,
    this.verbose = false,
    this.metadata = const {},
    this.onReadAloud,
    this.onEdit,
    this.onRetry,
  });

  Future<void> _copyMessage(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Message copied'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Bubble colors
    final userBubbleColor = const Color(0xFFD4AF37);
    final assistantBubbleColor = isDark
        ? const Color(0xFF2A2A2A)
        : const Color(0xFFEAEAEA);
    final assistantTextColor = isDark ? Colors.white : Colors.black87;

    // Collect extra metadata for verbose mode
    final List<String> metaLines = [];
    if (verbose) {
      final role = (metadata['role'] as String?) ?? 'unknown';
      metaLines.add('role: $role');
      // Show any extra fields that aren't role/content
      for (final entry in metadata.entries) {
        if (entry.key == 'role' || entry.key == 'content') continue;
        final value = entry.value?.toString() ?? 'null';
        if (value.length > 80) {
          metaLines.add('${entry.key}: ${value.substring(0, 80)}…');
        } else {
          metaLines.add('${entry.key}: $value');
        }
      }
    }

    final bubble = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width - 80,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isUser ? userBubbleColor : assistantBubbleColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Verbose metadata header
          if (metaLines.isNotEmpty) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (isUser ? Colors.white : Colors.black).withValues(
                  alpha: 0.1,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: metaLines
                    .map(
                      (line) => Text(
                        line,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: isUser
                              ? Colors.white.withValues(alpha: 0.8)
                              : (isDark ? Colors.grey[400] : Colors.grey[600]),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          // Message content
          MarkdownBody(
            data: content,
            selectable: true,
            styleSheet: MarkdownStyleSheet(
              p: (isUser
                  ? theme.textTheme.bodyMedium?.copyWith(color: Colors.white)
                  : theme.textTheme.bodyMedium?.copyWith(
                      color: assistantTextColor,
                    )),
              code: TextStyle(
                backgroundColor: (isUser ? Colors.white : Colors.black)
                    .withValues(alpha: 0.12),
                fontFamily: 'monospace',
                color: isUser ? Colors.white : null,
              ),
              a: TextStyle(
                color: isUser ? Colors.white70 : theme.colorScheme.primary,
              ),
              h1: isUser
                  ? theme.textTheme.headlineSmall?.copyWith(color: Colors.white)
                  : theme.textTheme.headlineSmall,
              h2: isUser
                  ? theme.textTheme.titleLarge?.copyWith(color: Colors.white)
                  : theme.textTheme.titleLarge,
              h3: isUser
                  ? theme.textTheme.titleMedium?.copyWith(color: Colors.white)
                  : theme.textTheme.titleMedium,
              blockquote: TextStyle(
                color: isUser ? Colors.white60 : Colors.grey,
                fontStyle: FontStyle.italic,
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isUser ? Colors.white38 : theme.colorScheme.primary,
                    width: 3,
                  ),
                ),
              ),
              em: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: Colors.white,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
              strong: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 19),
                  tooltip: 'Copy message',
                  onPressed: () => _copyMessage(context),
                ),
                if (onReadAloud != null)
                  IconButton(
                    icon: const Icon(Icons.volume_up_outlined, size: 20),
                    tooltip: 'Read aloud',
                    onPressed: onReadAloud,
                  ),
                if (onEdit != null)
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: 'Edit and resend',
                    onPressed: onEdit,
                  ),
                if (onRetry != null)
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: 'Regenerate from the preceding prompt',
                    onPressed: onRetry,
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return Row(
      mainAxisAlignment: isUser
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [bubble],
    );
  }
}
