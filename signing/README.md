# Android signing key (private repo only)

`airlink.jks` is the fixed key every Cindrix AirLink APK is signed with, so new builds install over old ones
and keep their data. `key.properties` holds its password.

- Keep this repository **private**. If it is ever made public, this key must be treated as compromised:
  the build workflow only uses it while the repository is private (otherwise it falls back to a throwaway key).
- Keep an offline copy of this folder. If the key is lost, installed copies can no longer be updated in place.
- Repository secrets `ANDROID_KEYSTORE_BASE64` + `ANDROID_KEY_PASSWORD` override this key when set.
