#!/bin/sh
# SoundScript.app paketini oluşturur ve ~/Applications'a kurar.
# Kullanım: scripts/bundle.sh [--no-install]
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product SoundScriptApp

APP=build/SoundScript.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SoundScriptApp "$APP/Contents/MacOS/SoundScript"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc imza: yerelde çalışır. Dağıtım için Developer ID + notarization gerekir.
codesign --force --sign - "$APP"

if [ "${1:-}" != "--no-install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/SoundScript.app"
    cp -R "$APP" "$HOME/Applications/"
    # Finder'ın "Şununla Aç" listesi ve Hizmetler menüsü için kaydı yenile
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/SoundScript.app"
    /System/Library/CoreServices/pbs -update
    echo "Kuruldu: $HOME/Applications/SoundScript.app"
else
    echo "Hazır: $APP"
fi
