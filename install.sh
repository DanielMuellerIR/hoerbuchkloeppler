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
#   ./install.sh --no-notarize            # nur Developer-ID-signierten Test-Build
#                                         #   im Projekt erzeugen; installiert nie
#                                         #   nach /Applications
#   ./install.sh --no-install             # baut, signiert und notarisiert das
#                                         #   Bundle im Projekt-Root, fasst
#                                         #   /Applications aber nicht an (der
#                                         #   Ausstieg, den release.sh nutzt)
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
DEST="${HOERBUCHKLOEPPLER_INSTALL_DEST:-/Applications/${APP_NAME}.app}"

NOTARIZE=1
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    # --no-install liefert genau das, was release.sh braucht: ein fertig
    # signiertes und notarisiertes Bundle im Projekt-Root, ohne /Applications
    # anzufassen.
    --no-install) INSTALL=0 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $arg" >&2
       echo "Aufruf: ./install.sh [--no-notarize] [--no-install] [--help]" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

# shellcheck source=script-helpers.sh
source "./script-helpers.sh"

# Ein benutzerdefiniertes Testziel darf den späteren Staging-Pfad nicht auf ein
# breites oder unerwartetes Dateisystemziel lenken. `--no-install` braucht diese
# Prüfung nicht, weil dieser Modus DEST überhaupt nicht anfasst.
if [ "$INSTALL" -eq 1 ] && [ "$NOTARIZE" -eq 1 ]; then
  case "$DEST" in
    /*/*.app) ;;
    *) echo "✗ Installationsziel muss ein absoluter .app-Pfad unterhalb eines Ordners sein: $DEST" >&2
       exit 1 ;;
  esac
  DEST_BASENAME="$(basename "$DEST")"
  DEST_PARENT_INPUT="$(dirname "$DEST")"
  if ! DEST_PARENT="$(cd "$DEST_PARENT_INPUT" 2>/dev/null && pwd -P)"; then
    echo "✗ Elternordner des Installationsziels fehlt: $DEST_PARENT_INPUT" >&2
    exit 1
  fi
  [ "$DEST_PARENT" != "/" ] \
    || { echo "✗ Installation direkt unter / ist nicht erlaubt: $DEST" >&2; exit 1; }
  # Normalisieren, damit spätere dirname-/basename-Aufrufe nicht erneut `..`
  # oder einen Symlink-Elternpfad interpretieren müssen.
  DEST="$DEST_PARENT/$DEST_BASENAME"
  if [ -L "$DEST" ]; then
    echo "✗ Installationsziel darf kein Symlink sein: $DEST" >&2
    exit 1
  fi
  if [ -e "$DEST" ] && [ ! -d "$DEST" ]; then
    echo "✗ Installationsziel existiert, ist aber kein App-Bundle-Ordner: $DEST" >&2
    exit 1
  fi
fi

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
APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || true)"
case "$APP_EXECUTABLE_NAME" in
  ""|*/*) echo "✗ Build-Ergebnis enthält keinen sicheren CFBundleExecutable-Namen." >&2; exit 1 ;;
esac

# ── 2. Mit Developer ID + Hardened Runtime signieren (innen→außen) ───────────
log "Signiere Bundle mit Developer ID + Hardened Runtime (eingebettete Programme → App)…"
./sign-bundle.sh "$APP" "$SIGN_IDENTITY"

# ── 3. Notarisieren (optional): als ZIP hochladen, --wait blockt bis fertig ──
if [ "$NOTARIZE" -eq 1 ]; then
  log "Notarisiere via Profil '$NOTARY_PROFILE' (wartet auf Apple, ~1–10 Min)…"
  notarize_app() (
    set -euo pipefail
    local temp_dir zip
    temp_dir="$(mktemp -d)"
    zip="$temp_dir/${APP_NAME}.zip"
    trap 'rm -rf "$temp_dir"' EXIT
    ditto -c -k --keepParent "$APP" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  )
  notarize_app
  # Ticket ans Bundle heften → validiert auch OFFLINE (ohne Netz).
  log "Hefte Notarisierungs-Ticket ans Bundle…"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
else
  log "⚠ --no-notarize: nur Developer-ID-signierter Test-Build (kein Notary-Ticket)."
fi

