#!/usr/bin/env bash
#
# build.sh — Hörbuchklöppler bauen.
#
# Lädt die externen Binaries (ffmpeg, mediainfo) vom offiziellen Upstream — sie
# liegen bewusst NICHT im Repo (ffmpeg ist GPL + ~76 MB, siehe docs/dependencies.md)
# — und baut anschließend Core/CLI (Swift Package) sowie die SwiftUI-App. Die
# fertige `.app` landet zum bequemen Testen im Repo-Root.
#
# Aufruf:
#   ./build.sh                 # Binaries holen (falls fehlen) + CLI + App bauen
#   ./build.sh --cli-only      # nur Binaries + Core/CLI (kein Xcode/App-Build)
#   ./build.sh --deps-only     # nur die Binaries herunterladen
#   ./build.sh --force-deps    # Binaries neu laden, auch wenn schon vorhanden
#
# AI-Agent/Headless: alle Schritte laufen ohne GUI; Exit-Code ≠ 0 bei Fehler.

set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin"
FFMPEG_URL="https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
MEDIAINFO_VERSION="26.05"   # bei Bedarf hochziehen: https://mediaarea.net/en/MediaInfo/Download/Mac_OS
MEDIAINFO_URL="https://mediaarea.net/download/binary/mediainfo/${MEDIAINFO_VERSION}/MediaInfo_CLI_${MEDIAINFO_VERSION}_Mac.dmg"

CLI_ONLY=0; DEPS_ONLY=0; FORCE_DEPS=0
for arg in "$@"; do
    case "$arg" in
        --cli-only)   CLI_ONLY=1 ;;
        --deps-only)  DEPS_ONLY=1 ;;
        --force-deps) FORCE_DEPS=1 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 64 ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

fetch_ffmpeg() {
    log "Lade ffmpeg (evermeet, x86_64 – läuft auf Apple Silicon via Rosetta) …"
    local tmp; tmp="$(mktemp -d)"
    curl -fSL --retry 3 --max-time 300 "$FFMPEG_URL" -o "$tmp/ffmpeg.zip"
    unzip -q -o "$tmp/ffmpeg.zip" -d "$tmp"
    mv "$tmp/ffmpeg" "$BIN_DIR/ffmpeg"
    chmod +x "$BIN_DIR/ffmpeg"
    rm -rf "$tmp"
}

fetch_mediainfo() {
    log "Lade mediainfo CLI ${MEDIAINFO_VERSION} (mediaarea, universal) …"
    local tmp mnt; tmp="$(mktemp -d)"; mnt="$tmp/mnt"
    curl -fSL --retry 3 --max-time 300 "$MEDIAINFO_URL" -o "$tmp/mediainfo.dmg"
    hdiutil attach "$tmp/mediainfo.dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null
    # Das DMG enthält keinen losen Binary, sondern einen Installer 'mediainfo.pkg'.
    # Payload entpacken (ohne zu installieren) und die Binary herausziehen.
    local pkg; pkg="$(find "$mnt" -maxdepth 1 -name '*.pkg' | head -1)"
    if [[ -z "$pkg" ]]; then
        hdiutil detach "$mnt" >/dev/null || true
        echo "Fehler: kein .pkg im mediainfo-DMG gefunden." >&2; exit 1
    fi
    pkgutil --expand-full "$pkg" "$tmp/expanded" >/dev/null
    hdiutil detach "$mnt" >/dev/null
    local found; found="$(find "$tmp/expanded" -type f -name mediainfo | head -1)"
    if [[ -z "$found" ]]; then
        echo "Fehler: 'mediainfo'-Binary im pkg-Payload nicht gefunden." >&2; exit 1
    fi
    cp "$found" "$BIN_DIR/mediainfo"
    chmod +x "$BIN_DIR/mediainfo"
    rm -rf "$tmp"
}

ensure_deps() {
    mkdir -p "$BIN_DIR"
    if [[ "$FORCE_DEPS" == 1 || ! -x "$BIN_DIR/ffmpeg" ]]; then fetch_ffmpeg; else log "ffmpeg schon vorhanden."; fi
    if [[ "$FORCE_DEPS" == 1 || ! -x "$BIN_DIR/mediainfo" ]]; then fetch_mediainfo; else log "mediainfo schon vorhanden."; fi
    log "ffmpeg:    $("$BIN_DIR/ffmpeg" -version 2>/dev/null | head -1)"
    log "mediainfo: $("$BIN_DIR/mediainfo" --Version 2>/dev/null | tr -d '\n')"
}

build_cli() {
    log "Baue Core + CLI (swift build -c release) …"
    ( cd HoerbuchkloepplerCore && swift build -c release )
    log "CLI gebaut: HoerbuchkloepplerCore/.build/release/kloeppler"
}

build_app() {
    # VERSION-Datei ist die einzige Quelle der Wahrheit — stempelt die App-Version.
    local version; version="$(cat VERSION 2>/dev/null || echo 1.0)"
    log "Baue App (xcodebuild, Release, macOS) — Version ${version} …"
    # Festes App-Scheme (nicht das Library-Scheme 'HoerbuchkloepplerCore' oder das
    # CLI-Scheme 'kloeppler') + macOS-Destination, sonst rät xcodebuild iOS-Simulatoren.
    rm -rf build
    xcodebuild -project "Hörbuchklöppler.xcodeproj" -scheme "Hörbuchklöppler" \
        -destination 'platform=macOS' \
        -configuration Release -derivedDataPath build \
        MARKETING_VERSION="$version" \
        CODE_SIGNING_ALLOWED=NO build >/dev/null
    local app; app="$(find build/Build/Products -maxdepth 2 -name '*.app' | head -1)"
    if [[ -z "$app" ]]; then echo "Fehler: gebaute .app nicht gefunden." >&2; exit 1; fi
    rm -rf "./$(basename "$app")"
    cp -R "$app" "./$(basename "$app")"
    log "App gebaut: ./$(basename "$app")  (zum Testen: open \"./$(basename "$app")\")"
}

ensure_deps
[[ "$DEPS_ONLY" == 1 ]] && { log "Fertig (nur Binaries)."; exit 0; }
build_cli
[[ "$CLI_ONLY" == 1 ]] && { log "Fertig (CLI). App-Build übersprungen."; exit 0; }
build_app
log "Fertig."
