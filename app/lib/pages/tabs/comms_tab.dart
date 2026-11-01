import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:localsend_app/comms/chat_thread_page.dart';
import 'package:localsend_app/comms/comms_sync.dart';
import 'package:localsend_app/comms/message.dart';
import 'package:localsend_app/comms/message_store.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AirLink Pro's Comms: a mailbox between paired phones. Each contact is a paired favorite; messages queue
/// locally and deliver the next time the two phones are directly linked (see comms_sync.dart) — like a radio,
/// not a live chat server, so there is no "online now" to show, only what has and hasn't gone through yet.
class CommsTab extends StatefulWidget {
  const CommsTab();

  @override
  State<CommsTab> createState() => _CommsTabState();
}

class _CommsTabState extends State<CommsTab> with Refena {
  Timer? _ambientSync;

  @override
  void initState() {
    super.initState();
    CommsMessageStore.instance.addListener(_onStoreChanged);
    // ignore: discarded_futures
    CommsMessageStore.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });

    // While this tab is open, opportunistically flush any queued mail to a paired contact the moment
    // normal LAN/discovery already sees them nearby — not everything has to wait for a deliberate
    // quickConnect tap.
    _ambientSync = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_flushToNearbyContacts()));
  }

  @override
  void dispose() {
    _ambientSync?.cancel();
    CommsMessageStore.instance.removeListener(_onStoreChanged);
    super.dispose();
  }

  Future<void> _flushToNearbyContacts() async {
    final nearby = ref.read(nearbyDevicesProvider).allDevices.values;
    if (nearby.isEmpty) return;
    final favorites = ref.read(favoritesProvider);
    final myFingerprint = ref.read(deviceFullInfoProvider).fingerprint;

    for (final device in nearby) {
      final ip = device.ip;
      if (ip == null) continue;
      final isFavorite = favorites.any((f) => f.fingerprint == device.fingerprint);
      if (!isFavorite) continue;
      if (CommsMessageStore.instance.pendingOutboundFor(device.fingerprint).isEmpty) continue;
      await deliverPendingTo(myFingerprint: myFingerprint, contactFingerprint: device.fingerprint, ip: ip);
    }
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final favorites = context.watch(favoritesProvider);

    if (favorites.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.forum, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('COMMS', style: TextStyle(fontFamily: airLinkHeadingFont, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 2)),
              const SizedBox(height: 10),
              const Text(
                'Pair a device first (Settings → Pair a device). Each paired phone becomes a Comms contact.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final sorted = [...favorites]..sort((a, b) {
      final la = CommsMessageStore.instance.lastForContact(a.fingerprint)?.createdAt;
      final lb = CommsMessageStore.instance.lastForContact(b.fingerprint)?.createdAt;
      if (la == null && lb == null) return a.alias.compareTo(b.alias);
      if (la == null) return 1;
      if (lb == null) return -1;
      return lb.compareTo(la);
    });

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sorted.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final favorite = sorted[index];
        final last = CommsMessageStore.instance.lastForContact(favorite.fingerprint);
        final unread = CommsMessageStore.instance.unreadCountForContact(favorite.fingerprint);
        return _ContactTile(favorite: favorite, last: last, unread: unread);
      },
    );
  }
}

class _ContactTile extends StatelessWidget {
  final FavoriteDevice favorite;
  final CommsMessage? last;
  final int unread;

  const _ContactTile({required this.favorite, required this.last, required this.unread});

  String _preview() {
    final message = last;
    if (message == null) return 'No messages yet';
    final who = message.outgoing ? 'You: ' : '';
    switch (message.type) {
      case CommsMessageType.text:
        return '$who${message.body}';
      case CommsMessageType.audio:
        return '$who🎙 Voice message';
      case CommsMessageType.location:
        return '$who📍 Location';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Icon(Icons.person, color: theme.colorScheme.primary),
      ),
      title: Text(favorite.alias, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(_preview(), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (last != null) Text(DateFormat.Hm().format(last!.createdAt), style: theme.textTheme.bodySmall),
          if (unread > 0)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(10)),
              child: Text('$unread', style: TextStyle(color: theme.colorScheme.onPrimary, fontSize: 12, fontWeight: FontWeight.bold)),
            )
          else if (last != null && last!.outgoing)
            Icon(
              last!.status == CommsMessageStatus.delivered ? Icons.done_all : Icons.schedule,
              size: 16,
              color: last!.status == CommsMessageStatus.delivered ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
        ],
      ),
      onTap: () async {
        await CommsMessageStore.instance.markContactRead(favorite.fingerprint);
        if (context.mounted) {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatThreadPage(favorite: favorite)));
        }
      },
    );
  }
}
