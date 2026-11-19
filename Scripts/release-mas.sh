#!/usr/bin/env bash
# Mac App Store build: signed .app with the store entitlements and profile,
# installer package, verification and (with --upload) upload to App Store
# Connect. Skeleton until the Apple account is active (plan B2): every account
# value comes from Config/Signing.xcconfig, nothing is stored here.
#
#   Scripts/release-mas.sh [--upload]
#
# Needs: SIGNING_DEVELOPMENT_TEAM, PRODUCT_BUNDLE_IDENTIFIER, MARKETING_VERSION,
# CURRENT_PROJECT_VERSION, CODE_SIGN_IDENTITY_MAS, INSTALLER_IDENTITY_MAS,
# PROVISIONING_PROFILE_MAS (path to the .provisionprofile) and, for --upload,
# ASC_KEYCHAIN_PROFILE or an App Store Connect API key in the environment.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/release-common.sh"

UPLOAD=0
[[ "${1:-}" == "--upload" ]] && UPLOAD=1

load_signing
require DEVELOPMENT_TEAM PRODUCT_BUNDLE_IDENTIFIER MARKETING_VERSION CURRENT_PROJECT_VERSION \
  CODE_SIGN_IDENTITY_MAS INSTALLER_IDENTITY_MAS PROVISIONING_PROFILE_MAS
require_identity "$SIGNING_CODE_SIGN_IDENTITY_MAS"
require_identity "$SIGNING_INSTALLER_IDENTITY_MAS"

# The profile must belong to this team and bundle ID.
profile_plist="$(security cms -D -i "$SIGNING_PROVISIONING_PROFILE_MAS")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' /dev/stdin <<<"$profile_plist")"
if [[ "$profile_app_id" != "$SIGNING_DEVELOPMENT_TEAM.$SIGNING_PRODUCT_BUNDLE_IDENTIFIER" ]]; then
  echo "El perfil es de «$profile_app_id», no de $SIGNING_DEVELOPMENT_TEAM.$SIGNING_PRODUCT_BUNDLE_IDENTIFIER" >&2
  exit 2
fi

# Store entitlements = Config/SonicRouter-MAS.entitlements + team and app ID.
OUT="$ROOT_DIR/build/release-mas"
rm -rf "$OUT" && mkdir -p "$OUT"
ENTITLEMENTS="$OUT/SonicRouter.entitlements"
cp "$ROOT_DIR/Config/SonicRouter-MAS.entitlements" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $SIGNING_DEVELOPMENT_TEAM.$SIGNING_PRODUCT_BUNDLE_IDENTIFIER" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $SIGNING_DEVELOPMENT_TEAM" "$ENTITLEMENTS"

SONICROUTER_BUNDLE_ID="$SIGNING_PRODUCT_BUNDLE_IDENTIFIER" \
SONICROUTER_VERSION="$SIGNING_MARKETING_VERSION" \
SONICROUTER_BUILD="$SIGNING_CURRENT_PROJECT_VERSION" \
SONICROUTER_ENTITLEMENTS="$ENTITLEMENTS" \
SONICROUTER_PROVISIONING_PROFILE="$SIGNING_PROVISIONING_PROFILE_MAS" \
CODE_SIGN_IDENTITY="$SIGNING_CODE_SIGN_IDENTITY_MAS" \
  "$ROOT_DIR/Scripts/build-app.sh" >/dev/null
cp -R "$ROOT_DIR/build/SonicRouter.app" "$OUT/"
"$ROOT_DIR/Scripts/verify-app.sh" "$OUT/SonicRouter.app" --store

PKG="$OUT/SonicRouter-$SIGNING_MARKETING_VERSION-$SIGNING_CURRENT_PROJECT_VERSION.pkg"
productbuild --component "$OUT/SonicRouter.app" /Applications --sign "$SIGNING_INSTALLER_IDENTITY_MAS" "$PKG"
pkgutil --check-signature "$PKG"
echo "Paquete: $PKG"

if [[ "$UPLOAD" == 1 ]]; then
  # altool still validates and uploads macOS packages; Transporter is the
  # graphical alternative. Credentials only from the keychain profile.
  xcrun altool --validate-app -f "$PKG" -t macos --keychain-profile "${SIGNING_ASC_KEYCHAIN_PROFILE:?Falta ASC_KEYCHAIN_PROFILE}"
  xcrun altool --upload-app -f "$PKG" -t macos --keychain-profile "$SIGNING_ASC_KEYCHAIN_PROFILE"
fi
