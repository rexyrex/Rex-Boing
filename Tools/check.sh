#!/bin/bash
# Compiles and runs the headless checks in Tools/ against the app sources.
# None of them need the app to be running or a menu bar to be visible.
#
#   Tools/check.sh                run every check
#   Tools/check.sh visual ink     run only the named checks
#   Tools/check.sh --pure         run only the checks that never read live
#                                 hardware (what CI runs)
#
#   visual   the CALayer drawing path draws every rex pixel-identically to a
#            direct render, flipped and unflipped
#   ink      the load colour ramp holds the label colour to the threshold and
#            walks orange → red without a step or a grey
#   readout  every menu bar caption fits the column it was measured for
#   clock    history buffers, process history and the usage ledger against a
#            synthetic timeline
#   ledger   the usage ledger's accounting, then one live pass through the
#            real process sampler, then micro-benchmarks
#   metrics  every sampler against this machine: availability, finiteness,
#            ranges and related counts (readings differ per Mac by design)
#   engine   the full engine against live samplers, without a status item
#            and without touching preferences
set -euo pipefail
cd "$(dirname "$0")/.."

PURE=(visual ink readout clock)
LIVE=(ledger metrics engine)

if [ $# -eq 0 ]; then
    CHECKS=("${PURE[@]}" "${LIVE[@]}")
elif [ "$1" = "--pure" ]; then
    CHECKS=("${PURE[@]}")
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,22p' "$0"
    exit 0
else
    CHECKS=("$@")
fi

OUT=.build/checks
mkdir -p "$OUT"

# Every check links against the same frameworks; the unused ones cost nothing.
FRAMEWORKS=(-framework AppKit -framework IOKit -framework SystemConfiguration
            -framework ServiceManagement -framework QuartzCore)

sources_for() {
    case "$1" in
        visual)
            echo RexBoing/StatusBar/Visualizer.swift RexBoing/StatusBar/VisualCanvas.swift ;;
        ink)
            echo RexBoing/UI/Theme.swift RexBoing/Metrics/Snapshot.swift \
                 RexBoing/Metrics/Format.swift ;;
        readout)
            echo RexBoing/StatusBar/StatusBarRenderer.swift RexBoing/App/Preferences.swift \
                 RexBoing/StatusBar/Visualizer.swift RexBoing/App/LoginItem.swift \
                 RexBoing/Metrics/Format.swift ;;
        clock)
            echo RexBoing/Metrics/Snapshot.swift RexBoing/Metrics/Format.swift \
                 RexBoing/Metrics/History.swift RexBoing/Metrics/ProcessHistory.swift \
                 RexBoing/Metrics/UsageLedger.swift ;;
        ledger)
            echo RexBoing/Metrics/Snapshot.swift RexBoing/Metrics/Format.swift \
                 RexBoing/Metrics/UsageLedger.swift \
                 RexBoing/Metrics/Samplers/ProcessSampler.swift ;;
        metrics)
            echo RexBoing/Metrics/Snapshot.swift RexBoing/Metrics/Format.swift \
                 RexBoing/Metrics/UsageLedger.swift RexBoing/Metrics/Samplers/*.swift ;;
        engine)
            find RexBoing -name '*.swift' ! -name RexBoingApp.swift | sort | tr '\n' ' ' ;;
        *)
            echo "Unknown check: $1 (valid: ${PURE[*]} ${LIVE[*]})" >&2
            exit 2 ;;
    esac
}

failed=()
for name in "${CHECKS[@]}"; do
    # shellcheck disable=SC2207
    sources=($(sources_for "$name"))
    echo
    echo "==> $name-check"
    if swiftc -O "${FRAMEWORKS[@]}" -o "$OUT/$name-check" "Tools/$name-check.swift" "${sources[@]}" \
        && "$OUT/$name-check"; then
        echo "==> $name-check: PASS"
    else
        echo "==> $name-check: FAIL"
        failed+=("$name")
    fi
done

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "All ${#CHECKS[@]} check(s) passed."
else
    echo "FAILED: ${failed[*]}"
    exit 1
fi
