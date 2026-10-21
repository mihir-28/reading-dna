# Reading DNA

Offline reading profile for KOReader's Bookshelf micro-modules. It summarizes recent reading patterns as consistency, inferred session depth, book loyalty, exploration, night reading, and book switching.

Reading DNA is a descriptive, playful summary, not a psychological assessment. Scores are hidden when evidence is too limited. Archetypes stay provisional until the selected window contains at least 14 active days and 5 hours of recorded reading.

## Requirements

- KOReader with the Bookshelf plugin.
- KOReader Reading statistics plugin enabled.
- Bookshelf micro-module API with `lib/bookshelf_module_kit` and user micro-module discovery.

Targeted against KOReader `v2026.07.1` and Bookshelf installed on a Kindle. Other Bookshelf releases may differ; see [development notes](docs/DEVELOPMENT.md).

## Install

1. Back up the device's `koreader/settings/bookshelf/` folder.
2. Copy [`micromodules/reading_dna.lua`](micromodules/reading_dna.lua) to `koreader/settings/bookshelf/micromodules/reading_dna.lua` on the device.
3. Safely eject and restart KOReader.
4. Add **Reading DNA** from Bookshelf's micro-module picker.
5. Tap the card to analyze or refresh. Long-press it for settings.

On Kindle, the USB-visible path is usually `koreader/settings/bookshelf/micromodules/`. The module needs no registry entry or Bookshelf source patch. Remove the one Lua file to uninstall it.

## Settings

Long-press the card, then choose **Module settings**:

- Analysis window: 30, 90, or 365 days.
- Night interval: 20:00–06:00, 21:00–04:00, or 22:00–05:00, using device-local time.
- Show or hide scores.
- Show or hide archetype.

Changing a setting clears the cached summary. Tap the card to recalculate.

## Metrics

- **Consistency:** local calendar days with reading events divided by selected window days. Score shown after at least 3 active days and 30 minutes recorded.
- **Session depth:** median duration of inferred sessions, grouped across gaps of at most 20 minutes. Score reaches 100 at a 60-minute median; requires at least 3 sessions.
- **Book loyalty:** share of active days where one book accounts for at least 60% of recorded reading time; requires 5 active days.
- **Exploration:** half the score comes from distinct books (10 reaches that half's maximum); half from distinct author entries (5 reaches that half's maximum); requires 3 books.
- **Night reading:** share of recorded reading seconds inside the selected night interval; requires at least 60 minutes.
- **Book switching:** share of adjacent inferred sessions involving a different book; requires at least 4 sessions.

Scores are simple descriptive scales, not validated measures. Archetype rules use thresholds: Deep Diver (depth and loyalty ≥65), Explorer (exploration ≥65), Marathoner (depth ≥60 and consistency ≥65), Night Owl (night reading ≥60), and Wanderer (switching ≥70). The evidence gate applies before assigning an archetype. Otherwise, the card shows Mixed Reader provisionally.

Completion is not scored: the statistics database does not provide reliable finished-state evidence. Genre exploration is omitted when metadata may be incomplete.

## Data and privacy

- Reads `statistics.sqlite3` in SQLite read-only mode.
- Uses `page_stat_data` events and `book` author metadata.
- Does not access the network, write to the statistics database, change book progress, or read book contents.
- Queries run only after a tap. Card rendering uses cached aggregates and does not query SQLite.
- Saves only the aggregate profile through Bookshelf's `Kit.moduleStore("reading_dna")`.

## Repository layout

```text
micromodules/
  reading_dna.lua              Installable Bookshelf module
docs/
  DEVELOPMENT.md               Architecture and implementation notes
CHANGELOG.md                    Release history
LICENSE                         AGPL-3.0-only
README.md                       User and installation guide
```

## Credits

Built for [Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin) and [KOReader](https://github.com/koreader/koreader). Reading data comes from KOReader's [Statistics plugin](https://github.com/koreader/koreader/tree/master/plugins/statistics.koplugin).

## License

GNU Affero General Public License v3.0 only. See [LICENSE](LICENSE).

## Upstream projects

- [KOReader](https://github.com/koreader/koreader)
- [Bookshelf plugin](https://github.com/AndyHazz/bookshelf.koplugin)
- [KOReader Statistics plugin source](https://github.com/koreader/koreader/tree/master/plugins/statistics.koplugin)

