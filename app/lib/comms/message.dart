import 'dart:convert';

enum CommsMessageType {
  text,
  audio,
  // Reserved for v1's later piece (check-in / start point / breadcrumbs): a lat/lon the receiver can
  // drop onto the shared GPX file the map viewer reads. Not sent by anything yet.
  location,
}

enum CommsMessageStatus { pending, delivered }

/// One message in the mailbox: text, a push-to-talk clip, or (later) a location. Lives in [CommsMessageStore],
/// one JSON record per line. `contactFingerprint` is always the *other* device, whichever direction this is.
class CommsMessage {
  final String id;
  final String contactFingerprint;
  final bool outgoing;
  final CommsMessageType type;

  /// The text body for [CommsMessageType.text], or a local file path for [CommsMessageType.audio].
  final String body;

  final DateTime createdAt;
  final CommsMessageStatus status;
  final bool read;

  const CommsMessage({
    required this.id,
    required this.contactFingerprint,
    required this.outgoing,
    required this.type,
    required this.body,
    required this.createdAt,
    required this.status,
    required this.read,
  });

  CommsMessage copyWith({CommsMessageStatus? status, bool? read}) => CommsMessage(
    id: id,
    contactFingerprint: contactFingerprint,
    outgoing: outgoing,
    type: type,
    body: body,
    createdAt: createdAt,
    status: status ?? this.status,
    read: read ?? this.read,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'contactFingerprint': contactFingerprint,
    'outgoing': outgoing,
    'type': type.name,
    'body': body,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'read': read,
  };

  factory CommsMessage.fromJson(Map<String, dynamic> json) => CommsMessage(
    id: json['id'] as String,
    contactFingerprint: json['contactFingerprint'] as String,
    outgoing: json['outgoing'] as bool,
    type: CommsMessageType.values.byName(json['type'] as String),
    body: json['body'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    status: CommsMessageStatus.values.byName(json['status'] as String),
    read: json['read'] as bool? ?? true,
  );

  /// The wire form sent to the other phone's comms server: everything except our own local [status]/[read],
  /// which are never meaningful to the recipient, plus `from`, our fingerprint, which [contactFingerprint]
  /// is not (that field always names the *other* side, so it can't double as the sender id on the wire).
  Map<String, dynamic> toWire(String myFingerprint, {String myAlias = ''}) => {
    'id': id,
    'from': myFingerprint,
    'fromAlias': myAlias,
    'type': type.name,
    'body': body,
    'createdAt': createdAt.toIso8601String(),
  };

  static CommsMessage fromWire(Map<String, dynamic> json) => CommsMessage(
    id: json['id'] as String,
    contactFingerprint: json['from'] as String,
    outgoing: false,
    type: CommsMessageType.values.byName(json['type'] as String),
    body: json['body'] as String,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    status: CommsMessageStatus.delivered,
    read: false,
  );

  static String encodeList(List<CommsMessage> messages) => messages.map((m) => jsonEncode(m.toJson())).join('\n');
}
