import 'dart:math';

/// Military-style callsigns, e.g. "Falcon-27". Used as the default device name
/// and by the "generate random alias" button in Settings.
const _callsigns = [
  'Falcon',
  'Viper',
  'Ranger',
  'Raven',
  'Wolf',
  'Hawk',
  'Eagle',
  'Cobra',
  'Titan',
  'Ghost',
  'Anvil',
  'Bravo',
  'Delta',
  'Echo',
  'Foxtrot',
  'Golf',
  'Hotel',
  'Kilo',
  'Lima',
  'Mike',
  'Oscar',
  'Romeo',
  'Sierra',
  'Tango',
  'Victor',
  'Whiskey',
  'Zulu',
  'Sentry',
  'Outpost',
  'Relay',
  'Warden',
  'Vanguard',
  'Granite',
  'Summit',
  'Talon',
  'Reaper',
];

String generateRandomAlias() {
  final random = Random();
  final name = _callsigns[random.nextInt(_callsigns.length)];
  final number = (random.nextInt(99) + 1).toString().padLeft(2, '0');
  return '$name-$number';
}
