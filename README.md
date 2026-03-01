# ios-ui

Minimal iOS chat UI for OpenClaw.

## What this is

- Simple SwiftUI chat app (no terminal UI)
- Talks to a tiny HTTP bridge on `bici-server`
- Bridge calls `openclaw agent --message ...` and returns the reply

This avoids WhatsApp and avoids terminal emulation.

## Repo layout

- `Sources/IOSUIApp/*` — iOS app
- `server/chat_bridge.py` — local bridge server on bici-server

## Requirements

- iOS 16+
- Xcode 15+ recommended
- `openclaw` installed on bici-server

## 1) Run bridge on bici-server

On bici-server:

python3 /Users/bici/.openclaw/workspace/thb-bici/ios-ui/server/chat_bridge.py

Bridge listens on all interfaces by default:

http://0.0.0.0:8787

### Run bridge as a persistent background service (recommended)

Install LaunchAgent (auto-start + auto-restart on crash):

```bash
cat > ~/Library/LaunchAgents/com.bici.ios-ui-chat-bridge.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.bici.ios-ui-chat-bridge</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string>
    <string>/Users/bici/.openclaw/workspace/thb-bici/ios-ui/server/chat_bridge.py</string>
  </array>
  <key>WorkingDirectory</key><string>/Users/bici/.openclaw/workspace/thb-bici/ios-ui/server</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/bici/.openclaw/workspace/logs/ios-ui-chat-bridge.log</string>
  <key>StandardErrorPath</key><string>/Users/bici/.openclaw/workspace/logs/ios-ui-chat-bridge.err.log</string>
</dict></plist>
PLIST

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.bici.ios-ui-chat-bridge.plist
launchctl enable gui/$(id -u)/com.bici.ios-ui-chat-bridge
launchctl kickstart -k gui/$(id -u)/com.bici.ios-ui-chat-bridge
```

Useful commands:

```bash
launchctl print gui/$(id -u)/com.bici.ios-ui-chat-bridge
launchctl kickstart -k gui/$(id -u)/com.bici.ios-ui-chat-bridge
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.bici.ios-ui-chat-bridge.plist
```

For iPhone access over Tailscale, use your server tailnet address:

`http://$(tailscale ip -4):8787`

Example: `http://100.73.55.46:8787`

## 2) Open app in Xcode

- Clone repo
- Open `Package.swift` in Xcode
- Select `IOSUIApp` scheme
- Run on iPhone

## 3) Configure app

In app top fields:
- **Backend URL**: bridge URL reachable from iPhone (example `http://100.x.y.z:8787`)
- **Session Key**: any stable label (example `ios-ui`)

Then send messages.

## Notes

- Keep bridge private (tailnet only)
- Do not expose bridge to public internet without auth
