#!/usr/bin/env bash
# KiCad electrical / design rule checks for every project under hardware/.
#
# For each hardware/**/<name>.kicad_pro:
#   - ERC on <name>.kicad_sch (the root sheet)
#   - DRC on <name>.kicad_pcb, if the board exists, including schematic
#     parity (board and schematic agree)
# Any error or warning fails the run. Reports go to build/kicad-reports/.
#
# Local use (Git Bash), from the repo root:
#   KICAD_CLI="/c/Program Files/KiCad/10.0/bin/kicad-cli.exe" scripts/kicad_check.sh
# CI: .github/workflows/kicad-checks.yml (kicad-cli is on PATH in the image).
set -u

cli="${KICAD_CLI:-kicad-cli}"
out="build/kicad-reports"
mkdir -p "$out"
fail=0

"$cli" version

while IFS= read -r pro; do
    dir=$(dirname "$pro")
    name=$(basename "$pro" .kicad_pro)
    sch="$dir/$name.kicad_sch"
    pcb="$dir/$name.kicad_pcb"

    echo "=== ERC: $sch"
    if ! "$cli" sch erc --severity-all --exit-code-violations \
        -o "$out/$name.erc.rpt" "$sch"; then
        cat "$out/$name.erc.rpt"
        fail=1
    fi

    if [ -f "$pcb" ]; then
        echo "=== DRC: $pcb"
        if ! "$cli" pcb drc --severity-all --schematic-parity --exit-code-violations \
            -o "$out/$name.drc.rpt" "$pcb"; then
            cat "$out/$name.drc.rpt"
            fail=1
        fi
    fi
done < <(find hardware -name '*.kicad_pro' -not -path '*/.history/*' | sort)

if [ "$fail" -ne 0 ]; then
    echo "KiCad checks FAILED (reports in $out)"
else
    echo "KiCad checks passed"
fi
exit "$fail"
