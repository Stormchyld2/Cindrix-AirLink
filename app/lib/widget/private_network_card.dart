import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/pairing_payload.dart';
import 'package:localsend_app/util/native/direct_link.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

/// "Share with anyone": creates a private Wi-Fi network (no router, no internet) and shows two QR codes for a friend
/// who has no app: first one joins the Wi-Fi (any phone camera offers "Connect"), the second opens the download page.
/// Android only. The page itself is served by the web share server that [WebSharePage] already runs.
class PrivateNetworkCard extends StatefulWidget {
  final int port;
  final String? pin;
  final bool encrypted;

  /// Called when the private network is up, so the page can let downloads through without a manual accept.
  final VoidCallback? onStarted;

  const PrivateNetworkCard({required this.port, required this.pin, required this.encrypted, this.onStarted});

  @override
  State<PrivateNetworkCard> createState() => _PrivateNetworkCardState();
}

class _PrivateNetworkCardState extends State<PrivateNetworkCard> {
  bool _starting = false;
  String? _error;
  String? _ssid;
  String? _passphrase;
  String? _hostIp;
  bool _showStep2 = false;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Wi-Fi Direct tells us when a device joins, so step 2 can appear by itself.
  void _watchForFriend() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || _showStep2 || !_active) {
        _poll?.cancel();
        return;
      }
      if (await directLinkClientCount() > 0 && mounted) {
        setState(() => _showStep2 = true);
        _poll?.cancel();
      }
    });
  }

  bool get _active => _ssid != null;

  /// Standard Wi-Fi sharing code understood by the camera apps of Android and iPhone.
  static String _wifiCode(String ssid, String passphrase) {
    String esc(String s) => s.replaceAllMapped(RegExp(r'([\;,:"])'), (m) => '\\${m[1]}');
    return 'WIFI:T:WPA;S:${esc(ssid)};P:${esc(passphrase)};;';
  }

  String get _pageUrl {
    final base = '${widget.encrypted ? 'https' : 'http'}://$_hostIp:${widget.port}';
    final pin = widget.pin;
    return pin == null ? base : '$base/?pin=${Uri.encodeQueryComponent(pin)}';
  }

  String get _pageAddress => '${widget.encrypted ? 'https' : 'http'}://$_hostIp:${widget.port}';

  static Future<Set<String>> _ipv4Addresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return {for (final i in interfaces) for (final a in i.addresses) a.address};
    } catch (_) {
      return {};
    }
  }

  /// The hotspot does not report its own address, so look for the address that appeared after it started.
  static Future<String?> _newAddress(Set<String> before) async {
    for (var i = 0; i < 8; i++) {
      final now = await _ipv4Addresses();
      final added = now.difference(before);
      if (added.isNotEmpty) {
        return added.first;
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return null;
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    await LinkWatcher.end();

    String? lastError;
    // Wi-Fi Direct first, then the phone's own hotspot.
    for (final method in [LinkMethod.direct, LinkMethod.hotspot]) {
      if (!await isLinkSupported(method)) {
        lastError = 'This phone cannot create the private network.';
        continue;
      }
      final before = await _ipv4Addresses();
      final result = await startLinkHost(method);
      if (!mounted) return;
      if (!result.ok || result.ssid == null || result.passphrase == null) {
        lastError = result.message;
        continue;
      }
      final ip = result.ip ?? await _newAddress(before);
      if (!mounted) return;
      if (ip == null) {
        await LinkWatcher.end();
        lastError = 'The network started but its address could not be found.';
        continue;
      }
      LinkWatcher.begin(method, keepOpen: true);
      setState(() {
        _starting = false;
        _ssid = result.ssid;
        _passphrase = result.passphrase;
        _hostIp = ip;
        _showStep2 = false;
      });
      widget.onStarted?.call();
      if (method == LinkMethod.direct) _watchForFriend();
      return;
    }

    setState(() {
      _starting = false;
      _error = lastError ?? 'Could not create the private network.';
    });
  }

  Future<void> _stop() async {
    _poll?.cancel();
    await LinkWatcher.end();
    if (!mounted) return;
    setState(() {
      _ssid = null;
      _passphrase = null;
      _hostIp = null;
      _showStep2 = false;
    });
  }

  Widget _qr(String data) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
        child: SizedBox(
          width: 220,
          height: 220,
          child: PrettyQrView.data(
            errorCorrectLevel: QrErrorCorrectLevel.M,
            data: data,
            decoration: const PrettyQrDecoration(shape: PrettyQrSmoothSymbol(roundFactor: 0, color: Colors.black)),
          ),
        ),
      ),
    );
  }

  Widget _stepTitle(BuildContext context, String number, String text) {
    return Row(
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Text(number, style: TextStyle(fontFamily: airLinkHeadingFont, fontSize: 18, color: Theme.of(context).colorScheme.onPrimary)),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.titleLarge)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!checkPlatform([TargetPlatform.android])) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Share with anyone', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'No Wi-Fi? No app? Make a private network. Your friend only needs a phone camera and a browser.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            if (!_active) ...[
              FilledButton.icon(
                onPressed: _starting ? null : _start,
                icon: _starting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                label: Text(_starting ? 'Starting…' : 'Create private network'),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
            ] else ...[
              _stepTitle(context, '1', 'Join the Wi-Fi'),
              const SizedBox(height: 6),
              Text(
                'On your friend\'s phone, open the camera and point it at this code. When "Connect" appears, tap it. '
                'If the phone says "no internet", tap to stay connected.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 10),
              _qr(_wifiCode(_ssid!, _passphrase!)),
              const SizedBox(height: 8),
              SelectableText('Network:  $_ssid\nPassword:  $_passphrase', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              if (!_showStep2)
                FilledButton(
                  onPressed: () => setState(() => _showStep2 = true),
                  child: const Text('Not showing up? Tap here for step 2'),
                )
              else ...[
                _stepTitle(context, '2', 'Get the file'),
                const SizedBox(height: 6),
                Text(
                  'Now point the camera at this second code. It opens a page with the download button. '
                  'If the browser warns the page is "not private", tap Advanced, then Continue. That is normal on a private network.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                _qr(_pageUrl),
                const SizedBox(height: 8),
                Text('Or type this in the browser:', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(child: SelectableText(_pageAddress, textAlign: TextAlign.center, style: theme.textTheme.titleLarge)),
                    IconButton(
                      onPressed: () => Clipboard.setData(ClipboardData(text: _pageAddress)),
                      icon: const Icon(Icons.content_copy, size: 18),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _stop,
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Done — turn off the network'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
