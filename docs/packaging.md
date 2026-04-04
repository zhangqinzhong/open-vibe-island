# Packaging

This repository can now produce a local macOS app bundle from the Swift package without requiring an Xcode project archive.

## Current Shape

- `zsh scripts/package-app.sh` builds `OpenIslandApp`, `OpenIslandHooks`, and `OpenIslandSetup` in release mode.
- The script creates `output/package/Open Island.app`.
- The bundle embeds helper binaries inside `Contents/Helpers/` so the app can still locate `OpenIslandHooks` after it leaves the repository checkout.
- The script also creates `output/package/Open Island.zip` for local sharing or later notarization.

## Unsigned First

If the machine does not yet have a `Developer ID Application` certificate, the script still works. It produces an unsigned `.app` bundle and `.zip` archive for local inspection.

Check whether signing identities are available with:

```bash
security find-identity -v -p codesigning
```

If that command reports `0 valid identities found`, packaging is limited to unsigned output until the certificate is created in the Apple Developer account and imported into the login keychain.

## Signing And Notarization

When a signing identity is available, pass it in with environment variables:

```bash
OPEN_ISLAND_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
zsh scripts/package-app.sh
```

The script signs the helper binaries first, then signs the app bundle with the Apple Events entitlement declared in `config/packaging/OpenIslandApp.entitlements`.

If a `notarytool` keychain profile is already stored, the same script can also notarize and staple:

```bash
OPEN_ISLAND_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
OPEN_ISLAND_NOTARY_PROFILE="open-island-notary" \
zsh scripts/package-app.sh
```

That path expects `xcrun notarytool store-credentials` to have been run ahead of time.

## Optional Overrides

The script accepts these environment variables:

- `OPEN_ISLAND_APP_NAME`
- `OPEN_ISLAND_BUNDLE_ID`
- `OPEN_ISLAND_VERSION`
- `OPEN_ISLAND_BUILD_NUMBER`
- `OPEN_ISLAND_PACKAGE_ROOT`
- `OPEN_ISLAND_BUNDLE_DIR`
- `OPEN_ISLAND_ZIP_PATH`
- `OPEN_ISLAND_SIGN_IDENTITY`
- `OPEN_ISLAND_NOTARY_PROFILE`
