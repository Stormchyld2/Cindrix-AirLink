import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';

/// Placeholder for AirLink Pro's Comms feature (messaging, later voice, over the same direct link
/// AirLink already uses for file transfer). Not built yet — this just reserves the tab and the
/// navigation slot so the real feature has a home from day one.
class CommsTab extends StatelessWidget {
  const CommsTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.forum, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 20),
            Text('COMMS', style: TextStyle(fontFamily: airLinkHeadingFont, fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: 2)),
            const SizedBox(height: 10),
            Text(
              'Grid-down messaging between paired phones, over the same private link AirLink already uses to send files.\n'
              'Coming to AirLink Pro.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
