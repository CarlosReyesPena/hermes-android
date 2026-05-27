/// Chat screen with message sending via WebSocket JSON-RPC.
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
  String? _sendError;

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

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() {
      _sending = true;
      _sendError = null;
    });
    _textController.text = '';

    try {
      final ws = WsClient(widget.connection.baseUrl);
      await ws.connect();
      await ws.resumeSession(widget.session.id);
      await ws.sendMessage(text);
      ws.close();
    } catch (e) {
      setState(() {
        _sendError = e.toString();
      });
    } finally {
      setState(() { _sending = false; });
      _fetchMessages();
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
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchMessages,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(),
      bottom: _buildInputBar(),
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
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          CircleAvatar(
            child: _sending
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
    if (_sending) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Sending…', style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      );
    }

    if (_sendError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text('Send failed', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                _sendError!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _fetchMessages, child: const Text('Refresh')),
            ],
          ),
        ),
      );
    }

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

    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              'No messages yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Type a message below to start',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
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
