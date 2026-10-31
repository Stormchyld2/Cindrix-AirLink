import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/model/pairing_payload.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/direct_link.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Pair two devices once, even with no router, no hotspot and no internet.
///
/// Connection methods, in order of preference: Wi-Fi Direct, the phone's local-only hotspot, then
/// the Wi-Fi network both devices are already on.
class PairPage extends StatefulWidget {
  const PairPage();

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> with Refena {
  /// `null` means automatic: try every method in order.
  LinkMethod? _choice;
  PairingPayload? _payload;
  bool _busy = false;
  String? _status;
  String? _error;

  bool get _canScan => checkPlatform([TargetPlatform.android, TargetPlatform.iOS]);

  static String _methodName(LinkMethod method) => switch (method) {
    LinkMethod.direct => 'Wi-Fi Direct',
    LinkMethod.hotspot => 'Phone hotspot',
    LinkMethod.lan => 'Same Wi-Fi',
  };

  /// Host side: open a link and show the code the other device scans.
  Future<void> _startHost() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Starting…';
      _payload = null;
    });
    await LinkWatcher.end();

    final me = ref.read(deviceFullInfoProvider);
    final fingerprint = me.fingerprint;
    if (me.port <= 0) {
      setState(() {
        _busy = false;
        _status = null;
        _error = 'AirLink is not receiving yet. Wait a moment and try again.';
      });
      return;
    }

    final order = _choice == null ? [LinkMethod.direct, LinkMethod.hotspot, LinkMethod.lan] : [_choice!];
    String? lastError;

    for (final method in order) {
      if (method == LinkMethod.lan) {
        final lanIp = me.ip;
        if (lanIp == null || lanIp == '-') {
          lastError ??= 'Not connected to a Wi-Fi network.';
          continue;
        }
        _showPayload(PairingPayload(alias: me.alias, fingerprint: fingerprint, ip: lanIp, port: me.port, https: me.https, method: method));
        return;
      }

      if (mounted) {
        setState(() => _status = 'Trying ${_methodName(method)}…');
      }
      if (!await isLinkSupported(method)) {
        lastError = '${_methodName(method)} is not available on this device.';
        continue;
      }
      final result = await startLinkHost(method);
      if (!mounted) return;
      if (result.ok) {
        LinkWatcher.begin(method);
        _showPayload(
          PairingPayload(
            alias: me.alias,
            fingerprint: fingerprint,
            ip: result.ip ?? '',
            port: me.port,
            https: me.https,
            method: method,
            ssid: result.ssid,
            passphrase: result.passphrase,
          ),
        );
        return;
      }
      lastError = '${_methodName(method)}: ${result.message}';
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = null;
      _error = lastError ?? 'No connection method is available.';
    });
  }

  void _showPayload(PairingPayload payload) {
    if (!mounted) return;
    setState(() {
      _payload = payload;
      _busy = false;
      _status = 'Ready (${_methodName(payload.method)}). Scan this code on the other device.';
      _error = null;
    });
  }

  /// Joining side: scan a code, join the link, introduce ourselves and remember the device.
  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));
    if (raw == null || !mounted) return;
    final payload = PairingPayload.tryParse(raw);
    if (payload == null) {
      context.showSnackBar('That is not a Cindrix AirLink code.');
      return;
    }
    await _connect(payload);
  }

  Future<void> _reconnect(FavoriteDevice favorite) async {
    final saved = await LinkStore.find(favorite.fingerprint);
    if (!mounted) return;
    if (saved == null) {
      context.showSnackBar('No saved direct link for this device. Scan its code once.');
      return;
    }
    await _connect(
      PairingPayload(
        alias: favorite.alias,
        fingerprint: favorite.fingerprint,
        ip: favorite.ip,
        port: favorite.port,
        https: ref.read(settingsProvider).https,
        method: LinkMethod.direct,
        ssid: saved.$1,
        passphrase: saved.$2,
      ),
    );
  }

  Future<void> _connect(PairingPayload payload) async {
    setState(() {
      _busy = true;
      _error = null;
      _payload = null;
      _status = 'Connecting to ${payload.alias}…';
    });

    var ip = payload.ip;
    if (payload.method != LinkMethod.lan) {
      final ssid = payload.ssid;
      final pass = payload.passphrase;
      if (ssid == null || pass == null) {
        setState(() {
          _busy = false;
          _status = null;
          _error = 'This code is missing the link details.';
        });
        return;
      }
      final result = await joinLink(payload.method, ssid, pass);
      if (!mounted) return;
      if (!result.ok) {
        setState(() {
          _busy = false;
          _status = null;
          _error = '${_methodName(payload.method)}: ${result.message}\nYou can ask the other device to choose another method.';
        });
        return;
      }
      ip = result.ip ?? payload.ip;
      LinkWatcher.begin(payload.method);
      if (payload.method == LinkMethod.direct) {
        await LinkStore.save(payload.fingerprint, ssid, pass);
      }
    }

    setState(() => _status = 'Linking with ${payload.alias}…');
    final reached = await _register(ip, payload);
    await _saveFavorite(payload, ip);
    if (!mounted) return;

    setState(() {
      _busy = false;
      _error = reached ? null : 'Linked, but ${payload.alias} did not answer yet. Open the Send tab to retry.';
      _status = reached ? '${payload.alias} is paired. Go to the Send tab and pick it.' : null;
    });
  }

  /// Tells the host who we are, so it can see us in its device list too.
  Future<bool> _register(String ip, PairingPayload payload) async {
    final me = ref.read(deviceFullInfoProvider).toRegisterDto();
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final http = ref.read(httpProvider);
        final client = payload.https ? http.pinnedTo(payload.fingerprint) : http.discovery;
        await client.register(
          protocol: payload.https ? ProtocolType.https : ProtocolType.http,
          ip: ip,
          port: payload.port,
          payload: me,
        );
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    return false;
  }

  Future<void> _saveFavorite(PairingPayload payload, String ip) async {
    final existing = ref.read(favoritesProvider).firstWhereOrNull((e) => e.fingerprint == payload.fingerprint);
    final action = existing != null
        ? UpdateFavoriteAction(existing.copyWith(ip: ip, port: payload.port))
        : AddFavoriteAction(
            FavoriteDevice.fromValues(fingerprint: payload.fingerprint, ip: ip, port: payload.port, alias: payload.alias),
          );
    await ref.redux(favoritesProvider).dispatchAsync(action);
  }

  Future<void> _disconnect() async {
    await LinkWatcher.end();
    if (!mounted) return;
    setState(() {
      _payload = null;
      _status = 'Disconnected.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final favorites = ref.watch(favoritesProvider);
    final payload = _payload;

    return Scaffold(
      appBar: AppBar(title: const Text('Pair a device')),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        children: [
          Text(
            'Connect two devices directly, with no router, hotspot or internet. '
            'Pair once; after that the device is remembered.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          Text('Connection method', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(label: const Text('Auto'), selected: _choice == null, onSelected: (_) => setState(() => _choice = null)),
              for (final method in LinkMethod.values)
                ChoiceChip(
                  label: Text(_methodName(method)),
                  selected: _choice == method,
                  onSelected: (_) => setState(() => _choice = method),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Auto tries Wi-Fi Direct first, then the phone hotspot, then the Wi-Fi you are both on.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _startHost,
            icon: const Icon(Icons.qr_code),
            label: const Text('Start link and show code'),
          ),
          if (_canScan) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan a code'),
            ),
          ],
          const SizedBox(height: 20),
          if (_busy) const Center(child: CircularProgressIndicator()),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_status!, textAlign: TextAlign.center, style: theme.textTheme.titleSmall),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (payload != null)
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                child: SizedBox(
                  width: 240,
                  height: 240,
                  child: PrettyQrView.data(
                    errorCorrectLevel: QrErrorCorrectLevel.M,
                    data: payload.encode(),
                    decoration: const PrettyQrDecoration(shape: PrettyQrSmoothSymbol(roundFactor: 0, color: Colors.black)),
                  ),
                ),
              ),
            ),
          ValueListenableBuilder<LinkMethod?>(
            valueListenable: LinkWatcher.active,
            builder: (context, active, _) {
              if (active == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  children: [
                    Text(
                      '${_methodName(active)} link is open. It closes by itself when the transfer is done.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                    TextButton(onPressed: _disconnect, child: const Text('Disconnect now')),
                  ],
                ),
              );
            },
          ),
          if (favorites.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Paired devices', style: theme.textTheme.titleMedium),
            for (final favorite in favorites)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices),
                title: Text(favorite.alias),
                subtitle: Text(favorite.ip),
                trailing: _canScan
                    ? TextButton(onPressed: _busy ? null : () => _reconnect(favorite), child: const Text('Reconnect'))
                    : null,
              ),
          ],
        ],
      ),
    );
  }
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && PairingPayload.tryParse(value) != null) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan code')),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}
