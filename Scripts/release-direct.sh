#!/usr/bin/env bash
# Direct channel (outside the store): Developer ID signature, Hardened Runtime,
# notarization and stapling, zip ready for a GitHub release. Skeleton until the
# Apple account is active (plan B3). Publishing the release stays manual and
# needs the owner's approval.
#
#   Scripts/release-direct.sh
#
# Needs in Config/Signing.xcconfig: PRODUCT_BUNDLE_IDENTIFIER, MARKETING_VERSION,
# CURRENT_PROJECT_VERSION, CODE_SIGN_IDENTITY_DIRECT, NOTARY_KEYCHAIN_PROFILE
# (created once with `xcrun notarytool store-credentials`).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/release-common.sh"

load_signing
require PRODUCT_BUNDLE_IDENTIFIER MARKETING_VERSION CURRENT_PROJECT_VERSION CODE_SIGN_IDENTITY_DIRECT NOTARY_KEYCHAIN_PROFILE
require_identity "$SIGNING_CODE_SIGN_IDENTITY_DIRECT"

OUT="$ROOT_DIR/build/release-direct"
rm -rf "$OUT" && mkdir -p "$OUT"
# Without sandbox entitlements: whether the direct build uses App Sandbox is
# decided after CAM-002 (docs/APP_STORE_MIGRATION.md, Canales).
SONICROUTER_BUNDLE_ID="$SIGNING_PRODUCT_BUNDLE_IDENTIFIER" \
SONICROUTER_VERSION="$SIGNING_MARKETING_VERSION" \
SONICROUTER_BUILD="$SIGNING_CURRENT_PROJECT_VERSION" \
CODE_SIGN_IDENTITY="$SIGNING_CODE_SIGN_IDENTITY_DIRECT" \
  "$ROOT_DIR/Scripts/build-app.sh" >/dev/null
cp -R "$ROOT_DIR/build/SonicRouter.app" "$OUT/"
"$ROOT_DIR/Scripts/verify-app.sh" "$OUT/SonicRouter.app"
codesign -dvv "$OUT/SonicRouter.app" 2>&1 | grep -qE 'flags=.*runtime' || { echo "Sin Hardened Runtime" >&2; exit 1; }

ZIP="$OUT/SonicRouter-$SIGNING_MARKETING_VERSION.zip"
ditto -c -k --keepParent "$OUT/SonicRouter.app" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$SIGNING_NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$OUT/SonicRouter.app"
xcrun stapler validate "$OUT/SonicRouter.app"
spctl --assess --type execute --verbose "$OUT/SonicRouter.app"
rm "$ZIP"
ditto -c -k --keepParent "$OUT/SonicRouter.app" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Listo para publicar a mano: $ZIP"
