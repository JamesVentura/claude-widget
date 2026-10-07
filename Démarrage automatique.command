#!/bin/bash
# Double-clique une seule fois : le widget se lancera à chaque ouverture de session.
cd "$(dirname "$0")" || exit 1
BIN="$(pwd)/Claude Widget.app/Contents/MacOS/ClaudeWidget"
PLIST="$HOME/Library/LaunchAgents/com.elise.claude-widget.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.elise.claude-widget</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PL
launchctl unload "$PLIST" 2>/dev/null
launchctl load "$PLIST" && echo "✅ Démarrage automatique activé."
echo "Pour le désactiver : launchctl unload \"$PLIST\" && rm \"$PLIST\""
