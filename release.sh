#!/usr/bin/env bash
#
# release.sh — notarisiertes DMG für die EIGENEN Macs bauen.
#
# ⚠ WICHTIG — dieses DMG wird NIE veröffentlicht.
# Der Build bündelt ffmpeg unter der GPL-3.0. Wer ein solches Binary weitergibt,
# muss den vollständigen entsprechenden Quelltext mitliefern und die Weitergabe
# unter GPL-Bedingungen stellen. Dieses Projekt tut das bewusst nicht (siehe
# README und THIRD-PARTY-NOTICES.md). Das DMG hier ist ausschließlich der bequeme
# Weg, denselben notarisierten Stand auf einen weiteren eigenen Mac zu bringen.
# Deshalb gibt es hier bewusst KEINEN --publish-Pfad, keinen GitHub-Upload und
# keinen Tag. Bitte auch keinen nachrüsten.
#
# Die drei Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh     schneller ad-hoc signierter Entwicklungs-Build im Projekt-Root
#   ./install.sh   baut, signiert, notarisiert und installiert nach /Applications
#   ./release.sh   baut, signiert, notarisiert und packt das DMG — installiert nie
#
# Zuerst bekommt die App ihr eigenes Notary-Ticket, dann das DMG. Nur so startet
# sie auch dann sauber, wenn jemand sie aus dem Image herauszieht — ein Ticket
# allein am DMG reicht dafür nicht.
#
# Voraussetzungen: wie install.sh (Developer-ID-Zertifikat, notarytool-Profil
# über NOTARY_PROFILE oder clone-lokale Git-Config; siehe notary-profile.sh).
#
# Aufruf:
#   ./release.sh                     # vollständiger Lauf
#   ./release.sh --no-finder-layout  # ohne Finder-Fensterlayout (headless)
#
# Bei Erfolg lautet die letzte Zeile maschinenlesbar:
#   RELEASE OK: <pfad-zum-dmg> (<version>)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Hörbuchklöppler"
APP="./${APP_NAME}.app"
VOLNAME="$APP_NAME"
VERSION="$(cat VERSION)"
DIST="build/dmg"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
RW_DMG="$DIST/${APP_NAME}-${VERSION}-rw.dmg"
MOUNT_DIR="/Volumes/$VOLNAME"

FINDER_LAYOUT=1
for arg in "$@"; do
  case "$arg" in
    --no-finder-layout) FINDER_LAYOUT=0 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $arg" >&2
       echo "Aufruf: ./release.sh [--no-finder-layout] [--help]" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

cleanup() {
  if hdiutil info | grep -Fq "$MOUNT_DIR"; then
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
  rm -f "$RW_DMG"
}
trap cleanup EXIT

# ── 1. Bauen, signieren, App notarisieren — ohne zu installieren ─────────────
# install.sh ist der geprüfte Weg dorthin; --no-install steigt genau vor dem
# Kopieren nach /Applications aus.
log "Baue, signiere und notarisiere die App (install.sh --no-install)…"
./install.sh --no-install

xcrun stapler validate "$APP"

# ── 2. DMG packen ───────────────────────────────────────────────────────────
log "Packe DMG…"
mkdir -p "$DIST"
rm -f "$DMG" "$RW_DMG"
[ -d "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true

SIZE=$(( $(du -sm "$APP" | cut -f1) + 60 ))
hdiutil create -srcfolder "$APP" -volname "$VOLNAME" -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE}m" "$RW_DMG"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noverify -noautoopen

ln -s /Applications "$MOUNT_DIR/Applications"
# Die GPL-Hinweise reisen mit: Wer das Image auf einem anderen eigenen Mac
# öffnet, findet die Lizenzlage direkt daneben.
cp THIRD-PARTY-NOTICES.md "$MOUNT_DIR/THIRD-PARTY-NOTICES.md" 2>/dev/null || true

# Icon-Positionen setzen. --no-finder-layout überspringt das: Der Schritt öffnet
# ein echtes Finder-Fenster und reißt den Fokus an sich, was headless-Läufe (und
# Läufe neben laufender Arbeit) stört.
if [ "$FINDER_LAYOUT" -eq 1 ]; then
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set position of item "${APP_NAME}.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    try
      set position of item "THIRD-PARTY-NOTICES.md" of container window to {300, 340}
    end try
    update without registering applications
    close
  end tell
end tell
APPLESCRIPT
else
  log "Finder-Layout übersprungen (--no-finder-layout)"
fi

sync; sleep 2                       # Race: DS_Store-Schreibpuffer vs. detach
hdiutil detach "$MOUNT_DIR" -force

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW_DMG"

# ── 3. DMG signieren, notarisieren, stapeln ─────────────────────────────────
SIGN_IDENTITY="${HOERBUCHKLOEPPLER_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
log "Signiere und notarisiere das DMG…"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

# install.sh hat das Profil oben bereits geprüft und clone-lokal gemerkt.
# shellcheck source=notary-profile.sh
source "./notary-profile.sh"
hoerbuchkloeppler_require_notary_profile

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/    /'

echo
echo "⚠ Nur für eigene Macs — nicht weitergeben (gebündeltes ffmpeg ist GPL-3.0)."
echo "RELEASE OK: $PWD/$DMG ($VERSION)"
