#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --package-path HoerbuchkloepplerCore -Xswiftc -warnings-as-errors
binary_dir="$(swift build --package-path HoerbuchkloepplerCore --show-bin-path)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoerbuchkloeppler-artwork.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
ln -s "$binary_dir/HoerbuchkloepplerCore_HoerbuchkloepplerCore.bundle" \
    "$work_dir/HoerbuchkloepplerCore_HoerbuchkloepplerCore.bundle"
if [ -f "$binary_dir/libHoerbuchkloepplerCore.a" ]; then
    core_args=(-I "$binary_dir" -L "$binary_dir" -lHoerbuchkloepplerCore)
else
    core_args=(-I "$binary_dir/Modules" "$binary_dir/HoerbuchkloepplerCore.build/"*.swift.o)
fi
python3 tests/generate_artwork_fixtures.py "$work_dir/fixtures" \
    HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg
swiftc -swift-version 6 -warnings-as-errors -parse-as-library "${core_args[@]}" \
    tests/verify_artwork.swift -o "$work_dir/verify-artwork"
for mode in baseline-preview baseline-embedded verify embedded-limit; do
    "$work_dir/verify-artwork" "$mode" "$work_dir/fixtures"
done
