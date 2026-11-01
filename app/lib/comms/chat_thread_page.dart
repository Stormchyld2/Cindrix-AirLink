import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:localsend_app/comms/message.dart';
import 'package:localsend_app/comms/message_store.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/util/native/quick_connect.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// One contact's conversation: send a text now (it queues and sends the moment the link is up), see what's
/// pending vs delivered. Push-to-talk is not built yet (text-only for now; see ARCHITECTURE.md).
class ChatThreadPage extends StatefulWidget {
  final FavoriteDevice favorite;

  const ChatThreadPage({required this.favorite});

  @override
  State<ChatThreadPage> createState() => _ChatThreadPageState();
}

class _ChatThreadPageState extends State<ChatThreadPage> with Refena {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    CommsMessageStore.instance.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    CommsMessageStore.instance.removeListener(_onStoreChanged);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _controller.clear();

    await CommsMessageStore.instance.queueText(contactFingerprint: widget.favorite.fingerprint, text: text);

    // Try to deliver right now: if the contact is already linked (Ready mode, or we're mid-send to them),
    // this flushes instantly instead of waiting for the next time quickConnect runs. quickConnect flushes
    // the outbox itself on success; on failure the message simply stays queued for later.
    if (mounted) {
      await quickConnect(context, ref, widget.favorite);
    }

    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final messages = CommsMessageStore.instance.forContact(widget.favorite.fingerprint);

    return Scaffold(
      appBar: AppBar(title: Text(widget.favorite.alias)),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(child: Text('No messages yet. Send one — it delivers the next time you two are linked.'))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) => _Bubble(message: messages[index]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(hintText: 'Message'),
                      onSubmitted: (_) async => await _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : () async => await _send(),
                    icon: _sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final CommsMessage message;

  const _Bubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = message.outgoing;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: mine ? theme.colorScheme.primary : theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.type == CommsMessageType.text ? message.body : '🎙 Voice message',
              style: TextStyle(color: mine ? theme.colorScheme.onPrimary : theme.colorScheme.onSecondaryContainer),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat.Hm().format(message.createdAt),
                  style: TextStyle(
                    fontSize: 11,
                    color: (mine ? theme.colorScheme.onPrimary : theme.colorScheme.onSecondaryContainer).withValues(alpha: 0.7),
                  ),
                ),
                if (mine) ...[
                  const SizedBox(width: 4),
                  Icon(
                    message.status == CommsMessageStatus.delivered ? Icons.done_all : Icons.schedule,
                    size: 13,
                    color: theme.colorScheme.onPrimary.withValues(alpha: 0.85),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
