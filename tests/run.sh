#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1

usage() {
  cat <<'HELP'
Aufruf: tests/run.sh [--swift|--integration|--lifecycle]

Ohne Option laufen die Swift-Suiten, die CLI- und AppKit-Integration und
die Build-, Signier-, Installations- und Release-Tests. Installations-
und Release-Tests verwenden isolierte Pfade und kontrollierte Dienste.
HELP
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 64
fi
scope="${1:---all}"
case "$scope" in
  -h|--help) usage; exit 0 ;;
  --all|--swift|--integration|--lifecycle) ;;
  *) usage >&2; exit 64 ;;
esac

if [[ "$scope" != --lifecycle ]]; then
  ./build.sh --deps-only
fi
if [[ "$scope" == --all || "$scope" == --swift ]]; then
  swift_test_flags=(-Xswiftc -warnings-as-errors)
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    # Parallel laufende Prozess- und Abbruchtests überschreiten auf dem Intel-Runner ihre Fristen.
    swift_test_flags+=(--experimental-maximum-parallelization-width 1)
  fi
  verify_timeout=0
  if [[ "$scope" == --all ]]; then verify_timeout=1; fi
  HOERBUCHKLOEPPLER_VERIFY_PROVIDER_TIMEOUT="$verify_timeout" \
    swift test --package-path HoerbuchkloepplerCore "${swift_test_flags[@]}"
  swift test --package-path tools/InstallBundle -Xswiftc -warnings-as-errors
fi
if [[ "$scope" == --all || "$scope" == --integration ]]; then
  swift build --package-path HoerbuchkloepplerCore
  for test in tests/verify_cli_project.py tests/verify_cli_matrix.py \
    tests/verify_cli_terminal.py tests/verify_audio_transitions.py \
    tests/verify_terminal_renderer.py; do
    python3 "$test"
  done
  if [[ "$scope" == --integration ]]; then
    HOERBUCHKLOEPPLER_VERIFY_PROVIDER_TIMEOUT=1 \
      swift test --package-path HoerbuchkloepplerCore -Xswiftc -warnings-as-errors --filter AppSupportTests
  fi
fi
if [[ "$scope" == --all || "$scope" == --lifecycle ]]; then
  ./tests/verify_scripts.sh
fi
