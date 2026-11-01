import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/comms/comms_server.dart';
import 'package:localsend_app/comms/message_store.dart';
import 'package:logging/logging.dart';

final _logger = Logger('CommsSync');

/// Flushes a contact's pending outbox to their phone. Call this whenever we have reason to think they're
/// reachable at [ip] right now — after [quickConnect], after a normal pairing connect, or because a scan
/// just found them on the LAN. Safe to call speculatively: a contact with nothing pending, or one that
/// isn't actually there, just times out quickly and is tried again next opportunity.
Future<void> deliverPendingTo({required String myFingerprint, required String contactFingerprint, required String ip}) async {
  final pending = CommsMessageStore.instance.pendingOutboundFor(contactFingerprint);
  if (pending.isEmpty) return;

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    for (final message in pending) {
      try {
        final request = await client.post(ip, CommsServer.port, '/comms/deliver');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(message.toWire(myFingerprint)));
        final response = await request.close().timeout(const Duration(seconds: 5));
        await response.drain<void>();
        if (response.statusCode == HttpStatus.ok) {
          await CommsMessageStore.instance.markDelivered(message.id);
        } else {
          _logger.info('Comms delivery to $contactFingerprint rejected (${response.statusCode}); will retry later');
          break; // keep ordering: don't deliver a later message before an earlier one that failed
        }
      } catch (e) {
        _logger.info('Comms delivery to $contactFingerprint at $ip not reachable right now: $e');
        break;
      }
    }
  } finally {
    client.close(force: true);
  }
}