# Die Signatur des Build-Artefakts immer prüfen. Ohne Notarisierung endet der
# Schnellpfad HIER: Er darf weder eine laufende App beenden noch unter
# /Applications löschen oder kopieren.
codesign --verify --deep --strict "$APP"
if [ "$NOTARIZE" -eq 0 ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
  echo
  echo "TEST BUILD OK: $APP ($VERSION) — nicht installiert"
  exit 0
fi

# Gatekeeper muss das tatsächlich zu installierende Quell-Bundle akzeptieren,
# bevor der Installationspfad irgendeine Mutation unter /Applications ausführt.
log "Prüfe Notarisierung und Gatekeeper-Freigabe des Build-Artefakts…"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/    /'

# Vor jeder Mutation unter /Applications beide tatsächlich eingebetteten
# Laufzeitprogramme starten. Ein bloß vorhandenes oder signiertes Binary kann
# trotzdem durch eine falsche Architektur oder beschädigte Payload unbrauchbar
# sein.
RESOURCE_BIN="$APP/Contents/Resources/HoerbuchkloepplerCore_HoerbuchkloepplerCore.bundle/Contents/Resources/bin"
APP_FFMPEG="$RESOURCE_BIN/ffmpeg"
APP_MEDIAINFO="$RESOURCE_BIN/mediainfo"
[ -x "$APP_FFMPEG" ] || { echo "✗ Gebündeltes ffmpeg fehlt oder ist nicht ausführbar." >&2; exit 1; }
[ -x "$APP_MEDIAINFO" ] || { echo "✗ Gebündeltes mediainfo fehlt oder ist nicht ausführbar." >&2; exit 1; }
"$APP_FFMPEG" -version >/dev/null 2>&1 \
  || { echo "✗ Gebündeltes ffmpeg startet im Build-Artefakt nicht." >&2; exit 1; }
"$APP_MEDIAINFO" --Version >/dev/null 2>&1 \
  || { echo "✗ Gebündeltes mediainfo startet im Build-Artefakt nicht." >&2; exit 1; }
log "Gebündelte Laufzeitprogramme im Build-Artefakt sind ausführbar."

# Ausstieg für release.sh: notarisiert, aber /Applications bleibt unberührt.
if [ "$INSTALL" -eq 0 ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
  echo
  echo "BUILD OK: $APP ($VERSION) — notarisiert, nicht installiert"
  exit 0
fi

# ── 4. Nach /Applications installieren (laufende Ziel-Instanz vorher beenden) ─
# Nur Prozesse des tatsächlich zu ersetzenden Bundles beenden. Ein pauschales
# `pkill -x` träfe auch einen Test-Build aus diesem oder einem anderen Worktree.
DEST_EXECUTABLE_NAME="$APP_EXECUTABLE_NAME"
if [ -f "$DEST/Contents/Info.plist" ]; then
  installed_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
  case "$installed_executable_name" in
    ""|*/*) ;;
    *) DEST_EXECUTABLE_NAME="$installed_executable_name" ;;
  esac
fi
DEST_EXECUTABLE=""
if [ -d "$DEST/Contents/MacOS" ]; then
  DEST_EXECUTABLE_DIR="$(cd "$DEST/Contents/MacOS" && pwd -P)"
  DEST_EXECUTABLE="$DEST_EXECUTABLE_DIR/$DEST_EXECUTABLE_NAME"
fi
destination_pids=()
destination_identities=()
process_is_original_destination() {
  hoerbuchkloeppler_process_matches_snapshot "$1" "$2" "$DEST_EXECUTABLE"
}
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  process_snapshot="$(hoerbuchkloeppler_process_snapshot "$pid")"
  if hoerbuchkloeppler_snapshot_targets_executable "$process_snapshot" "$DEST_EXECUTABLE"; then
      destination_pids+=("$pid")
      destination_identities+=("$process_snapshot")
  fi
done < <(pgrep -x "$DEST_EXECUTABLE_NAME" 2>/dev/null || true)
if [ "${#destination_pids[@]}" -gt 0 ]; then
  log "Beende laufende ${APP_NAME}-Instanz aus $DEST"
  for index in "${!destination_pids[@]}"; do
    pid="${destination_pids[$index]}"
    if process_is_original_destination "$pid" "${destination_identities[$index]}"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for _ in {1..50}; do
    still_running=0
    for index in "${!destination_pids[@]}"; do
      pid="${destination_pids[$index]}"
      if process_is_original_destination "$pid" "${destination_identities[$index]}"; then
        still_running=1; break
      fi
    done
    [ "$still_running" -eq 0 ] && break
    sleep 0.1
  done
  for index in "${!destination_pids[@]}"; do
    pid="${destination_pids[$index]}"
    if process_is_original_destination "$pid" "${destination_identities[$index]}"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  for _ in {1..20}; do
    still_running=0
    for index in "${!destination_pids[@]}"; do
      pid="${destination_pids[$index]}"
      if process_is_original_destination "$pid" "${destination_identities[$index]}"; then
        still_running=1; break
      fi
    done
    [ "$still_running" -eq 0 ] && break
    sleep 0.1
  done
  [ "$still_running" -eq 0 ] \
    || { echo "✗ Laufende Ziel-App konnte nicht beendet werden: $DEST" >&2; exit 1; }
fi
# Atomar austauschen: erst neben das Ziel legen, dann in einem Schritt
# eintauschen. Ein Abbruch mittendrin darf keine halb ersetzte App unter
# /Applications hinterlassen — genau das konnte `rm -rf` + `cp -R` erzeugen.
DEST_STEM="${DEST_BASENAME%.app}"
STAGED="$DEST_PARENT/.${DEST_STEM}.install-$$.app"
BACKUP_BASENAME=".${DEST_STEM}.backup-$$.app"
BACKUP="$DEST_PARENT/$BACKUP_BASENAME"
[ ! -e "$STAGED" ] && [ ! -L "$STAGED" ] \
  || { echo "✗ Installations-Staging-Pfad ist bereits belegt: $STAGED" >&2; exit 1; }
[ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ] \
  || { echo "✗ Installations-Backup-Pfad ist bereits belegt: $BACKUP" >&2; exit 1; }
DEST_EXISTED=0
[ -e "$DEST" ] && DEST_EXISTED=1
INSTALL_STATE="staged"

rollback_install() {
  local status="$?" rollback_ok=1
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    if [ "$DEST_EXISTED" -eq 1 ] && [ -e "$BACKUP" ]; then
      if /usr/bin/swift - "$BACKUP" "$DEST" <<'SWIFT'
import Foundation

let fileManager = FileManager.default
let backup = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
if fileManager.fileExists(atPath: destination.path) {
    _ = try fileManager.replaceItemAt(
        destination,
        withItemAt: backup,
        backupItemName: nil,
        options: [.usingNewMetadataOnly]
    )
} else {
    try fileManager.moveItem(at: backup, to: destination)
}
SWIFT
      then
        echo "⚠ Fehlgeschlagene Installation wurde auf das vorige Bundle zurückgerollt." >&2
      else
        rollback_ok=0
        echo "✗ KRITISCH: Rollback fehlgeschlagen; vorige App liegt unter $BACKUP" >&2
      fi
    elif [ "$DEST_EXISTED" -eq 0 ] && [ "$INSTALL_STATE" = "replacing" ] && [ -e "$DEST" ]; then
      if mv "$DEST" "$STAGED"; then
        echo "⚠ Fehlgeschlagene Erstinstallation wurde entfernt." >&2
      else
        rollback_ok=0
        echo "✗ KRITISCH: Fehlgeschlagene Erstinstallation konnte nicht entfernt werden: $DEST" >&2
      fi
    fi
  fi
  rm -rf "$STAGED"
  if [ "$status" -eq 0 ]; then rm -rf "$BACKUP"; fi
  [ "$rollback_ok" -eq 1 ] || exit 1
  exit "$status"
}
trap rollback_install EXIT
ditto "$APP" "$STAGED"

# Die tatsächlich kopierte Staging-App vollständig prüfen. Nur so kann ein
# Kopierfehler nicht erst auffallen, nachdem die vorige Installation ersetzt ist.
codesign --verify --deep --strict "$STAGED"
xcrun stapler validate "$STAGED"
spctl --assess --type execute -vv "$STAGED" 2>&1 | sed 's/^/    /'
STAGED_RESOURCE_BIN="$STAGED/Contents/Resources/HoerbuchkloepplerCore_HoerbuchkloepplerCore.bundle/Contents/Resources/bin"
"$STAGED_RESOURCE_BIN/ffmpeg" -version >/dev/null 2>&1 \
  || { echo "✗ Gebündeltes ffmpeg startet im Staging-Bundle nicht." >&2; exit 1; }
"$STAGED_RESOURCE_BIN/mediainfo" --Version >/dev/null 2>&1 \
  || { echo "✗ Gebündeltes mediainfo startet im Staging-Bundle nicht." >&2; exit 1; }

INSTALL_STATE="replacing"
/usr/bin/swift - "$STAGED" "$DEST" "$BACKUP_BASENAME" <<'SWIFT'
import Foundation

let fileManager = FileManager.default
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
if fileManager.fileExists(atPath: destination.path) {
    _ = try fileManager.replaceItemAt(
        destination,
        withItemAt: source,
        backupItemName: CommandLine.arguments[3],
        options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
    )
} else {
    try fileManager.moveItem(at: source, to: destination)
}
SWIFT

# ── 5. Verifizieren: Signatur, Gatekeeper und gebündeltes ffmpeg im DEST ─────
codesign --verify --deep --strict "$DEST"
# spctl bewertet zusätzlich die Gatekeeper-Freigabe der installierten Kopie.
spctl --assess --type execute -vv "$DEST" 2>&1 | sed 's/^/    /'
DEST_RESOURCE_BIN="$DEST/Contents/Resources/HoerbuchkloepplerCore_HoerbuchkloepplerCore.bundle/Contents/Resources/bin"
"$DEST_RESOURCE_BIN/ffmpeg" -version >/dev/null 2>&1 \
  || { echo "✗ Gebündeltes ffmpeg startet nach der Installation nicht." >&2; exit 1; }
"$DEST_RESOURCE_BIN/mediainfo" --Version >/dev/null 2>&1 \
  || { echo "✗ Gebündeltes mediainfo startet nach der Installation nicht." >&2; exit 1; }
log "Gebündelte Laufzeitprogramme im installierten Bundle sind ausführbar."

# Erst nach allen Zielprüfungen ist das alte Bundle entbehrlich. Der EXIT-Trap
# hält es bis hierhin als atomar einwechselbares Rollback bereit.
INSTALL_STATE="verified"
trap - EXIT
if ! rm -rf "$BACKUP" "$STAGED"; then
  echo "⚠ Die geprüfte neue App bleibt installiert; ein Backup-/Staging-Rest konnte nicht entfernt werden:" >&2
  echo "  $BACKUP" >&2
  echo "  $STAGED" >&2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")"
echo
echo "INSTALL OK: $DEST ($VERSION)"
