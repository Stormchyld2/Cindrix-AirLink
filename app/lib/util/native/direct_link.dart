import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/pairing_payload.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('com.cindrix.airlink/airlink');
final _logger = Logger('DirectLink');

/// Result of starting or joining a direct link.
class LinkResult {
  final bool ok;

  /// Error code from the native side (`unsupported`, `permission`, `wifi_off`, `timeout`, ...).
  final String? error;
  final String? ssid;
  final String? passphrase;
  final String? ip;

  const LinkResult({required this.ok, this.error, this.ssid, this.passphrase, this.ip});

  factory LinkResult.fromMap(Map? map) {
    if (map == null) {
      return const LinkResult(ok: false, error: 'no_response');
    }
    return LinkResult(
      ok: map['ok'] == true,
      error: map['error'] as String?,
      ssid: map['ssid'] as String?,
      passphrase: map['passphrase'] as String?,
      ip: map['ip'] as String?,
    );
  }

  /// A short sentence the user can act on.
  String get message => switch (error) {
    'unsupported' => 'This phone does not support this connection method.',
    'permission' => 'Permission for nearby devices / location was not granted.',
    'wifi_off' => 'Turn Wi-Fi on first (it does not need to be connected to anything).',
    'timeout' || 'unavailable' => 'Could not find the other device. Make sure it started the link and is close by.',
    _ => 'The connection could not be set up (${error ?? 'unknown error'}).',
  };
}

bool get _isAndroid => checkPlatform([TargetPlatform.android]);

/// Whether this device can create/join links of this [method] without a router.
Future<bool> isLinkSupported(LinkMethod method) async {
  if (!_isAndroid) return false;
  try {
    return switch (method) {
      LinkMethod.direct => await _channel.invokeMethod<bool>('directLinkSupported') ?? false,
      LinkMethod.hotspot => await _channel.invokeMethod<bool>('hotspotSupported') ?? false,
      LinkMethod.lan => true,
    };
  } catch (e) {
    _logger.warning('support check failed', e);
    return false;
  }
}

/// Asks for the runtime permission that Wi-Fi Direct / hotspot need.
/// Android 13 and newer use "nearby devices", older versions use location. Works on any version.
Future<bool> ensureLinkPermissions() async {
  if (!_isAndroid) return false;
  final sdk = RefenaScope.defaultRef.read(deviceInfoProvider).androidSdkInt ?? 0;
  final permission = sdk >= 33 ? Permission.nearbyWifiDevices : Permission.locationWhenInUse;
  final status = await permission.request();
  return status.isGranted;
}

/// Starts the host side of a link. For [LinkMethod.lan] nothing is started.
Future<LinkResult> startLinkHost(LinkMethod method) async {
  if (!_isAndroid || method == LinkMethod.lan) {
    return const LinkResult(ok: false, error: 'unsupported');
  }
  if (!await ensureLinkPermissions()) {
    return const LinkResult(ok: false, error: 'permission');
  }
  try {
    final name = method == LinkMethod.direct ? 'directLinkStart' : 'hotspotStart';
    return LinkResult.fromMap(await _channel.invokeMethod<Map>(name));
  } catch (e) {
    _logger.warning('start failed', e);
    return LinkResult(ok: false, error: e.toString());
  }
}

/// Joins the link of a host. The result contains the host's address.
Future<LinkResult> joinLink(LinkMethod method, String ssid, String passphrase) async {
  if (!_isAndroid || method == LinkMethod.lan) {
    return const LinkResult(ok: false, error: 'unsupported');
  }
  if (!await ensureLinkPermissions()) {
    return const LinkResult(ok: false, error: 'permission');
  }
  try {
    final name = method == LinkMethod.direct ? 'directLinkJoin' : 'hotspotJoin';
    return LinkResult.fromMap(await _channel.invokeMethod<Map>(name, {'ssid': ssid, 'passphrase': passphrase}));
  } catch (e) {
    _logger.warning('join failed', e);
    return LinkResult(ok: false, error: e.toString());
  }
}

