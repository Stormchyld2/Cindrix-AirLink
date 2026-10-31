import 'dart:convert';

/// How two devices are linked when there may be no router.
enum LinkMethod {
  /// Wi-Fi Direct: a private device-to-device link, no router or hotspot needed (preferred).
  direct,

  /// The phone's local-only hotspot (no internet needed). Fallback when Wi-Fi Direct fails.
  hotspot,

  /// Both devices are already on the same Wi-Fi network (or hotspot) and only need to find each other.
  lan,
}

/// What a pairing QR code carries: who the other device is, how to reach it, and (for a direct link) the private network to join.
class PairingPayload {
  static const _prefix = 'CINDRIX-AIRLINK:1:';

  final String alias;
  final String fingerprint;

  /// Address of the host. For hotspot links it is learned by the joining device, so it can be empty.
  final String ip;
  final int port;
  final bool https;
  final LinkMethod method;
  final String? ssid;
  final String? passphrase;

  const PairingPayload({
    required this.alias,
    required this.fingerprint,
    required this.ip,
    required this.port,
    required this.https,
    required this.method,
    this.ssid,
    this.passphrase,
  });

  String encode() {
    return _prefix +
        jsonEncode({
          'a': alias,
          'f': fingerprint,
          'i': ip,
          'p': port,
          's': https,
          'm': method.name,
          if (ssid != null) 'n': ssid,
          if (passphrase != null) 'k': passphrase,
        });
  }

  /// Returns `null` if [raw] is not an AirLink pairing code.
  static PairingPayload? tryParse(String raw) {
    if (!raw.startsWith(_prefix)) {
      return null;
    }
    try {
      final map = jsonDecode(raw.substring(_prefix.length)) as Map<String, dynamic>;
      final method = LinkMethod.values.firstWhere((e) => e.name == map['m'], orElse: () => LinkMethod.lan);
      return PairingPayload(
        alias: map['a'] as String,
        fingerprint: map['f'] as String,
        ip: (map['i'] as String?) ?? '',
        port: map['p'] as int,
        https: map['s'] as bool,
        method: method,
        ssid: map['n'] as String?,
        passphrase: map['k'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
