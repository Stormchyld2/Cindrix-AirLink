/// Which product this build is: plain Cindrix AirLink (file transfer) or AirLink Pro (adds Comms).
///
/// Set at build time with `--dart-define=TIER=pro`; the Android side picks the matching product
/// flavor (and app name / applicationId) with `--flavor pro`. Unflavored/undefined builds are "free",
/// so every build so far keeps behaving exactly as before.
const String _tier = String.fromEnvironment('TIER', defaultValue: 'free');

const bool isPro = _tier == 'pro';

const String productName = isPro ? 'Cindrix AirLink Pro' : 'Cindrix AirLink';
