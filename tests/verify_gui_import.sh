#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --package-path HoerbuchkloepplerCore
binary_dir="$(swift build --package-path HoerbuchkloepplerCore --show-bin-path)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoerbuchkloeppler-gui-import.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
ln -s "$binary_dir/HoerbuchkloepplerCore_HoerbuchkloepplerCore.bundle" \
    "$work_dir/HoerbuchkloepplerCore_HoerbuchkloepplerCore.bundle"
if [ -f "$binary_dir/libHoerbuchkloepplerCore.a" ]; then
    core_args=(-I "$binary_dir" -L "$binary_dir" -lHoerbuchkloepplerCore)
else
    core_args=(-I "$binary_dir/Modules" "$binary_dir/HoerbuchkloepplerCore.build/"*.swift.o)
fi
swiftc -swift-version 6 -warnings-as-errors -parse-as-library "${core_args[@]}" \
    Hörbuchklöppler/ImportCoordinator.swift tests/verify_gui_import.swift \
    -o "$work_dir/verify-gui-import"
"$work_dir/verify-gui-import" "$@"
