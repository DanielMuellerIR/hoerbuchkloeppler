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

# `notarytool history` liefert auf manchen Macs sporadisch einen falschen
# Profilfehler. Jeder Aufrufer — auch direkt nach `store-credentials` — nutzt
# deshalb denselben begrenzten Retry.
hoerbuchkloeppler_notary_profile_works() {
  local profile="$1" attempt
  for attempt in 1 2 3 4 5; do
    if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
      return 0
    fi
    [ "$attempt" -eq 5 ] || sleep 3
  done
  return 1
}

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
  #
  # Fünf Versuche statt einem: `history` meldet gelegentlich fälschlich „No
  # Keychain password item found", obwohl das Profil da ist (2026-07-26 auf
  # einem Mac belegt — Versuch 1 fehlgeschlagen, Versuch 2 sofort ok). Ein
  # einzelner Fehlversuch würde sonst einen ganzen Lauf grundlos abbrechen oder
  # unnötig nach store-credentials fragen; ein wirklich fehlendes Profil
  # scheitert auch nach fünf Versuchen.
  if ! hoerbuchkloeppler_notary_profile_works "$profile"; then
    echo "✗ Notary-Profil '$profile' ist auf diesem Mac nicht verwendbar." >&2
    echo "  (Schlüsselbund-Profile werden zwischen Macs nicht synchronisiert;" >&2
    echo "   über SSH ist der Login-Schlüsselbund oft gesperrt.)" >&2
    if [ ! -t 0 ]; then
      echo "  Einmalig in einer lokalen GUI-Terminalsitzung einrichten:" >&2
      printf "  xcrun notarytool store-credentials %q\n" "$profile" >&2
      echo "  Apple-ID, Team-ID und App-spezifisches Passwort nur an den interaktiven Abfragen eingeben." >&2
      return 1
    fi
    printf "Profil jetzt interaktiv im Schlüsselbund einrichten? [j/N] " >&2
    local answer; IFS= read -r answer
    case "$answer" in
      j|J|ja|Ja|JA|y|Y|yes|Yes|YES) ;;
      *) return 1 ;;
    esac
    # Keine Zugangsdaten als Argumente: notarytool fragt Apple-ID, Team-ID und
    # App-Passwort selbst interaktiv ab und schreibt sie direkt in den Schlüsselbund.
    xcrun notarytool store-credentials "$profile"
    if ! hoerbuchkloeppler_notary_profile_works "$profile"; then
      echo "✗ Neu gespeichertes Notary-Profil '$profile' ist nicht verwendbar." >&2
      return 1
    fi
  fi

  # Nur der Profilname landet clone-lokal in .git/config (wird nie committet/gepusht).
  git config --local hoerbuchkloeppler.notaryProfile "$profile"
  NOTARY_PROFILE="$profile"
  export NOTARY_PROFILE
}
