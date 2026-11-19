#!/usr/bin/env bash
# Summarizes SonicRouter's callback timing (REN-01-R04, CAM-003 T6).
#
# 1. defaults write local.sonicrouter.app SonicRouter.RenderStats -bool YES
# 2. Restart SonicRouter, control some apps, play audio for a while.
# 3. Scripts/render-stats.sh [--last 30m]        (reads the unified log)
#    Scripts/render-stats.sh --file saved.log    (or a saved `log show` output)
# 4. defaults delete local.sonicrouter.app SonicRouter.RenderStats
#
# Budget = the audio duration of each callback (e.g. 5.33 ms for 256 frames
# at 48 kHz). Pass criterion proposed in performance.md: p99 below half the
# budget, no callback over budget, no overloads.
set -euo pipefail

LAST="30m"
FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --last) LAST="$2"; shift 2 ;;
    --file) FILE="$2"; shift 2 ;;
    *) echo "Uso: $0 [--last 30m | --file archivo]" >&2; exit 2 ;;
  esac
done

if [[ -n "$FILE" ]]; then
  INPUT="$(cat "$FILE")"
else
  INPUT="$(log show --last "$LAST" --style compact \
    --predicate 'subsystem == "local.sonicrouter.app" AND eventMessage CONTAINS "render-stats"' 2>/dev/null)"
fi

printf '%s\n' "$INPUT" | python3 -c '
import re, sys
BOUNDS = [4 << i for i in range(11)]  # µs; bucket 11 is open
engines = {}
for line in sys.stdin:
    if "render-stats" not in line:
        continue
    rest = line.split("render-stats", 1)[1]
    mode = rest.split(" mode=", 1)[1].strip() if " mode=" in rest else "?"
    fields = dict(re.findall(r"(\w+)=([^\s]+)", rest.split(" mode=", 1)[0]))
    fields["mode"] = mode
    if "buckets" not in fields:
        continue
    pid = fields.get("pid", "?")
    e = engines.setdefault(pid, {"callbacks": 0, "totalUs": 0.0, "maxUs": 0.0, "overHalf": 0,
                                 "overBudget": 0, "overloads": 0, "buckets": [0] * 12, "reports": 0,
                                 "mode": fields.get("mode", "?")})
    calls = int(fields["callbacks"])
    e["reports"] += 1
    e["callbacks"] += calls
    e["totalUs"] += calls * float(fields["meanUs"])
    e["maxUs"] = max(e["maxUs"], float(fields["maxUs"]))
    for key in ("overHalf", "overBudget", "overloads"):
        e[key] += int(fields[key])
    for i, n in enumerate(fields["buckets"].split(",")[:12]):
        e["buckets"][i] += int(n)

def percentile(buckets, fraction):
    total = sum(buckets)
    if total == 0:
        return 0
    rank = max(1, -(-int(total * fraction * 1000) // 1000))
    seen = 0
    for i, n in enumerate(buckets):
        seen += n
        if seen >= rank:
            return f"<{BOUNDS[i]}" if i < len(BOUNDS) else f">={BOUNDS[-1]}"
    return "?"

if not engines:
    print("No hay líneas render-stats. ¿Activaste SonicRouter.RenderStats y reiniciaste el motor?")
    sys.exit(1)
bad = False
for pid, e in sorted(engines.items()):
    mean = e["totalUs"] / e["callbacks"] if e["callbacks"] else 0
    p50, p99 = percentile(e["buckets"], .5), percentile(e["buckets"], .99)
    print("pid %s (%s): %d callbacks en %d informes" % (pid, e["mode"], e["callbacks"], e["reports"]))
    print("  media %.1f µs · p50 %s µs · p99 %s µs · máx %.1f µs" % (mean, p50, p99, e["maxUs"]))
    print("  > mitad del presupuesto: %d · > presupuesto: %d · sobrecargas: %d" % (e["overHalf"], e["overBudget"], e["overloads"]))
    bad = bad or e["overBudget"] > 0 or e["overloads"] > 0
print("RESULTADO:", "FALLA (callbacks fuera de tiempo o sobrecargas)" if bad else "sin callbacks fuera de tiempo ni sobrecargas")
sys.exit(1 if bad else 0)
'
