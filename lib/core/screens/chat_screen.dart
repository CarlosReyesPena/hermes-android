/// Chat screen with real-time streaming via WebSocket JSON-RPC.
/// Uses a persistent WS connection and polls for updated messages after send.
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../services/connection_manager.dart';
import '../services/ws_client.dart';

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

class _ChatScreenState extends State<ChatScreen> {
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  String? _error;
  ApiClient? _client;

  // Chat sending state
  final _textController = TextEditingController();
  bool _sending = false;
  bool _streaming = false; // true while assistant is responding

  @override
  void initState() {
    super.initState();
    _client = ApiClient();
    _fetchMessages();
  }

  @override
  void dispose() {
    _client?.close();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _fetchMessages() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final messages = await _client!.getMessages(
        widget.connection.baseUrl,
        widget.session.id,
      );
      setState(() {
        _messages = messages;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Poll for new messages until we see a new one (or timeout).
  Future<void> _pollForResponse() async {
    const maxPolls = 60; // up to 60 seconds of polling
    const pollInterval = const Duration(milliseconds: 1000);
    final lastCount = _messages.length;

    for (int i = 0; i < maxPolls; i++) {
      if (!mounted) return;
      await Future.delayed(pollInterval);

      try {
        final messages = await _client!.getMessages(
          widget.connection.baseUrl,
          widget.session.id,
        );

        // If we got new messages, update UI
        if (messages.length > lastCount) {
          setState(() {
            _messages = messages;
            _streaming = false;
            _sending = false;
          });
          return;
        }
      } catch (e) {
        // Continue polling on transient errors
      }
    }

    // Timeout: still update with latest state
    if (mounted) {
      try {
        final messages = await _client!.getMessages(
          widget.connection.baseUrl,
          widget.session.id,
        );
        if (messages.length > lastCount) {
          setState(() {
            _messages = messages;
            _streaming = false;
            _sending = false;
          });
        } else {
          // No new messages but response might be there
          setState(() {
            _streaming = false;
            _sending = false;
          });
        }
      } catch (_) {
        setState(() {
          _streaming = false;
          _sending = false;
        });
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending || _streaming) return;

    // Optimistic: add user message immediately
    final optimisticMsg = {'role': 'user', 'content': text};
    _textController.text = '';

    setState(() {
      _sending = true;
      _streaming = true;
    });

    try {
      final ws = WsClient(widget.connection.baseUrl);
      await ws.connect();
      await ws.resumeSession(widget.session.id);
      await ws.sendMessage(text);
      ws.close();

      // Update UI with optimistic message
      setState(() {
        _messages.insert(0, optimisticMsg);
        _sending = false;
        _loading = false;
        _error = null;
      });

      // Start polling for assistant response
      _pollForResponse();
    } catch (e) {
      setState(() {
        _sending = false;
        _streaming = false;
        // Remove optimistic message on failure
        if (_messages.isNotEmpty &&
            _messages[0]['role'] == 'user' &&
            _messages[0]['content'] == text) {
          _messages.removeAt(0);
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Send failed: $e'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
                  Text('Streaming…', style: TextStyle(fontSize: 13)),
                ],
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _fetchMessages,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          _buildInputBar(),
        ],
      ),
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
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: InputDecoration(
                hintText: 'Type a message…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                isDense: true,
              ),
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              enabled: !_loading && !_streaming,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          CircleAvatar(
            child: _streaming
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.send, size: 20),
                    onPressed: _sendMessage,
                    tooltip: 'Send',
                  ),
          ),
        ],
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

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 4),
      reverse: true,
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        final role = (msg['role'] as String?) ?? 'assistant';
        final content = (msg['content'] as String?) ?? '';
        final isUser = role == 'user';

        return _MessageBubble(content: content, isUser: isUser);
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final bool isUser;

  const _MessageBubble({required this.content, required this.isUser});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isUser) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width - 80,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(18),
          ),
          child: MarkdownBody(
            data: content,
            styleSheet: MarkdownStyleSheet(
              p: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
              code: TextStyle(
                backgroundColor: Colors.white.withValues(alpha: 0.15),
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      );
    }

    // Assistant message
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: MarkdownBody(
        data: content,
        styleSheet: MarkdownStyleSheet(
          p: theme.textTheme.bodyMedium,
          h1: theme.textTheme.headlineSmall,
          h2: theme.textTheme.titleLarge,
          h3: theme.textTheme.titleMedium,
          code: TextStyle(
            backgroundColor: Colors.white.withValues(alpha: 0.1),
            fontFamily: 'monospace',
            fontSize: 13,
          ),
          blockquote: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
          blockquoteDecoration: BoxDecoration(
            border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 3)),
          ),
          a: TextStyle(color: theme.colorScheme.primary),
          em: theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
          strong: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
