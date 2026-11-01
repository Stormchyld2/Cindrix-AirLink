import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/comms/message.dart';
import 'package:localsend_app/comms/message_store.dart';
import 'package:logging/logging.dart';

final _logger = Logger('CommsServer');

/// Comms' own tiny delivery channel: one port, one endpoint, pure Dart. Deliberately separate from the
/// Rust-based file-transfer server (`packages/core`) rather than a new endpoint on it, so Comms can be
/// built, changed and tested without touching the FRB-generated bridge or the Rust side at all.
///
/// Security note: this channel trusts whatever `from` fingerprint a message claims, unlike the file-transfer
/// protocol's certificate-bound identity. The real protection is the same one "Share with anyone" already
/// relies on: only someone on the private Wi-Fi Direct network (i.e. who has the password) can reach this
/// port at all. Good enough for a family link; worth tightening (pin the sender's cert, like pairing does)
/// before this is treated as hardened against anyone deliberately hostile already on the link.
class CommsServer {
  static const port = 53318;

  static HttpServer? _server;

  static bool get running => _server != null;

  static Future<void> start() async {
    if (_server != null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
      _server = server;
      _logger.info('Comms server listening on $port');
      server.listen(_handle, onError: (Object e) => _logger.warning('Comms server error', e));
    } catch (e) {
      _logger.warning('Could not start the comms server', e);
    }
  }

  static Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  static Future<void> _handle(HttpRequest request) async {
    if (request.method != 'POST' || request.uri.path != '/comms/deliver') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final message = CommsMessage.fromWire(json);
      await CommsMessageStore.instance.receive(message);
      request.response.statusCode = HttpStatus.ok;
    } catch (e) {
      _logger.warning('Dropped a malformed comms delivery', e);
      request.response.statusCode = HttpStatus.badRequest;
    }
    await request.response.close();
  }
}
