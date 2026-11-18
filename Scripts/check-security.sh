#!/usr/bin/env bash
# SEG-01-R05: fails if Sources/ uses the network, or if the audio modules
# write files. Static check (text search), so it also runs in CI without audio.
#   Scripts/check-security.sh [root]     check a tree (default: the repo)
#   Scripts/check-security.sh --selftest prove the check catches violations
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Network: any of these anywhere in Sources/ is a failure.
NETWORK_PATTERN='^[[:space:]]*import[[:space:]]+(Network|CFNetwork)\b|URLSession|NSURLConnection|NWConnection|NWListener|NWBrowser|CFSocket|CFStream|socket\(|getaddrinfo|WKWebView|import[[:space:]]+WebKit'
# File writes: forbidden in the audio modules (the engine must never record).
WRITE_PATTERN='\.write\(to:|FileHandle\(forWriting|FileHandle\(forUpdating|createFile\(atPath|FileManager\.default\.(copyItem|moveItem)|fopen\(|fwrite\(|open\([^)]*O_(WRONLY|RDWR|CREAT)|std::ofstream|std::fstream|ExtAudioFile|AudioFileCreate|AudioFileOpen|AVAudioFile|AVAudioRecorder|AVAssetWriter'

audio_files() {
  local root="$1"
  find "$root/Sources/SonicRouterDSP" "$root/Sources/SonicRouterCore" -type f \( -name '*.swift' -o -name '*.cpp' -o -name '*.h' -o -name '*.c' \) 2>/dev/null
  find "$root/Sources/SonicRouter" -type f \( -name 'AudioProcessTap.swift' -o -name 'CoreAudio*.swift' -o -name 'AudioDevice*.swift' -o -name 'MultiOutput*.swift' \) 2>/dev/null
}

check_tree() {
  local root="$1" failed=0
  if [[ ! -d "$root/Sources" ]]; then
    echo "No existe $root/Sources" >&2
    return 2
  fi
  local hits
  hits="$(grep -rnE --include='*.swift' --include='*.c' --include='*.cpp' --include='*.h' --include='*.m' \
    "$NETWORK_PATTERN" "$root/Sources" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
  if [[ -n "$hits" ]]; then
    echo "FALLA SEG-01-R05: uso de red en Sources/:"
    echo "$hits"
    failed=1
  fi
  local files
  files="$(audio_files "$root")"
  if [[ -n "$files" ]]; then
    # shellcheck disable=SC2086
    hits="$(grep -nHE "$WRITE_PATTERN" $files | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
    if [[ -n "$hits" ]]; then
      echo "FALLA SEG-01-R05: escritura de archivos en el módulo de audio:"
      echo "$hits"
      failed=1
    fi
  fi
  if [[ "$failed" == 0 ]]; then
    echo "SEG-01-R05: sin red en Sources/ y sin escritura de archivos en el audio ($(echo "$files" | grep -c .) archivos de audio revisados)."
  fi
  return "$failed"
}

selftest() {
  local tmp failures=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/Sources/SonicRouterCore" "$tmp/Sources/SonicRouter" "$tmp/Sources/SonicRouterDSP"
  expect() {
    local name="$1" want="$2" got=0
    check_tree "$tmp" >/dev/null 2>&1 || got=$?
    if [[ "$got" == "$want" ]]; then echo "OK    $name"; else echo "FALLA $name (salida $got, esperada $want)"; failures=$((failures + 1)); fi
  }
  echo 'let x = 1' > "$tmp/Sources/SonicRouterCore/A.swift"
  expect "árbol limpio pasa" 0
  echo '// URLSession only in a comment' > "$tmp/Sources/SonicRouter/C.swift"
  expect "comentario no cuenta" 0
  echo 'import Network' > "$tmp/Sources/SonicRouter/N.swift"
  expect "import Network falla" 1
  rm "$tmp/Sources/SonicRouter/N.swift"
  echo 'let s = URLSession.shared' > "$tmp/Sources/SonicRouter/U.swift"
  expect "URLSession falla" 1
  rm "$tmp/Sources/SonicRouter/U.swift"
  echo 'try data.write(to: url)' > "$tmp/Sources/SonicRouter/ProfilesView.swift"
  expect "escritura fuera del audio se permite (exportar perfiles)" 0
  echo 'try data.write(to: url)' > "$tmp/Sources/SonicRouter/AudioProcessTap.swift"
  expect "escritura en AudioProcessTap falla" 1
  rm "$tmp/Sources/SonicRouter/AudioProcessTap.swift"
  echo 'FILE* f = fopen("x", "w");' > "$tmp/Sources/SonicRouterDSP/D.cpp"
  expect "fopen en el núcleo C++ falla" 1
  rm "$tmp/Sources/SonicRouterDSP/D.cpp"
  echo 'ExtAudioFileCreateWithURL(u, 0, &f, nil, 0, &r)' > "$tmp/Sources/SonicRouterCore/R.swift"
  expect "grabar audio en el núcleo falla" 1
  if [[ "$failures" == 0 ]]; then echo "Autoprueba: todo pasa."; else echo "Autoprueba: $failures fallos."; fi
  return "$failures"
}

if [[ "${1:-}" == "--selftest" ]]; then
  selftest
else
  check_tree "${1:-$ROOT_DIR}"
fi
