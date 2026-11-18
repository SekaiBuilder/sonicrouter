#!/usr/bin/env bash
# Everything CI checks, runnable locally the same way: Scripts/ci.sh
# No audio hardware, no permissions, no signing identity needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

step() { printf '\n== %s ==\n' "$1"; }

step "Specs sin deriva (sdd-deriva --estricto)"
python3 Scripts/sdd-deriva.py . --estricto | tail -n 1

step "Sin red ni escritura en el audio (SEG-01-R05)"
Scripts/check-security.sh --selftest
Scripts/check-security.sh

step "Compilación estricta"
swift build -Xswiftc -warnings-as-errors

step "Pruebas (debug)"
Scripts/test.sh

step "Pruebas (release, igualdad bit a bit con optimización)"
swift run -c release SonicRouterPolicyTests

step "Pruebas con ASan y UBSan"
swift run --sanitize=address --sanitize=undefined SonicRouterPolicyTests

step "Autoprueba del análisis de la prueba nula"
swift run -c release SonicRouterNullTest --selftest

step "Paquete universal y verificación"
Scripts/build-app.sh >/dev/null
Scripts/verify-app.sh

printf '\nCI local: todo pasa.\n'
