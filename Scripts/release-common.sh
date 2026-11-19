#!/usr/bin/env bash
# Shared by the release scripts: reads Config/Signing.xcconfig (KEY = value
# lines) into SIGNING_<KEY> variables and refuses to run if that file could
# end up in git (SEG-01-R04).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_FILE="$ROOT_DIR/Config/Signing.xcconfig"

load_signing() {
  if [[ ! -f "$SIGNING_FILE" ]]; then
    echo "Falta Config/Signing.xcconfig: copia Config/Signing.xcconfig.example y rellénalo." >&2
    exit 2
  fi
  if ! git -C "$ROOT_DIR" check-ignore -q "$SIGNING_FILE"; then
    echo "Config/Signing.xcconfig no está en .gitignore (plan B6): no sigo, para no subir datos de la cuenta." >&2
    exit 2
  fi
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]] || continue
    printf -v "SIGNING_${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]:-}"
  done < <(grep -v '^[[:space:]]*//' "$SIGNING_FILE")
}

require() {
  local missing=0
  for name in "$@"; do
    local variable="SIGNING_$name"
    if [[ -z "${!variable:-}" ]]; then echo "Falta $name en Config/Signing.xcconfig" >&2; missing=1; fi
  done
  [[ "$missing" == 0 ]] || exit 2
}

require_identity() {
  if ! security find-identity -v -p codesigning | grep -qF "$1" \
    && ! security find-identity -v | grep -qF "$1"; then
    echo "No hay en el llavero una identidad «$1» (paso C4 de docs/APP_STORE_MIGRATION.md)." >&2
    exit 2
  fi
}
