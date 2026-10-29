# The Gratitude Ledger

A small macOS menu bar journal. Each day you write what you're grateful for and tap how you feel. The year fills in as a grid of coloured squares based on the dominant emotion of the day, styled with the aesthetic like an old typed ledger.

## Credits

- **Planning and editing:** [@jydubbs](https://github.com/jydubbs). The idea, every design decision (features, emotions, colours, style, behaviour), testing on a real Mac, and the changes made after using it.
- **Code:** written by Claude (Anthropic), following that plan.

## What it does

- **One page a day.** Write your gratitude (max 1000 char) and press Return to seal the page, which rings a typewriter bell. You can edit today's page, and you can still fill in yesterday's if you forgot.
- **Feelings.** Choose from happy, excited, calm, grateful, tired, sad, anxious and angry. Tap a feeling once, twice or three times for mild, medium or strong. The strongest one colours that day's square, and stronger feelings give deeper ink.
- **The year grid.** Each daily submission is saved in a calendar grid-like format. Hover over a square to peek at that day, and click it to keep the page open. Long pages scroll.
- **Search and "on this day".** Search lights up every square that matches the word entered. "On this day" shows what you wrote on this date a year ago.
- **Menu bar book.** The book in the menu bar stays closed until today's page is written. An optional evening reminder arrives if the page is still blank.
- **Your data.** Entries are saved as plain JSON in **iCloud Drive › Gratitude Ledger › entries.json**, with a local backup.
- **When a day ends.** Each day runs until 4am, so writing late at night still counts for that day.

## Install

You need a Mac running macOS 13 (Ventura) or newer. To check, open the Apple menu  and choose About This Mac.

### Quick install (recommended)

You don't need to download anything first. The command fetches the installer from this repo and runs it.

1. Open **Terminal**. Press ⌘ Space, type `Terminal`, and press Return.
2. Copy this whole line, paste it into Terminal and press Return:

   ```
   curl -fsSL https://raw.githubusercontent.com/jydubbs/gratitude-ledger/main/install-gratitude-ledger.sh | bash
   ```

3. Wait about a minute while it builds. When it's done, it prints **Done**, and a small closed book appears in your menu bar at the top right of the screen.

**The first time only:** if your Mac doesn't have Apple's free Command Line Tools, a window will pop up asking to install them. Click **Install**, wait for it to finish (a few minutes), then do step 2 again.

### Or download the installer yourself

1. Click [`install-gratitude-ledger.sh`](install-gratitude-ledger.sh) in the file list above, then click the download button (↓ Download raw file) at the top right of the file view.
2. Open Terminal and run:

   ```
   bash ~/Downloads/install-gratitude-ledger.sh
   ```

   If your browser saved it under a different name, for example `install-gratitude-ledger (1).sh`, use that name instead.

### Can't see the book?

If your menu bar is full, macOS hides icons behind the camera notch without telling you. To free up space, go to **System Settings › Control Centre** (called **Menu Bar** on newer macOS) and set a few built-in items to "Don't show in Menu Bar", such as Bluetooth, Now Playing or Spotlight. They stay available in Control Centre.

### Updating

The app checks this repo about once a day. When there's a new version, a banner saying **"a new edition of the ledger is available"** appears at the top of the drop-down. Click **update**, and the ledger closes and reopens with the new version in about a minute. To check right away, open the gear menu and click **check for updates**.

You can also update at any time by running the quick install command again. Either way, your entries are not affected, because they live in iCloud Drive, not in the app.

Versions installed before the update checker was added can't check for updates, so run the quick install command once to get it.

### Uninstalling

To uninstall, run this in Terminal:

```
launchctl bootout gui/$(id -u)/com.gratitudeledger.app; rm -rf ~/Applications/"Gratitude Ledger.app" ~/Library/LaunchAgents/com.gratitudeledger.app.plist
```

This removes the app but leaves your entries in iCloud Drive › Gratitude Ledger.

## Repo layout

- `src/` contains the SwiftUI app.
- `sounds/` contains the typewriter key and bell sounds, which were synthesised for this project.
- `build_installer.py` packs `src/` and `sounds/` into the single `install-gratitude-ledger.sh`. It also writes `VERSION`, a fingerprint of the code that installed apps compare against to decide whether an update is available.
- **After changing anything in `src/` or `sounds/`, run `python3 build_installer.py` and commit all three: your change, `install-gratitude-ledger.sh` and `VERSION`.** If you skip this, nobody's app will see the change.
