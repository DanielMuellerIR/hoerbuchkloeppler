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
# dist/ liegt bewusst AUSSERHALB von build/: build.sh löscht build/ bei jedem
# App-Build komplett — ein früher notarisiertes DMG unter build/dmg verschwand
# damit schon beim Start des nächsten Release-Versuchs.
DIST="dist"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
# Unfertige Zwischenstände tragen eigene Namen; der endgültige DMG-Pfad
# entsteht erst nach bestandener Signatur-/Notary-/Gatekeeper-Prüfung durch
# atomares Umbenennen. So bleibt ein früheres gutes DMG bei einem Fehlversuch
# erhalten, und unter dem Erfolgsnamen liegt nie ein ungeprüftes Image.
STAGING_DMG="$DIST/${APP_NAME}-${VERSION}.unverified.dmg"
RW_DMG="$DIST/${APP_NAME}-${VERSION}-rw.dmg"

FINDER_LAYOUT=1
for arg in "$@"; do
  case "$arg" in
    --no-finder-layout) FINDER_LAYOUT=0 ;;
    -h|--help) sed -n '/^# release\.sh/,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $arg" >&2
       echo "Aufruf: ./release.sh [--no-finder-layout] [--help]" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

MOUNT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hoerbuchkloeppler-release.XXXXXX")"
# `hdiutil info` meldet macOS-Symlinks kanonisch (`/private/var/...` statt
# `/var/...`). Derselbe kanonische Pfad ist deshalb Voraussetzung dafür, einen
# aktiven Mount im Cleanup zuverlässig zu erkennen.
MOUNT_ROOT="$(cd "$MOUNT_ROOT" && pwd -P)"
MOUNT_DIR="$MOUNT_ROOT/volume"

mount_is_active() {
  # Ohne `grep -q`: Dessen frühes Ende kann `hdiutil` unter pipefail mit SIGPIPE
  # beenden und einen vorhandenen Mount fälschlich als inaktiv melden.
  hdiutil info | grep -F "$MOUNT_DIR" >/dev/null
}

cleanup() {
  # Der private Mountpoint gehört eindeutig diesem Lauf. Solange er noch aktiv
  # ist, dürfen weder sein Verzeichnis noch das zugrunde liegende RW-DMG
  # gelöscht werden.
  if mount_is_active; then
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
  if mount_is_active; then
    echo "Warnung: DMG blieb eingehängt; temporäre Daten bleiben erhalten: $MOUNT_ROOT" >&2
    return
  fi
  rm -f "$RW_DMG" "$STAGING_DMG"
  rm -rf "$MOUNT_ROOT"
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
# Nur die Zwischenstände wegräumen. Ein vorhandenes fertiges "$DMG" bleibt
# liegen, bis der neue Stand alle Prüfungen bestanden hat (atomares mv unten).
rm -f "$RW_DMG" "$STAGING_DMG"

SIZE=$(( $(du -sm "$APP" | cut -f1) + 60 ))
hdiutil create -srcfolder "$APP" -volname "$VOLNAME" -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE}m" "$RW_DMG"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noverify \
  -noautoopen >/dev/null

ln -s /Applications "$MOUNT_DIR/Applications"
# Die GPL-Hinweise reisen mit: Wer das Image auf einem anderen eigenen Mac
# öffnet, findet die Lizenzlage direkt daneben. Der Kopiervorgang ist
# verpflichtend — ein DMG ohne die zugesagten Lizenzhinweise darf kein
# RELEASE OK melden (set -e bricht bei cp-Fehler ab).
cp THIRD-PARTY-NOTICES.md "$MOUNT_DIR/THIRD-PARTY-NOTICES.md"

# Icon-Positionen setzen. --no-finder-layout überspringt das: Der Schritt öffnet
# ein echtes Finder-Fenster und reißt den Fokus an sich, was headless-Läufe (und
# Läufe neben laufender Arbeit) stört.
if [ "$FINDER_LAYOUT" -eq 1 ]; then
osascript <<APPLESCRIPT
tell application "Finder"
  set targetFolder to POSIX file "$MOUNT_DIR" as alias
  open targetFolder
  set targetWindow to container window of targetFolder
  set current view of targetWindow to icon view
  set toolbar visible of targetWindow to false
  set statusbar visible of targetWindow to false
  set the bounds of targetWindow to {200, 120, 800, 520}
  set theViewOptions to the icon view options of targetWindow
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set position of item "${APP_NAME}.app" of targetFolder to {150, 190}
    set position of item "Applications" of targetFolder to {450, 190}
    try
      set position of item "THIRD-PARTY-NOTICES.md" of targetFolder to {300, 340}
    end try
  update targetFolder without registering applications
  close targetWindow
end tell
APPLESCRIPT
else
  log "Finder-Layout übersprungen (--no-finder-layout)"
fi

# Vor dem Aushängen sicherstellen, dass die Lizenzhinweise wirklich im Image
# liegen (z.B. gegen ein versehentliches Entfernen im Finder-Layout-Schritt).
[ -f "$MOUNT_DIR/THIRD-PARTY-NOTICES.md" ] \
  || { echo "Fehler: THIRD-PARTY-NOTICES.md fehlt im DMG." >&2; exit 1; }

sync; sleep 2                       # Race: DS_Store-Schreibpuffer vs. detach
if ! hdiutil detach "$MOUNT_DIR"; then
  hdiutil detach "$MOUNT_DIR" -force
fi
mount_is_active && { echo "Fehler: privates DMG konnte nicht ausgehängt werden." >&2; exit 1; }

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$STAGING_DMG"
rm -f "$RW_DMG"

# ── 3. DMG signieren, notarisieren, stapeln ─────────────────────────────────
SIGN_IDENTITY="${HOERBUCHKLOEPPLER_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ && !found {print $2; found=1}')"
fi
log "Signiere und notarisiere das DMG…"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$STAGING_DMG"

# install.sh hat das Profil oben bereits geprüft und clone-lokal gemerkt.
# shellcheck source=notary-profile.sh
source "./notary-profile.sh"
hoerbuchkloeppler_require_notary_profile

xcrun notarytool submit "$STAGING_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$STAGING_DMG"
xcrun stapler validate "$STAGING_DMG"
spctl --assess --type open --context context:primary-signature -v "$STAGING_DMG" 2>&1 | sed 's/^/    /'

# Alle Prüfungen bestanden — erst jetzt bekommt das Image den endgültigen
# Namen. Ein Fehler weiter oben lässt höchstens die .unverified-Datei zurück
# (die der EXIT-Cleanup entfernt), nie ein ungeprüftes "$DMG".
mv -f "$STAGING_DMG" "$DMG"

echo
echo "⚠ Nur für eigene Macs — nicht weitergeben (gebündeltes ffmpeg ist GPL-3.0)."
echo "RELEASE OK: $PWD/$DMG ($VERSION)"
