import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/comms/comms_sync.dart';
import 'package:localsend_app/config/tier.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/ready_mode.dart';
import 'package:localsend_isolates/util/foreground_service.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _logger = Logger('BackgroundMode');

/// AirLink Pro only (Android): keeps the app alive with a foreground service while the screen is off or
/// AirLink is in the background, so Ready mode (the Wi-Fi Direct group) and Comms delivery keep working.
///
/// Android 12+ only lets a foreground service START while the app is visible, so the service is started
/// whenever the app comes to the front and then simply keeps running. Swiping AirLink out of the recent-apps
/// list still ends it (that kills the app process); the notification says so.
class BackgroundMode with WidgetsBindingObserver {
  static const _prefKey = 'airlink_background_mode';

  static final BackgroundMode _instance = BackgroundMode._();
  BackgroundMode._();

  /// The user setting (default on for Pro).
  static final ValueNotifier<bool> enabled = ValueNotifier(true);

  /// `true` while the stay-ready service is running; Ready mode then keeps going in the background.
  static final ValueNotifier<bool> running = ValueNotifier(false);

  /// `true` when Android may not kill us for battery reasons (battery-optimisation exemption granted).
  static final ValueNotifier<bool> batteryExempt = ValueNotifier(false);

  static Timer? _timer;
  static bool _foreground = true;

  static bool get supported => isPro && checkPlatform([TargetPlatform.android]);

  static Future<void> init() async {
    if (!supported || _timer != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_prefKey) ?? true;
    } catch (_) {}
    ReadyMode.backgroundAllowed = () => running.value;
    WidgetsBinding.instance.addObserver(_instance);
    _foreground = WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    await refreshBatteryExempt();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_tick()));
    await _tick();
  }

  static Future<void> refreshBatteryExempt() async {
    try {
      batteryExempt.value = await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {}
  }

  /// Shows the system "allow AirLink Pro to run in the background" prompt.
  static Future<void> requestBatteryExemption() async {
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (e) {
      _logger.warning('Battery exemption request failed', e);
    }
    await refreshBatteryExempt();
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {}
    await _tick();
  }

  static String get _statusText {
    if (ReadyMode.ready.value) return 'READY: paired phones can connect. Swiping this app away from recents stops it.';
    return 'Listening for messages and paired phones. Swiping this app away from recents stops it.';
  }

  static Future<void> _tick() async {
    if (!supported) return;

    if (enabled.value) {
      if (ForegroundService.isPersistent && running.value) {
        // keep the notification text in step with Ready mode (works in the background too)
        ForegroundService.startPersistent(channelName: 'AirLink Pro ready', title: 'AirLink Pro is on standby', text: _statusText);
      } else if (_foreground) {
        // only start while visible: Android 12+ refuses to start a foreground service from the background
        ForegroundService.startPersistent(channelName: 'AirLink Pro ready', title: 'AirLink Pro is on standby', text: _statusText);
        running.value = true;
      }
    } else if (running.value) {
      ForegroundService.stopPersistent();
      running.value = false;
    }

    // Deliver queued Comms messages to any paired contact we can currently see, screen on or off.
    await flushCommsToNearby(RefenaScope.defaultRef);
    unawaited(ReadyMode.evaluate());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(refreshBatteryExempt());
      unawaited(_tick());
    }
  }
}
