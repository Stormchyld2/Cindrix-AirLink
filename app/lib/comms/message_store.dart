import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/comms/message.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('CommsMessageStore');
const _uuid = Uuid();

/// All comms messages, newline-delimited JSON, one line per [CommsMessage]. Lives in the app's own
/// private storage (not a shared folder), since this is a mailbox between two phones, not a file to hand
/// someone else. Loaded fully into memory on start; message volume here is small (text + occasional audio
/// clip paths, not the clips themselves), so this is simpler and more robust than a real database for v1.
class CommsMessageStore extends ChangeNotifier {
  static final CommsMessageStore instance = CommsMessageStore._();
  CommsMessageStore._();

  final List<CommsMessage> _messages = [];
  bool _loaded = false;

  List<CommsMessage> get all => List.unmodifiable(_messages);

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'comms_messages.jsonl'));
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          _messages.add(CommsMessage.fromJson(jsonDecode(line) as Map<String, dynamic>));
        } catch (e) {
          _logger.warning('Skipping a corrupt comms message line', e);
        }
      }
      notifyListeners();
    } catch (e) {
      _logger.warning('Could not load comms messages', e);
    }
  }

  Future<void> _persist() async {
    try {
      final file = await _file();
      await file.writeAsString('${CommsMessage.encodeList(_messages)}\n');
    } catch (e) {
      _logger.warning('Could not save comms messages', e);
    }
  }

  List<CommsMessage> forContact(String fingerprint) =>
      _messages.where((m) => m.contactFingerprint == fingerprint).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  CommsMessage? lastForContact(String fingerprint) {
    final list = forContact(fingerprint);
    return list.isEmpty ? null : list.last;
  }

  int unreadCountForContact(String fingerprint) => _messages.where((m) => m.contactFingerprint == fingerprint && !m.outgoing && !m.read).length;

  int get totalUnread => _messages.where((m) => !m.outgoing && !m.read).length;

  List<CommsMessage> get pendingOutbound => _messages.where((m) => m.outgoing && m.status == CommsMessageStatus.pending).toList();

  List<CommsMessage> pendingOutboundFor(String fingerprint) =>
      pendingOutbound.where((m) => m.contactFingerprint == fingerprint).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// Queues an outgoing text message. It is delivered the next time [CommsSync] reaches this contact.
  Future<CommsMessage> queueText({required String contactFingerprint, required String text}) {
    return _add(
      CommsMessage(
        id: _uuid.v4(),
        contactFingerprint: contactFingerprint,
        outgoing: true,
        type: CommsMessageType.text,
        body: text,
        createdAt: DateTime.now(),
        status: CommsMessageStatus.pending,
        read: true,
      ),
    );
  }

  /// Queues an outgoing push-to-talk clip. [localAudioPath] is a file this device already recorded.
  Future<CommsMessage> queueAudio({required String contactFingerprint, required String localAudioPath}) {
    return _add(
      CommsMessage(
        id: _uuid.v4(),
        contactFingerprint: contactFingerprint,
        outgoing: true,
        type: CommsMessageType.audio,
        body: localAudioPath,
        createdAt: DateTime.now(),
        status: CommsMessageStatus.pending,
        read: true,
      ),
    );
  }

  /// Records a message that just arrived from the comms server.
  Future<void> receive(CommsMessage message) async {
    if (_messages.any((m) => m.id == message.id)) return; // already have it (resend after a dropped ack)
    await _add(message);
  }

  Future<CommsMessage> _add(CommsMessage message) async {
    _messages.add(message);
    notifyListeners();
    await _persist();
    return message;
  }

  Future<void> markDelivered(String id) async {
    final i = _messages.indexWhere((m) => m.id == id);
    if (i == -1) return;
    _messages[i] = _messages[i].copyWith(status: CommsMessageStatus.delivered);
    notifyListeners();
    await _persist();
  }

  Future<void> markContactRead(String fingerprint) async {
    var changed = false;
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m.contactFingerprint == fingerprint && !m.outgoing && !m.read) {
        _messages[i] = m.copyWith(read: true);
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      await _persist();
    }
  }
}