/// How many devices are connected to the Wi-Fi Direct group this phone hosts (0 if unknown).
Future<int> directLinkClientCount() async {
  if (!_isAndroid) return 0;
  try {
    return await _channel.invokeMethod<int>('directLinkClients') ?? 0;
  } catch (_) {
    return 0;
  }
}

/// Holds the CPU and Wi-Fi awake (screen off included) while a transfer runs.
Future<void> setKeepAwake(bool on) async {
  if (!_isAndroid) return;
  try {
    await _channel.invokeMethod('keepAwake', {'on': on});
  } catch (_) {}
}

Future<void> _stopNative() async {
  if (!_isAndroid) return;
  for (final name in ['directLinkStop', 'hotspotStop']) {
    try {
      await _channel.invokeMethod(name);
    } catch (e) {
      _logger.warning('$name failed', e);
    }
  }
}

/// Keeps a direct link open only as long as it is needed:
/// it is closed shortly after the last transfer finishes, or if nothing starts within [_noTransferTimeout].
class LinkWatcher {
  static const _noTransferTimeout = Duration(minutes: 10);
  static const _afterTransferDelay = Duration(seconds: 10);

  static Timer? _timer;
  static DateTime _startedAt = DateTime.now();
  static DateTime? _idleSince;
  static bool _sawTransfer = false;
  static bool _keepOpen = false;

  /// `true` while a direct link is open.
  static final ValueNotifier<LinkMethod?> active = ValueNotifier(null);

  /// With [keepOpen] the link is not closed automatically; the caller closes it with [end] (used by "Share with anyone",
  /// where the page serves downloads for as long as the screen is open).
  static void begin(LinkMethod method, {bool keepOpen = false}) {
    _timer?.cancel();
    _keepOpen = keepOpen;
    _startedAt = DateTime.now();
    _idleSince = null;
    _sawTransfer = false;
    active.value = method;
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  /// Closes the link now (user pressed disconnect, or the transfer is done).
  static Future<void> end() async {
    _timer?.cancel();
    _timer = null;
    active.value = null;
    await _stopNative();
  }

  static bool _isBusy(SessionStatus status) => status == SessionStatus.waiting || status == SessionStatus.sending;

  /// `true` while a file is being sent or received.
  static bool get transferBusy {
    final ref = RefenaScope.defaultRef;
    final receiving = ref.read(serverProvider)?.session;
    final sending = ref.read(sendProvider).values;
    return (receiving != null && _isBusy(receiving.status)) || sending.any((s) => _isBusy(s.status));
  }

  static void _tick() {
    if (_keepOpen) return;
    final busy = transferBusy;
    final now = DateTime.now();

    if (busy) {
      _sawTransfer = true;
      _idleSince = null;
      return;
    }

    if (_sawTransfer) {
      _idleSince ??= now;
      if (now.difference(_idleSince!) >= _afterTransferDelay) {
        _logger.info('transfer finished, closing the direct link');
        unawaited(end());
      }
    } else if (now.difference(_startedAt) >= _noTransferTimeout) {
      _logger.info('no transfer started, closing the direct link');
      unawaited(end());
    }
  }
}

/// Remembers how to rejoin a device that was paired before (only Wi-Fi Direct credentials are stable).
class LinkStore {
  static const _key = 'airlink_direct_links';

  static Future<Map<String, dynamic>> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(String fingerprint, String ssid, String passphrase) async {
    final all = await _load();
    all[fingerprint] = {'ssid': ssid, 'passphrase': passphrase};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(all));
    } catch (e) {
      _logger.warning('could not save link', e);
    }
  }

  /// Returns `(ssid, passphrase)` for a paired device, or null.
  static Future<(String, String)?> find(String fingerprint) async {
    final entry = (await _load())[fingerprint];
    if (entry is Map && entry['ssid'] is String && entry['passphrase'] is String) {
      return (entry['ssid'] as String, entry['passphrase'] as String);
    }
    return null;
  }
}
