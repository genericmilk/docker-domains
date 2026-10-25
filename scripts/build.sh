#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
swift scripts/make-icon.swift
iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
app="$PWD/dist/Docker Domains.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/DockerDomains "$app/Contents/MacOS/DockerDomains"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign "${SIGNING_IDENTITY:--}" "$app"
print "Built $app"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  ditto "$app" "$HOME/Applications/Docker Domains.app"
  print "Installed $HOME/Applications/Docker Domains.app"
fi
