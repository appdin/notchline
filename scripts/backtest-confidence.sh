#!/bin/sh
# Measures how often the planner's scores held, from Open-Meteo's archived forecasts made 0 to 3
# days ahead against SNOTEL and BC station readings, and writes the confidence table the app
# ships with. Run on demand, then commit the table.
#
# Usage: scripts/backtest-confidence.sh [cache-dir]
# The cache keeps responses between runs. The backtest uses about a quarter of Open-Meteo's free
# daily quota, and the BC archive files are over 100 MB together.
set -eu
cd "$(dirname "$0")/.."
cache="${1:-${TMPDIR:-/tmp}/notchline-backtest-cache}"
swift run -c release notchline-fetch --backtest-confidence --cache "$cache" \
    --out Sources/NotchlineCore/Resources/confidence.json
