import 'package:flutter/material.dart';
import 'package:localsend_app/model/pairing_payload.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/direct_link.dart';
import 'package:localsend_app/util/native/ready_mode.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// One-tap connect to a paired phone that is not on our network: joins its stored Wi-Fi Direct group
/// (which that phone opened in Ready mode) and returns the device, ready to send to. `null` if it did not work.
Future<Device?> quickConnect(BuildContext context, Ref ref, FavoriteDevice favorite) async {
  final saved = await LinkStore.find(favorite.fingerprint);
  if (saved == null) {
    if (context.mounted) context.showSnackBar('No direct link saved for ${favorite.alias}. Pair it once from "Pair a device".');
    return null;
  }

  // Only one phone can host: the sender gives up its own group and joins the other's.
  await ReadyMode.release();
  final result = await joinLink(LinkMethod.direct, saved.$1, saved.$2);
  if (!result.ok) {
    if (context.mounted) {
      context.showSnackBar('Could not reach ${favorite.alias}: ${result.message}\nIs AirLink open on that phone, showing READY?');
    }
    return null;
  }
  LinkWatcher.begin(LinkMethod.direct);

  final ip = result.ip ?? favorite.ip;
  final https = ref.read(settingsProvider).https;
  final me = ref.read(deviceFullInfoProvider).toRegisterDto();
  for (var attempt = 0; attempt < 6; attempt++) {
    try {
      final http = ref.read(httpProvider);
      final client = https ? http.pinnedTo(favorite.fingerprint) : http.discovery;
      final response = await client.register(
        protocol: https ? ProtocolType.https : ProtocolType.http,
        ip: ip,
        port: favorite.port,
        payload: me,
      );
      await ref.redux(favoritesProvider).dispatchAsync(UpdateFavoriteAction(favorite.copyWith(ip: ip)));
      return response.body.toDevice(ip, favorite.port, https);
    } catch (_) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  await LinkWatcher.end();
  if (context.mounted) {
    context.showSnackBar('Joined the link, but ${favorite.alias} did not answer. Is AirLink open there?');
  }
  return null;
}
