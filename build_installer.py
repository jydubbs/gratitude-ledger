"""Assembles install-gratitude-ledger.sh: one script with the Swift source and sounds embedded."""
import base64
import hashlib
import pathlib

ROOT = pathlib.Path(__file__).parent
SRC = ["App.swift", "Models.swift", "Store.swift", "Services.swift", "Updater.swift", "LedgerView.swift", "YearGrid.swift"]
SOUNDS = ["clack1", "clack2", "clack3", "bell"]

HEAD = r'''#!/bin/bash
# The Gratitude Ledger: installer.
# Builds a small menu-bar journal app on this Mac and starts it.
# Run with:  bash ~/Downloads/install-gratitude-ledger.sh
set -euo pipefail

APP_NAME="Gratitude Ledger"
EXEC="GratitudeLedger"
BUILD="__BUILD__"   # fingerprint of src/ and sounds/; the app compares it with VERSION on GitHub
BUNDLE_ID="com.gratitudeledger.app"
DEST="$HOME/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

say() { printf '\n  %s\n' "$*"; }

if [[ "$(uname)" != "Darwin" ]]; then
  say "This installer is for macOS."
  exit 1
fi

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MAJOR < 13 )); then
  say "The Gratitude Ledger needs macOS 13 (Ventura) or newer. This Mac has $(sw_vers -productVersion)."
  exit 1
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  say "One-time step: Apple's free Command Line Tools are needed to build the app."
  say "A window will pop up. Click Install, wait for it to finish (a few minutes),"
  say "then run this same command again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/sounds"

say "Unpacking the ledger…"
'''

TAIL = r'''
say "Building (this takes about a minute)…"
ARCH="$(uname -m)"
xcrun swiftc -O -parse-as-library \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "${ARCH}-apple-macos13.0" \
  "$WORK"/src/*.swift \
  -o "$WORK/$EXEC"

say "Binding the pages…"
GUI="gui/$(id -u)"
# Stop the running ledger (and its start-at-login job) before replacing it.
launchctl bootout "$GUI/$BUNDLE_ID" >/dev/null 2>&1 || true
pkill -x "$EXEC" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x "$EXEC" >/dev/null 2>&1 || break
  sleep 0.5
done
pkill -9 -x "$EXEC" >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$WORK/$EXEC" "$DEST/Contents/MacOS/$EXEC"
cp "$WORK"/sounds/*.wav "$DEST/Contents/Resources/"

cat > "$DEST/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>GLBuildHash</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST_EOF

codesign --force --sign - "$DEST" >/dev/null 2>&1 || true

# Start at login, and have macOS restart the ledger if it ever quits unexpectedly.
# Choosing "quit" in the gear menu is respected: it stays closed until the next login.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<AGENT_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST/Contents/MacOS/$EXEC</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>AbandonProcessGroup</key><true/>
</dict>
</plist>
AGENT_EOF

# Load the job now (this also starts the ledger). Retry briefly in case the old job is still unloading.
STARTED=no
for _ in 1 2 3 4 5; do
  if launchctl bootstrap "$GUI" "$AGENT" >/dev/null 2>&1; then STARTED=yes; break; fi
  sleep 1
done
if [[ "$STARTED" != yes ]]; then
  open "$DEST"
fi

say "Done. Look for the little closed book in your menu bar (top right)."
say "Your entries are kept in iCloud Drive > Gratitude Ledger > entries.json"
say "To uninstall later:  launchctl bootout $GUI/$BUNDLE_ID; rm -rf \"$DEST\" \"$AGENT\""
echo
'''


def build_hash() -> str:
    """Changes whenever any source file, sound or the installer itself changes."""
    h = hashlib.sha256()
    h.update(HEAD.encode() + b"\0" + TAIL.encode() + b"\0")
    for name in SRC:
        h.update(name.encode() + b"\0" + (ROOT / "src" / name).read_bytes() + b"\0")
    for name in SOUNDS:
        h.update(name.encode() + b"\0" + (ROOT / "sounds" / f"{name}.wav").read_bytes() + b"\0")
    return h.hexdigest()[:12]


def main():
    build = build_hash()
    parts = [HEAD.replace("__BUILD__", build)]
    for name in SRC:
        code = (ROOT / "src" / name).read_text()
        assert "SWIFT_EOF" not in code
        parts.append(f"cat > \"$WORK/src/{name}\" <<'SWIFT_EOF'\n{code.rstrip()}\nSWIFT_EOF\n\n")
    for name in SOUNDS:
        b64 = base64.encodebytes((ROOT / "sounds" / f"{name}.wav").read_bytes()).decode()
        parts.append(f"base64 --decode > \"$WORK/sounds/{name}.wav\" <<'B64_EOF'\n{b64.rstrip()}\nB64_EOF\n\n")
    parts.append(TAIL)
    out = ROOT / "install-gratitude-ledger.sh"
    out.write_text("".join(parts))
    out.chmod(0o755)
    (ROOT / "VERSION").write_text(build + "\n")
    print(out, out.stat().st_size, "build", build)


if __name__ == "__main__":
    main()
