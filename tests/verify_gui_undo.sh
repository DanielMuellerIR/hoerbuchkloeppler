#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --package-path HoerbuchkloepplerCore
binary_dir="$(swift build --package-path HoerbuchkloepplerCore --show-bin-path)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoerbuchkloeppler-undo.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# Swift Build liefert eine statische Library; ältere SwiftPM-Versionen legen
# die einzelnen Objektdateien neben dem Modules-Verzeichnis ab.
if [ -f "$binary_dir/libHoerbuchkloepplerCore.a" ]; then
    core_args=(-I "$binary_dir" -L "$binary_dir" -lHoerbuchkloepplerCore)
else
    core_args=(-I "$binary_dir/Modules" "$binary_dir/HoerbuchkloepplerCore.build/"*.swift.o)
fi
swiftc -swift-version 6 -warnings-as-errors -parse-as-library "${core_args[@]}" \
    Hörbuchklöppler/ChapterUndoRouter.swift tests/verify_gui_undo.swift \
    -o "$work_dir/verify-gui-undo"
"$work_dir/verify-gui-undo"
