#!/usr/bin/env bash
# Checks a built SonicRouter.app before testing, CAM-002 or upload.
#   Scripts/verify-app.sh [path/to/SonicRouter.app] [--arm64-only] [--store]
#     --arm64-only  accept a single-architecture build (SONICROUTER_UNIVERSAL=0)
#     --store       also require the store signature: entitlements equal to
#                   Config/SonicRouter-MAS.entitlements, Hardened Runtime, no ad hoc
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/build/SonicRouter.app"
EXPECT_ARCHS="arm64 x86_64"
STORE=0
for argument in "$@"; do
  case "$argument" in
    --arm64-only) EXPECT_ARCHS="arm64" ;;
    --store) STORE=1 ;;
    -*) echo "Opción desconocida: $argument" >&2; exit 2 ;;
    *) APP="$argument" ;;
  esac
done

FAILURES=0
ok() { echo "OK    $1"; }
bad() { echo "FALLA $1"; FAILURES=$((FAILURES + 1)); }

CONTENTS="$APP/Contents"
PLIST="$CONTENTS/Info.plist"
BINARY="$CONTENTS/MacOS/SonicRouter"
PRIVACY="$CONTENTS/Resources/PrivacyInfo.xcprivacy"
[[ -d "$APP" ]] || { echo "No existe $APP" >&2; exit 2; }

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# Info.plist
if plutil -lint -s "$PLIST"; then ok "Info.plist válido"; else bad "Info.plist no es un plist válido"; fi
for key in CFBundleIdentifier CFBundleExecutable CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion NSAudioCaptureUsageDescription; do
  value="$(plist_value "$PLIST" "$key")"
  if [[ -n "$value" ]]; then ok "Info.plist $key = $value"; else bad "Info.plist sin $key"; fi
done
for language in es en ja; do
  strings="$CONTENTS/Resources/$language.lproj/InfoPlist.strings"
  if [[ -f "$strings" ]] && plutil -lint -s "$strings" && grep -q NSAudioCaptureUsageDescription "$strings"; then
    ok "texto del permiso de captura en $language"
  else
    bad "falta o no es válido $language.lproj/InfoPlist.strings con NSAudioCaptureUsageDescription"
  fi
done
[[ -f "$CONTENTS/Resources/AppIcon.icns" ]] && ok "icono" || bad "falta AppIcon.icns"

# Privacy manifest (SEG-01-R03)
if [[ -f "$PRIVACY" ]] && plutil -lint -s "$PRIVACY"; then
  ok "PrivacyInfo.xcprivacy válido"
  [[ "$(plist_value "$PRIVACY" NSPrivacyTracking)" == "false" ]] && ok "sin rastreo" || bad "NSPrivacyTracking no es false"
  collected="$(plutil -extract NSPrivacyCollectedDataTypes raw "$PRIVACY" 2>/dev/null)"
  [[ "$collected" == "0" ]] && ok "ningún dato recogido" || bad "NSPrivacyCollectedDataTypes no está vacío ($collected)"
  if plutil -convert xml1 -o - "$PRIVACY" | grep -A3 NSPrivacyAccessedAPICategoryUserDefaults | grep -q CA92.1; then
    ok "UserDefaults declarado (CA92.1)"
  else
    bad "UserDefaults sin declarar con CA92.1"
  fi
  if grep -rqE 'UserDefaults' "$ROOT_DIR/Sources" && ! grep -q NSPrivacyAccessedAPICategoryUserDefaults "$PRIVACY"; then
    bad "Sources/ usa UserDefaults y el manifiesto no lo declara"
  fi
else
  bad "falta o no es válido PrivacyInfo.xcprivacy"
fi

# Architectures
archs="$(lipo -archs "$BINARY" 2>/dev/null | tr ' ' '\n' | sort | xargs)"
want="$(echo "$EXPECT_ARCHS" | tr ' ' '\n' | sort | xargs)"
[[ "$archs" == "$want" ]] && ok "arquitecturas: $archs" || bad "arquitecturas «$archs», se esperaba «$want»"
minos="$(otool -l "$BINARY" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
plist_min="$(plist_value "$PLIST" LSMinimumSystemVersion)"
[[ -n "$minos" && "${plist_min%%.*}" == "${minos%%.*}" ]] && ok "macOS mínimo: binario $minos, Info.plist $plist_min" \
  || bad "macOS mínimo distinto: binario $minos, Info.plist $plist_min"

# Signature
if codesign --verify --strict --deep "$APP" 2>/dev/null; then ok "firma válida (strict)"; else bad "firma no válida"; fi
signature="$(codesign -dvv "$APP" 2>&1)"
entitlements="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
if [[ "$STORE" == 1 ]]; then
  echo "$signature" | grep -q 'Signature=adhoc' && bad "firma ad hoc: no vale para la tienda" || ok "firma con identidad"
  echo "$signature" | grep -qE 'flags=.*runtime' && ok "Hardened Runtime" || bad "sin Hardened Runtime"
  expected="$(plutil -convert json -o - "$ROOT_DIR/Config/SonicRouter-MAS.entitlements" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))')"
  actual="$(echo "$entitlements" | plutil -convert json -o - - 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in ("com.apple.application-identifier","com.apple.developer.team-identifier"): d.pop(k,None)
print(json.dumps(d,sort_keys=True))' 2>/dev/null)"
  [[ "$expected" == "$actual" ]] && ok "entitlements iguales a Config/SonicRouter-MAS.entitlements" \
    || bad "entitlements distintos. Esperados: $expected. Firmados: ${actual:-ninguno}"
else
  echo "$signature" | grep -q 'Signature=adhoc' && echo "INFO  firma ad hoc (desarrollo)"
  [[ -n "$entitlements" ]] && echo "INFO  entitlements firmados: $(echo "$entitlements" | plutil -convert json -o - - 2>/dev/null)" \
    || echo "INFO  sin entitlements (build de desarrollo sin sandbox)"
fi

# Nothing that should not ship
stray="$(find "$APP" \( -name '*.dSYM' -o -name '.DS_Store' -o -name '*.swiftmodule' \) 2>/dev/null)"
[[ -z "$stray" ]] && ok "sin archivos de depuración sueltos" || bad "archivos que no deben ir en el paquete: $stray"

echo
if [[ "$FAILURES" == 0 ]]; then echo "Paquete correcto."; exit 0; fi
echo "$FAILURES comprobaciones fallan."; exit 1
