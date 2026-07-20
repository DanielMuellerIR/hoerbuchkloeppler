#!/usr/bin/env bash
# notary-profile.sh — public-safe Verwaltung des lokalen notarytool-Profils.
#
# notarytool speichert die Apple-Zugangsdaten (App-spezifisches Passwort,
# Apple-ID, Team-ID) im macOS-Schlüsselbund unter einem Profilnamen.
# Schlüsselbund-Profile werden von iCloud NICHT zwischen Macs synchronisiert,
# also ist das Profil pro Mac einmalig einzurichten.
#
# Dieses Skript legt im Repo/Git NUR den nicht geheimen Profilnamen ab; die
# eigentlichen Credentials bleiben ausschließlich im Schlüsselbund. Der Name
# kommt aus (in dieser Reihenfolge):
#   1. Umgebungsvariable NOTARY_PROFILE
#   2. clone-lokale Git-Config  hoerbuchkloeppler.notaryProfile  (nicht gepusht)
#   3. interaktive Abfrage (Default-Platzhalter "notary")

hoerbuchkloeppler_require_notary_profile() {
  local profile="${NOTARY_PROFILE:-}"

  if [ -z "$profile" ]; then
    profile="$(git config --local --get hoerbuchkloeppler.notaryProfile 2>/dev/null || true)"
  fi

  if [ -z "$profile" ]; then
    if [ ! -t 0 ]; then
      echo "✗ Kein Notary-Profil konfiguriert (kein TTY für Rückfrage)." >&2
      echo "  Profil über Umgebungsvariable setzen:  NOTARY_PROFILE=<profil> ./install.sh" >&2
      echo "  oder clone-lokal (nicht gepusht):       git config --local hoerbuchkloeppler.notaryProfile <profil>" >&2
      return 1
    fi
    printf "Notary-Profilname für diesen Mac [notary]: " >&2
    IFS= read -r profile
    profile="${profile:-notary}"
  fi

  # `history` ist der verlässliche Test: findet gültige Profile zuverlässiger
  # als ein bloßer security-find-generic-password-Check.
  if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    echo "✗ Notary-Profil '$profile' ist auf diesem Mac nicht verwendbar." >&2
    echo "  (Schlüsselbund-Profile werden zwischen Macs nicht synchronisiert;" >&2
    echo "   über SSH ist der Login-Schlüsselbund oft gesperrt.)" >&2
    if [ ! -t 0 ]; then
      echo "  Einmalig in einer lokalen GUI-Terminalsitzung einrichten:" >&2
      echo "  xcrun notarytool store-credentials '$profile' --apple-id '<apple-id>' --team-id '<team-id>'" >&2
      echo "  Das App-spezifische Passwort NUR an der verdeckten Abfrage eingeben, nie als Argument." >&2
      return 1
    fi
    printf "Profil jetzt interaktiv im Schlüsselbund einrichten? [j/N] " >&2
    local answer; IFS= read -r answer
    case "$answer" in
      j|J|ja|Ja|JA|y|Y|yes|Yes|YES) ;;
      *) return 1 ;;
    esac
    local apple_id team_id
    printf "Apple-ID: " >&2;  IFS= read -r apple_id
    printf "Team-ID: "  >&2;  IFS= read -r team_id
    if [ -z "$apple_id" ] || [ -z "$team_id" ]; then
      echo "✗ Apple-ID und Team-ID dürfen nicht leer sein." >&2
      return 1
    fi
    # Absichtlich kein --password: notarytool fragt das App-Passwort verdeckt ab
    # und legt es direkt im lokalen Schlüsselbund ab.
    xcrun notarytool store-credentials "$profile" --apple-id "$apple_id" --team-id "$team_id"
    xcrun notarytool history --keychain-profile "$profile" >/dev/null
  fi

  # Nur der Profilname landet clone-lokal in .git/config (wird nie committet/gepusht).
  git config --local hoerbuchkloeppler.notaryProfile "$profile"
  NOTARY_PROFILE="$profile"
  export NOTARY_PROFILE
}
