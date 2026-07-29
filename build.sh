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
FFMPEG_VERSION="8.1.2"
FFMPEG_URL="https://evermeet.cx/ffmpeg/ffmpeg-${FFMPEG_VERSION}.zip"
FFMPEG_ARCHIVE_SHA256="e91df72a1ee7c26606f90dd2dd4dcccc6a75140ff9ea6fdd50faae828b82ba69"
FFMPEG_BINARY_SHA256="60725ea0467ccaf900bf294d3567c302a802dc661f03bdde6aa7ecc9ccf05c4f"
MEDIAINFO_VERSION="26.05"   # bei Bedarf mit URL + beiden Prüfsummen zusammen aktualisieren
MEDIAINFO_URL="https://mediaarea.net/download/binary/mediainfo/${MEDIAINFO_VERSION}/MediaInfo_CLI_${MEDIAINFO_VERSION}_Mac.dmg"
MEDIAINFO_ARCHIVE_SHA256="507605a7c8f1054a6996d99a4ef5b5a0711cfbf2f8ca2ef5161d6ee701ea8015"
MEDIAINFO_BINARY_SHA256="d070140e4d60b3f49aae1cab752d77dc3611aac451b6109b9d2b1812b602b17e"

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

verify_sha256() {
    local file="$1" expected="$2" label="$3" actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "Fehler: SHA-256-Prüfung für $label fehlgeschlagen." >&2
        echo "  erwartet: $expected" >&2
        echo "  erhalten: $actual" >&2
        return 1
    fi
}

binary_matches_sha256() {
    local file="$1" expected="$2"
    [[ -f "$file" && -x "$file" ]] \
        && [[ "$(shasum -a 256 "$file" | awk '{print $1}')" == "$expected" ]]
}

fetch_ffmpeg() (
    set -euo pipefail
    log "Lade ffmpeg ${FFMPEG_VERSION} (evermeet, x86_64 – läuft auf Apple Silicon via Rosetta) …"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fSL --retry 3 --max-time 300 "$FFMPEG_URL" -o "$tmp/ffmpeg.zip"
    verify_sha256 "$tmp/ffmpeg.zip" "$FFMPEG_ARCHIVE_SHA256" "ffmpeg-Archiv"
    unzip -q -o "$tmp/ffmpeg.zip" -d "$tmp"
    verify_sha256 "$tmp/ffmpeg" "$FFMPEG_BINARY_SHA256" "ffmpeg-Binary"
    mv "$tmp/ffmpeg" "$BIN_DIR/ffmpeg"
    chmod +x "$BIN_DIR/ffmpeg"
)

fetch_mediainfo() (
    set -euo pipefail
    log "Lade mediainfo CLI ${MEDIAINFO_VERSION} (mediaarea, universal) …"
    local tmp mnt mounted=0
    tmp="$(mktemp -d)"
    mnt="$tmp/mnt"
    cleanup_mediainfo_download() {
        if [[ "$mounted" == 1 ]]; then
            hdiutil detach "$mnt" >/dev/null 2>&1 || true
        fi
        rm -rf "$tmp"
    }
    trap cleanup_mediainfo_download EXIT
    curl -fSL --retry 3 --max-time 300 "$MEDIAINFO_URL" -o "$tmp/mediainfo.dmg"
    verify_sha256 "$tmp/mediainfo.dmg" "$MEDIAINFO_ARCHIVE_SHA256" "MediaInfo-Archiv"
    hdiutil attach "$tmp/mediainfo.dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null
    mounted=1
    # Das DMG enthält keinen losen Binary, sondern einen Installer 'mediainfo.pkg'.
    # Payload entpacken (ohne zu installieren) und die Binary herausziehen.
    local pkg; pkg="$(find "$mnt" -maxdepth 1 -name '*.pkg' | head -1)"
    if [[ -z "$pkg" ]]; then
        echo "Fehler: kein .pkg im mediainfo-DMG gefunden." >&2; exit 1
    fi
    pkgutil --expand-full "$pkg" "$tmp/expanded" >/dev/null
    hdiutil detach "$mnt" >/dev/null
    mounted=0
    local found; found="$(find "$tmp/expanded" -type f -name mediainfo | head -1)"
    if [[ -z "$found" ]]; then
        echo "Fehler: 'mediainfo'-Binary im pkg-Payload nicht gefunden." >&2; exit 1
    fi
    verify_sha256 "$found" "$MEDIAINFO_BINARY_SHA256" "MediaInfo-Binary"
    cp "$found" "$BIN_DIR/mediainfo"
    chmod +x "$BIN_DIR/mediainfo"
)

ensure_deps() {
    mkdir -p "$BIN_DIR"
    if [[ "$FORCE_DEPS" == 1 ]] || ! binary_matches_sha256 "$BIN_DIR/ffmpeg" "$FFMPEG_BINARY_SHA256"; then
        fetch_ffmpeg
    else
        log "ffmpeg ${FFMPEG_VERSION} schon vorhanden und geprüft."
    fi
    if [[ "$FORCE_DEPS" == 1 ]] || ! binary_matches_sha256 "$BIN_DIR/mediainfo" "$MEDIAINFO_BINARY_SHA256"; then
        fetch_mediainfo
    else
        log "mediainfo ${MEDIAINFO_VERSION} schon vorhanden und geprüft."
    fi

    local ffmpeg_version mediainfo_version
    if ! ffmpeg_version="$("$BIN_DIR/ffmpeg" -version 2>/dev/null)" || [[ -z "$ffmpeg_version" ]]; then
        echo "Fehler: Das geprüfte ffmpeg-Binary startet nicht." >&2
        return 1
    fi
    if ! mediainfo_version="$("$BIN_DIR/mediainfo" --Version 2>/dev/null)" || [[ -z "$mediainfo_version" ]]; then
        echo "Fehler: Das geprüfte MediaInfo-Binary startet nicht." >&2
        return 1
    fi
    log "ffmpeg:    ${ffmpeg_version%%$'\n'*}"
    log "mediainfo: ${mediainfo_version//$'\n'/ }"
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
    # Xcode erzeugt bei deaktiviertem Signing nur eine linker-signierte
    # Programmdatei, aber kein versiegeltes Bundle. Für den lokalen Test-Build
    # alle verschachtelten Programme und die App korrekt ad-hoc signieren.
    ./sign-bundle.sh "./$(basename "$app")" -
    log "App gebaut: ./$(basename "$app")  (zum Testen: open \"./$(basename "$app")\")"
}

ensure_deps
[[ "$DEPS_ONLY" == 1 ]] && { log "Fertig (nur Binaries)."; exit 0; }
build_cli
[[ "$CLI_ONLY" == 1 ]] && { log "Fertig (CLI). App-Build übersprungen."; exit 0; }
build_app
log "Fertig."
