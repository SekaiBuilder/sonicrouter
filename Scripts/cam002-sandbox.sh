#!/usr/bin/env bash
# CAM-002 harness: the current app with App Sandbox, ad hoc signed (no Apple
# account), plus the sandbox log and a results sheet for A01–A18.
#
#   Scripts/cam002-sandbox.sh prepare   build, sign with Config/SonicRouter-MAS.entitlements, verify
#   Scripts/cam002-sandbox.sh start     back up preferences, start logging, open the sandboxed app
#   Scripts/cam002-sandbox.sh stop      stop logging, summarize denials, check orphans, write the sheet
#   Scripts/cam002-sandbox.sh restore   put back the preferences of the normal app
#
# The sandboxed copy has the same bundle ID, so on first launch macOS moves
# ~/Library/Preferences/local.sonicrouter.app.plist into the container
# (container-migration.plist, plan A8). `start` backs it up first and
# `restore` puts it back for the normal app. Run `restore` when done.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT_DIR/build/sandbox"
APP="$WORK/SonicRouter.app"
DOMAIN="local.sonicrouter.app"
PREFS="$HOME/Library/Preferences/$DOMAIN.plist"
BACKUP="$WORK/preferences-backup.plist"
STAMP="$(date +%Y%m%d-%H%M%S)"

prepare() {
  SONICROUTER_UNIVERSAL=0 "$ROOT_DIR/Scripts/build-app.sh" >/dev/null
  rm -rf "$APP"
  mkdir -p "$WORK"
  cp -R "$ROOT_DIR/build/SonicRouter.app" "$APP"
  codesign --force --options runtime --sign - \
    --entitlements "$ROOT_DIR/Config/SonicRouter-MAS.entitlements" "$APP"
  "$ROOT_DIR/Scripts/verify-app.sh" "$APP" --arm64-only
  codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q app-sandbox \
    && echo "OK    App Sandbox en la firma" || { echo "FALLA sin App Sandbox"; exit 1; }
  echo "Listo: $APP"
}

start() {
  [[ -d "$APP" ]] || prepare
  if pgrep -x SonicRouter >/dev/null; then
    echo "Cierra antes la SonicRouter normal (solo puede haber una)."; exit 1
  fi
  if [[ -f "$PREFS" && ! -f "$BACKUP" ]]; then
    defaults export "$DOMAIN" "$BACKUP"
    echo "Preferencias guardadas en $BACKUP"
  fi
  local log="$WORK/sandbox-$STAMP.log"
  log stream --style compact --level info --predicate \
    '(sender == "Sandbox" AND eventMessage CONTAINS "SonicRouter") OR subsystem == "local.sonicrouter.app" OR (process == "tccd" AND eventMessage CONTAINS "sonicrouter")' \
    > "$log" 2>&1 &
  echo $! > "$WORK/log.pid"
  echo "$log" > "$WORK/log.path"
  sleep 1
  open "$APP"
  cat <<TEXT
Registrando en $log
Recorre los casos A01–A18 de specs/changes/CAM-002-prueba-app-sandbox.md.
Para A17: kill -9 \$(pgrep -x SonicRouter), vuelve a abrir la app y ciérrala.
Al terminar: Scripts/cam002-sandbox.sh stop
TEXT
}

stop() {
  if [[ -f "$WORK/log.pid" ]]; then
    kill "$(cat "$WORK/log.pid")" 2>/dev/null || true
    rm -f "$WORK/log.pid"
  fi
  local log
  log="$(cat "$WORK/log.path" 2>/dev/null || true)"
  [[ -n "$log" && -f "$log" ]] || { echo "No hay registro; ¿ejecutaste start?"; exit 1; }
  local sheet="$WORK/resultados-$STAMP.md"
  {
    echo "# CAM-002 — resultados del $(date '+%Y-%m-%d %H:%M')"
    echo
    echo "Entorno: macOS $(sw_vers -productVersion), $(uname -m), commit $(git -C "$ROOT_DIR" rev-parse --short HEAD), firma ad hoc con Config/SonicRouter-MAS.entitlements."
    echo
    echo "## Denegaciones del sandbox (únicas)"
    echo
    echo '```'
    grep -E 'deny\(' "$log" | sed -E 's/^.*(deny\([0-9]+\) [^ ]+ ?[^ ]*).*$/\1/' | sort | uniq -c | sort -rn | head -50 || true
    echo '```'
    echo
    echo "## Errores de SonicRouter"
    echo
    echo '```'
    grep -iE 'error|failed|unavailable|unsupported' "$log" | grep -v 'deny(' | tail -40 || true
    echo '```'
    echo
    echo "## Objetos huérfanos (A17)"
    echo
    echo '```'
    (cd "$ROOT_DIR" && swift run -c release SonicRouterAudioTools orphans 2>/dev/null) || true
    echo '```'
    echo
    echo "## Casos"
    echo
    echo "| ID | Resultado (C / X / R) | Nota, mensaje o código de Core Audio |"
    echo "|---|---|---|"
    for n in $(seq -w 1 18); do echo "| CAM-002-A$n | | |"; done
  } > "$sheet"
  echo "Hoja de resultados: $sheet"
  echo "Registro completo: $log"
  echo "Cuando acabes con la app con sandbox: Scripts/cam002-sandbox.sh restore"
}

restore() {
  if pgrep -x SonicRouter >/dev/null; then echo "Cierra SonicRouter primero."; exit 1; fi
  if [[ -f "$BACKUP" ]]; then
    defaults import "$DOMAIN" "$BACKUP"
    mv "$BACKUP" "$WORK/preferences-restored-$STAMP.plist"
    echo "Preferencias de la app normal restauradas."
  else
    echo "No hay copia de preferencias que restaurar."
  fi
  echo "El contenedor ~/Library/Containers/$DOMAIN se deja como evidencia; bórralo a mano si quieres."
}

case "${1:-}" in
  prepare) prepare ;;
  start) start ;;
  stop) stop ;;
  restore) restore ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
