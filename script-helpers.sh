#!/usr/bin/env bash

# Gemeinsame, nebenwirkungsfreie Prüfungen der Build-, Installations- und
# Release-Skripte. Diese Datei wird nur eingebunden und nicht direkt ausgeführt.

hoerbuchkloeppler_read_version() {
  local version_file="${1:-VERSION}" version
  if [[ ! -r "$version_file" ]]; then
    echo "Fehler: VERSION-Datei fehlt oder ist nicht lesbar: $version_file" >&2
    return 1
  fi
  version="$(<"$version_file")"
  if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "Fehler: ungültige App-Version in $version_file: '$version'" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

# Startzeit und vollständiges Kommando stammen bewusst aus EINEM ps-Snapshot.
# Zwei getrennte Abfragen könnten bei einer wiederverwendeten PID verschiedene
# Prozesse beobachten und damit die spätere TERM/KILL-Prüfung falsch binden.
hoerbuchkloeppler_process_snapshot() {
  local pid="$1"
  ps -ww -p "$pid" -o lstart= -o command= 2>/dev/null || true
}

hoerbuchkloeppler_snapshot_command() {
  local snapshot="$1" command_part
  # macOS ps formatiert lstart immer als 24 Zeichen, gefolgt vom Kommando.
  [ "${#snapshot}" -gt 24 ] || return 1
  command_part="${snapshot:24}"
  command_part="${command_part#"${command_part%%[![:space:]]*}"}"
  [ -n "$command_part" ] || return 1
  printf '%s\n' "$command_part"
}

hoerbuchkloeppler_snapshot_targets_executable() {
  local snapshot="$1" expected_executable="$2" process_command
  process_command="$(hoerbuchkloeppler_snapshot_command "$snapshot")" || return 1
  case "$process_command" in
    "$expected_executable"|"$expected_executable "*) return 0 ;;
    *) return 1 ;;
  esac
}

hoerbuchkloeppler_process_matches_snapshot() {
  local pid="$1" expected_snapshot="$2" expected_executable="$3" current
  current="$(hoerbuchkloeppler_process_snapshot "$pid")"
  [ -n "$current" ] \
    && [ "$current" = "$expected_snapshot" ] \
    && hoerbuchkloeppler_snapshot_targets_executable "$current" "$expected_executable"
}
