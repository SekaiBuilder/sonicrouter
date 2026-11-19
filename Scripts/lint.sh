#!/usr/bin/env bash
# Swift lint with the swift-format that ships with the toolchain (.swift-format).
# Check only, never rewrites (decision of 2026-11-19):
#   - rule findings (semicolons, force unwrap rules enabled in the config, …)
#     fail everywhere;
#   - layout findings (indentation, line breaks, spacing, line length,
#     trailing commas) fail only in files listed in STRICT_LAYOUT, written
#     after the config existed; in the rest they are only counted, so old
#     code is not reformatted.
# C/C++ is not linted (clang-format is not installed; same decision).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LAYOUT='\[(Indentation|AddLines|RemoveLine|Spacing|LineLength|TrailingComma)\]'
STRICT_LAYOUT=(
  Tests/SonicRouterNullTest/main.swift
  Tests/SonicRouterNullTest/Analysis.swift
  Tests/SonicRouterAudioTools
  Sources/SonicRouterCore/PreferenceMigration.swift
)

output="$(swift format lint --recursive Sources Tests 2>&1 | grep -v ': note:' || true)"
rules="$(echo "$output" | grep -E 'warning:|error:' | grep -vE "$LAYOUT" || true)"
layout="$(echo "$output" | grep -E "$LAYOUT" || true)"
strict=""
for path in "${STRICT_LAYOUT[@]}"; do
  strict+="$(echo "$layout" | grep -F "$path" || true)"
done

failed=0
if [[ -n "$rules" ]]; then
  echo "FALLA: reglas de swift-format:"; echo "$rules"; failed=1
fi
if [[ -n "$strict" ]]; then
  echo "FALLA: formato en archivos nuevos (arreglar con: swift format format -i <archivo>):"; echo "$strict"; failed=1
fi
echo "Formato heredado sin aplicar: $(echo "$layout" | grep -c . || true) avisos (solo informativo)."
[[ "$failed" == 0 ]] && echo "Lint: OK."
exit "$failed"
