#!/usr/bin/env bash
# sign-bundle.sh — signiert Hörbuchklöpplers eingebettete Programme von innen
# nach außen. Reihenfolge ist wichtig: verschachtelte Mach-O-Dateien und das
# Framework MÜSSEN vor dem äußeren App-Bundle signiert werden, sonst bricht die
# äußere Signatur die inneren wieder auf.
#
# Aufruf: ./sign-bundle.sh <Hörbuchklöppler.app> <codesign-identity-oder->
#   Identität "-" = Ad-hoc (lokaler Test, ohne Hardened Runtime/Zeitstempel).
#   Echte "Developer ID Application: …" = verteilbar + notarisierbar.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Aufruf: ./sign-bundle.sh <Hörbuchklöppler.app> <codesign-identity-oder->" >&2
  exit 2
fi

APP="$1"
IDENTITY="$2"
FRAMEWORK="$APP/Contents/Frameworks/HoerbuchkloepplerCore.framework"

[ -d "$APP" ] || { echo "✗ App-Bundle fehlt: $APP" >&2; exit 1; }
[ -d "$FRAMEWORK" ] || { echo "✗ HoerbuchkloepplerCore.framework fehlt im Bundle." >&2; exit 1; }

# Ad-hoc-Builds brauchen weder Hardened Runtime noch einen Netz-Zeitstempel.
# Verteilbare Builds erhalten beides mit derselben Developer ID.
SIGN_ARGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

# Die gebündelten Tools ffmpeg und mediainfo liegen als Mach-O in einer
# SwiftPM-Ressourcen-Bundle unter Contents/Resources. Sie sind eigenständige
# Programme (keine Frameworks/Helpers) und müssen einzeln signiert werden — eine
# äußere Bundle-Signatur erfasst sie nicht korrekt. (Beide linken nur gegen
# System-Bibliotheken, daher kein Library-Validation-Entitlement nötig.)
while IFS= read -r -d '' embedded_file; do
  if file -b "$embedded_file" 2>/dev/null | grep -q 'Mach-O'; then
    codesign "${SIGN_ARGS[@]}" "$embedded_file"
  fi
done < <(find "$APP/Contents/Resources" -type f -print0)

# Dann der geteilte Core als Framework, dann das äußere App-Bundle (signiert
# zugleich Contents/MacOS/Hörbuchklöppler und versiegelt alles Innere).
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
codesign "${SIGN_ARGS[@]}" "$APP"

# --deep nur zum PRÜFEN (beim Signieren wäre es falsch).
codesign --verify --deep --strict --verbose=2 "$APP"
