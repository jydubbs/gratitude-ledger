# The Gratitude Ledger

A small macOS menu bar journal. Each day you write what you're grateful for and tap how you feel. The year fills in as a grid of coloured squares, styled like an old typed ledger.

## Credits

- **Planning and editing:** [@jydubbs](https://github.com/jydubbs). The idea, every design decision (features, emotions, colours, style, behaviour), testing on a real Mac, and the changes made after using it.
- **Code:** written by Claude (Anthropic), following that plan.

## What it does

- **One page a day.** Write your gratitude and press Return to seal the page, which rings a typewriter bell. You can edit today's page, and you can still fill in yesterday's if you forgot.
- **Feelings.** Choose from happy, excited, calm, grateful, tired, sad, anxious and angry. Tap a feeling once, twice or three times for mild, medium or strong. The strongest one colours that day's square, and stronger feelings give deeper ink.
- **The year grid.** A GitHub-style grid of the calendar year. Hover over a square to peek at that day, and click it to keep the page open. Long pages scroll.
- **Search and "on this day".** Search lights up every square that matches. "On this day" shows what you wrote on this date a year ago.
- **Menu bar book.** The book in the menu bar stays closed until today's page is written. An optional evening reminder arrives if the page is still blank.
- **Your data.** Entries are saved as plain JSON in **iCloud Drive › Gratitude Ledger › entries.json**, with a local backup.
- **When a day ends.** Each day runs until 4am, so writing late at night still counts for that day.

## Install

You need macOS 13 (Ventura) or newer. Open Terminal and paste:

```
curl -fsSL https://raw.githubusercontent.com/jydubbs/gratitude-ledger/main/install-gratitude-ledger.sh | bash
```

The first time, macOS may ask you to install Apple's free Command Line Tools. Install them, then paste the command again.

To update, paste the same command again. Your entries are not affected, because they live in iCloud, not in the app.

To uninstall:

```
rm -rf ~/Applications/"Gratitude Ledger.app" ~/Library/LaunchAgents/com.gratitudeledger.app.plist
```

## Repo layout

- `src/` contains the SwiftUI app.
- `sounds/` contains the typewriter key and bell sounds, which were synthesised for this project.
- `build_installer.py` packs `src/` and `sounds/` into the single `install-gratitude-ledger.sh`. Re-run it after changing either folder.
