#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=script-helpers.sh
source "./script-helpers.sh"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoerbuchkloeppler-script-tests.XXXXXX")"
cleanup() {
  find "$work_dir" -depth -delete
}
trap cleanup EXIT

valid_two="$work_dir/version-two"
valid_three="$work_dir/version-three"
invalid_path="$work_dir/version-path"
printf '1.4\n' > "$valid_two"
printf '1.4.2\n' > "$valid_three"
printf '../../fremd\n' > "$invalid_path"

[ "$(hoerbuchkloeppler_read_version "$valid_two")" = "1.4" ]
[ "$(hoerbuchkloeppler_read_version "$valid_three")" = "1.4.2" ]
if hoerbuchkloeppler_read_version "$invalid_path" >/dev/null 2>&1; then
  echo "Fehler: Pfadbestandteile wurden als Release-Version akzeptiert." >&2
  exit 1
fi

start="Sun Aug 30 09:47:56 2026"
target="/Applications/Hörbuchklöppler.app/Contents/MacOS/Hörbuchklöppler"
snapshot="$start     $target --wiederherstellen"
hoerbuchkloeppler_snapshot_targets_executable "$snapshot" "$target"
if hoerbuchkloeppler_snapshot_targets_executable "$snapshot" "${target}X"; then
  echo "Fehler: Ein abweichendes Prozesskommando wurde akzeptiert." >&2
  exit 1
fi

# Eine Probe darf genau einen ps-Aufruf ausführen. Die Attrappe liefert bei
# einem zweiten Aufruf absichtlich eine fremde Identität; der Zähler belegt,
# dass Registrierung und Kommando aus demselben Snapshot stammen.
ps_calls="$work_dir/ps-calls"
: > "$ps_calls"
ps() {
  printf 'x\n' >> "$ps_calls"
  if [ "$(wc -l < "$ps_calls" | tr -d ' ')" -eq 1 ]; then
    printf '%s\n' "$snapshot"
  else
    printf '%s     /tmp/fremder-prozess\n' "$start"
  fi
}
captured="$(hoerbuchkloeppler_process_snapshot 12345)"
[ "$captured" = "$snapshot" ]
[ "$(wc -l < "$ps_calls" | tr -d ' ')" -eq 1 ]
hoerbuchkloeppler_snapshot_targets_executable "$captured" "$target"

: > "$ps_calls"
hoerbuchkloeppler_process_matches_snapshot 12345 "$snapshot" "$target"
[ "$(wc -l < "$ps_calls" | tr -d ' ')" -eq 1 ]
unset -f ps

echo "Shell-Sicherheitstests bestanden."
