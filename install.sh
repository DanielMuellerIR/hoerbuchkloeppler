#!/usr/bin/env bash
#
# install.sh — Hörbuchklöppler als notarisierten Build nach /Applications
# installieren.
#
# Unterschied zu build.sh: build.sh erzeugt einen schnellen, nur ad-hoc
# signierten Entwicklungs-Build im Projekt-Root (./Hörbuchklöppler.app) zum
# Testen. install.sh erzeugt die BEWUSST installierte Fassung: mit Developer ID
# + Hardened Runtime signiert, bei Apple notarisiert, Ticket angeheftet, nach
# /Applications kopiert. Diese Version startet ohne Gatekeeper-Meckern — auch
# auf anderen Macs.
#
# Ablauf: build.sh  →  signieren (innen→außen)  →  notarisieren  →  stapeln  →
#         nach /Applications kopieren  →  verifizieren.
#
# Bei Erfolg lautet die letzte Zeile maschinenlesbar:
#   INSTALL OK: /Applications/Hörbuchklöppler.app (<version>)
#
# Voraussetzungen:
#   - Xcode + Command-Line-Tools (wie bei build.sh).
#   - Ein „Developer ID Application"-Zertifikat im Schlüsselbund (wird
#     automatisch gefunden; per HOERBUCHKLOEPPLER_SIGN_IDENTITY überschreibbar).
#   - Ein notarytool-Keychain-Profil (pro Mac lokal). Name über NOTARY_PROFILE
#     oder clone-lokale Git-Config; siehe notary-profile.sh.
#
# Aufruf:
#   ./install.sh                          # Profil aus NOTARY_PROFILE/Git-Config
#   NOTARY_PROFILE=<profil> ./install.sh  # anderes Keychain-Profil
#   ./install.sh --no-notarize            # nur Developer-ID-signiert (schneller
#                                         #   Test; läuft sofort auf DIESEM Mac,
#                                         #   nicht garantiert gatekeeper-frei
#                                         #   auf anderen)
#   ./install.sh --help
#
# GPL-Hinweis: Der installierte Build bündelt ffmpeg (GPL-3.0). Das ist für den
# Eigengebrauch bzw. die eigenen Macs gedacht — dieses Projekt verteilt bewusst
# keine fertigen Binaries öffentlich (siehe README / THIRD-PARTY-NOTICES.md).
#
# AI-Agent/Headless: alle Schritte laufen ohne GUI; Exit-Code ≠ 0 bei Fehler.
# (Ausnahme: fehlt ein Notary-Profil und läuft das Skript ohne TTY, bricht es
# mit klarer Anleitung ab, statt zu blockieren.)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Hörbuchklöppler"
DEST="/Applications/${APP_NAME}.app"

NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $arg" >&2
       echo "Aufruf: ./install.sh [--no-notarize] [--help]" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

# ── Notar-Profil VOR dem teuren Build prüfen (schneller Fehlschlag) ──────────
if [ "$NOTARIZE" -eq 1 ]; then
  # shellcheck source=notary-profile.sh
  source "./notary-profile.sh"
  hoerbuchkloeppler_require_notary_profile
fi

# ── Developer-ID-Identität ermitteln (public-safe: nichts Privates im Skript,
#    wird zur Laufzeit aus dem Schlüsselbund gelesen) ─────────────────────────
SIGN_IDENTITY="${HOERBUCHKLOEPPLER_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  echo "✗ Kein 'Developer ID Application'-Zertifikat im Schlüsselbund gefunden." >&2
  echo "  Ohne Developer ID kann nicht signiert/notarisiert werden." >&2
  exit 1
fi
log "Signatur-Identität: $SIGN_IDENTITY"

# ── 1. Release-Build (baut Core/CLI/App; App landet ad-hoc im Projekt-Root) ──
./build.sh
APP="./${APP_NAME}.app"
[ -d "$APP" ] || { echo "✗ Build-Ergebnis fehlt: $APP" >&2; exit 1; }

# ── 2. Mit Developer ID + Hardened Runtime signieren (innen→außen) ───────────
log "Signiere Bundle mit Developer ID + Hardened Runtime (ffmpeg/mediainfo → Framework → App)…"
./sign-bundle.sh "$APP" "$SIGN_IDENTITY"

# ── 3. Notarisieren (optional): als ZIP hochladen, --wait blockt bis fertig ──
if [ "$NOTARIZE" -eq 1 ]; then
  TMP="$(mktemp -d)"; ZIP="$TMP/${APP_NAME}.zip"
  log "Notarisiere via Profil '$NOTARY_PROFILE' (wartet auf Apple, ~1–10 Min)…"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -rf "$TMP"
  # Ticket ans Bundle heften → validiert auch OFFLINE (ohne Netz).
  log "Hefte Notarisierungs-Ticket ans Bundle…"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
else
  log "⚠ --no-notarize: nur Developer-ID-signiert (kein Notary-Ticket)."
fi

# ── 4. Nach /Applications installieren (laufende Instanz vorher beenden) ─────
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  log "Beende laufende ${APP_NAME}-Instanz"
  pkill -x "$APP_NAME" || true
  sleep 1
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"

# ── 5. Verifizieren: Signatur, Gatekeeper und gebündeltes ffmpeg im DEST ─────
codesign --verify --deep --strict "$DEST"
if [ "$NOTARIZE" -eq 1 ]; then
  # spctl bewertet die Gatekeeper-Freigabe der tatsächlich installierten App.
  spctl --assess --type execute -vv "$DEST" 2>&1 | sed 's/^/    /'
fi
FFMPEG="$DEST/Contents/Resources/HoerbuchkloepplerCore_HoerbuchkloepplerCore.bundle/Contents/Resources/bin/ffmpeg"
if [ -x "$FFMPEG" ]; then
  "$FFMPEG" -version >/dev/null 2>&1 \
    && log "Gebündeltes ffmpeg im installierten Bundle ist ausführbar." \
    || { echo "✗ Gebündeltes ffmpeg startet nicht — Signatur/Architektur prüfen." >&2; exit 1; }
fi

VERSION="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo
echo "INSTALL OK: $DEST ($VERSION)"
