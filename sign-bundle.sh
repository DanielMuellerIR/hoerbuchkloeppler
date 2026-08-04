#!/usr/bin/env bash
# sign-bundle.sh — signiert Hörbuchklöpplers eingebettete Programme von innen
# nach außen. Reihenfolge ist wichtig: verschachtelte Mach-O-Dateien und ein
# gegebenenfalls dynamisch eingebettetes Framework MÜSSEN vor dem äußeren
# App-Bundle signiert werden, sonst bricht die äußere Signatur sie wieder auf.
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

# Ad-hoc-Builds brauchen weder Hardened Runtime noch einen Netz-Zeitstempel.
# Verteilbare Builds erhalten beides mit derselben Developer ID.
SIGN_ARGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

# --- Spuren des Build-Macs entfernen, BEVOR signiert wird ---------------------
# (strip und Löschen machen eine vorhandene Signatur ungültig, deshalb hier und
# nicht später.) Gefunden am 2026-08-04 in der ausgelieferten App: An zwei
# Stellen stand der volle Pfad dieses Macs.
#
# 1. Debug-Map in den Binärdateien. Der Compiler notiert für jede übersetzte
#    Quelldatei den vollen Pfad ihrer .o-Datei. `strip -S` nimmt genau diese
#    Debug-Symbole und lässt die normale Symboltabelle stehen, damit
#    Absturzberichte lesbar bleiben. Angefasst werden nur die eigenen
#    Binärdateien; ffmpeg und mediainfo kommen fertig von außen.
for eigene in "$APP/Contents/MacOS/"* "$FRAMEWORK/Versions/A/HoerbuchkloepplerCore"; do
  [ -f "$eigene" ] || continue
  if file -b "$eigene" 2>/dev/null | grep -q 'Mach-O'; then
    strip -S "$eigene"
  fi
done

# 2. Die Modules-Dateien des Frameworks (.swiftmodule und vor allem
#    .swiftsourceinfo) enthalten Quelldateipfade — .swiftsourceinfo ist genau
#    dafür da. Gebraucht werden sie nur, um GEGEN das Framework zu übersetzen;
#    zur Laufzeit liest sie niemand. In einer ausgelieferten App haben sie
#    nichts verloren.
if [ -d "$FRAMEWORK/Versions/A/Modules" ]; then
  rm -rf "$FRAMEWORK/Versions/A/Modules"
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

# Das Xcode-Projekt bindet den SwiftPM-Core derzeit statisch ein. Sollte Xcode
# ihn später wieder als dynamisches Framework ausgeben, bleibt die notwendige
# Reihenfolge hier trotzdem korrekt.
if [ -d "$FRAMEWORK" ]; then
  codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
fi

# Zuletzt das äußere App-Bundle; das signiert Contents/MacOS/Hörbuchklöppler und
# versiegelt alle Ressourcen.
codesign "${SIGN_ARGS[@]}" "$APP"

# --deep nur zum PRÜFEN (beim Signieren wäre es falsch).
codesign --verify --deep --strict --verbose=2 "$APP"
