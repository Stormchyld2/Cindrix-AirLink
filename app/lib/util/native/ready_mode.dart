import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/model/pairing_payload.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/util/native/direct_link.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _logger = Logger('ReadyMode');

/// "Ready" mode (Android only): when the phone has no usable network, AirLink opens its stored Wi-Fi Direct group by itself,
/// so a paired phone can connect with one tap. Phase 1: it only runs while the app is on screen.
class ReadyMode with WidgetsBindingObserver {
  static const _prefKey = 'airlink_ready_mode';

  /// The Wi-Fi Direct address range; addresses in it do not count as a real network.
  static const _directPrefix = '192.168.49.';

  static final ReadyMode _instance = ReadyMode._();
  ReadyMode._();

  /// The user setting.
  static final ValueNotifier<bool> enabled = ValueNotifier(true);

  /// `true` while this phone hosts the group and waits for a paired phone.
  static final ValueNotifier<bool> ready = ValueNotifier(false);

  static Timer? _timer;
  static bool _busy = false;
  static bool _foreground = true;

  static bool get _supported => checkPlatform([TargetPlatform.android]);

  static Future<void> init() async {
    if (!_supported || _timer != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_prefKey) ?? true;
    } catch (_) {}
    WidgetsBinding.instance.addObserver(_instance);
    LinkWatcher.active.addListener(() {
      // the link was closed by someone else (Done button, timeout)
      if (LinkWatcher.active.value == null && ready.value) {
        ready.value = false;
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(evaluate()));
    unawaited(evaluate());
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {}
    await evaluate();
  }

  static bool _hasRealNetwork() {
    final ips = RefenaScope.defaultRef.read(localIpProvider).localIps;
    return ips.any((ip) => !ip.startsWith(_directPrefix));
  }

  /// Starts or stops Ready so that it matches the current situation.
  static Future<void> evaluate() async {
    if (!_supported || _busy) return;
    final shouldRun = enabled.value && _foreground && !_hasRealNetwork();

    if (!shouldRun) {
      if (ready.value && !LinkWatcher.transferBusy) {
        _logger.info('leaving Ready mode');
        await release();
      }
      return;
    }
    if (ready.value || LinkWatcher.active.value != null) return;

    _busy = true;
    try {
      if (!await isLinkSupported(LinkMethod.direct)) return;
      final result = await startLinkHost(LinkMethod.direct);
      if (!result.ok) {
        _logger.info('Ready mode could not start: ${result.message}');
        return;
      }
      LinkWatcher.begin(LinkMethod.direct, keepOpen: true);
      ready.value = true;
    } finally {
      _busy = false;
    }
  }

  /// Turns Ready off and closes the link.
  static Future<void> release() async {
    ready.value = false;
    await LinkWatcher.end();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    unawaited(evaluate());
  }
}
