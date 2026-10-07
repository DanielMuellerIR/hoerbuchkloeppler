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
invalid_empty="$work_dir/version-empty"
invalid_suffix="$work_dir/version-suffix"
invalid_path="$work_dir/version-path"
# Syntaxprüfung aller Root-Shell-Skripte. Ergänzende Verhaltensprüfungen stehen
# nach den gemeinsamen Versions- und Prozessidentitätsprüfungen.
for script_path in ./*.sh; do
  [ -f "$script_path" ] || continue
  script="${script_path#./}"
  if [ ! -r "$script" ]; then
    printf 'Fehler: Skript fehlt: %s\n' "$script" >&2
    exit 1
  fi
  syntax_log="$work_dir/syntax.log"
  if ! bash -n "$script" 2>"$syntax_log"; then
    printf 'Fehler: Syntaxfehler in %s:\n' "$script" >&2
    cat "$syntax_log" >&2
    rm -f "$syntax_log"
    exit 1
  fi
  rm -f "$syntax_log"
done

# Eine nackte `[ … ]`-Zeile beendet den Lauf unter `set -e` zwar korrekt, sagt
# aber nicht, welche der Prüfungen brach. Diese Hülle nennt sie.
assert_equal() {
  if [ "$1" != "$2" ]; then
    printf 'Fehler: %s (erwartet: %s, war: %s)\n' "$3" "$2" "$1" >&2
    exit 1
  fi
}

printf '1.4\n' > "$valid_two"
printf '1.4.2\n' > "$valid_three"
: > "$invalid_empty"
printf '1.4.2-beta\n' > "$invalid_suffix"
printf '../../fremd\n' > "$invalid_path"

assert_equal "$(hoerbuchkloeppler_read_version "$valid_two")" "1.4" "Zweistellige Version wurde nicht gelesen"
assert_equal "$(hoerbuchkloeppler_read_version "$valid_three")" "1.4.2" "Dreistellige Version wurde nicht gelesen"
for invalid_version in "$invalid_empty" "$invalid_suffix" "$invalid_path" "$work_dir/fehlt"; do
  if hoerbuchkloeppler_read_version "$invalid_version" >/dev/null 2>&1; then
    echo "Fehler: Ungültige oder fehlende Release-Version wurde akzeptiert: $invalid_version" >&2
    exit 1
  fi
done

# Die VERSION-Datei ist laut AGENTS.md die einzige Quelle der App-Version.
# build.sh, install.sh und release.sh stempeln sie über MARKETING_VERSION in den
# Build. Ein direkter Xcode-Build (Cmd-R) nimmt dagegen den im Projekt
# hinterlegten Wert — laufen beide auseinander, trägt genau dieser Build eine
# falsche Versionsnummer, ohne dass es irgendwo auffiele.
project_versions="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);$/\1/p' \
  "Hörbuchklöppler.xcodeproj/project.pbxproj" | sort -u)"
repo_version="$(hoerbuchkloeppler_read_version)"
if [ "$project_versions" != "$repo_version" ]; then
  echo "Fehler: MARKETING_VERSION im Xcode-Projekt ('$project_versions') weicht von VERSION ('$repo_version') ab." >&2
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
assert_equal "$captured" "$snapshot" "Prozess-Snapshot weicht von der ps-Ausgabe ab"
assert_equal "$(wc -l < "$ps_calls" | tr -d ' ')" "1" "Snapshot darf ps genau einmal aufrufen"
hoerbuchkloeppler_snapshot_targets_executable "$captured" "$target"

: > "$ps_calls"
hoerbuchkloeppler_process_matches_snapshot 12345 "$snapshot" "$target"
assert_equal "$(wc -l < "$ps_calls" | tr -d ' ')" "1" "Abgleich darf ps genau einmal aufrufen"
if hoerbuchkloeppler_process_matches_snapshot 12345 "$snapshot" "$target"; then
  echo "Fehler: Wiederverwendete PID mit neuer Identität wurde akzeptiert." >&2
  exit 1
fi
assert_equal "$(wc -l < "$ps_calls" | tr -d ' ')" "2" "Zweiter Abgleich muss ps erneut aufrufen"
unset -f ps

PYTHONDONTWRITEBYTECODE=1 python3 tests/verify_sign_bundle.py

echo "Shell-Sicherheitstests bestanden."
