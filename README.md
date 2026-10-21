# Reading DNA

Offline reading profile for KOReader's Bookshelf micro-modules. It summarizes reading regularity, inferred session length, focused days, reading breadth, night-time share, book changes, streaks, and weekend reading.

Current development version: `0.4.2`.

Reading DNA is a descriptive reading summary, not a psychological assessment. Measures stay in their original units; small samples are marked provisional. Reader-pattern traits need at least 14 active days and 5 hours of recorded reading overall.

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

## Releases

After Kindle compatibility checks pass, tagged GitHub releases publish a ZIP containing `reading_dna.lua`, this README, the changelog, and license. Copy `reading_dna.lua` from the archive into `koreader/settings/bookshelf/micromodules/`. Release tags must match the module version (for example, `v0.2.1`).

## Settings

Long-press the card, then choose **Module settings**:

- Analysis window: 30, 90, or 365 days.
- Night interval: 20:00–06:00, 21:00–04:00, or 22:00–05:00, using device-local time.
- Show or hide reader-pattern traits.

Changing the analysis window or night interval starts analysis automatically. Trait-display choice applies without rerunning analysis. Tap the card any time to refresh statistics.

## Metrics

- **Reading regularity:** reading days divided by the recorded-history span inside the selected window. The span starts at the earliest positive-duration event in KOReader's statistics database. Days with no reading count as non-reading days. This is not proof that KOReader recorded data on every day in that span.
- **Session length:** median duration of inferred sessions. Events belong to one session when the gap between them is at most 20 minutes. Sessions under one minute are excluded and sessions are capped at 6 hours; at least 3 sessions are needed for a stable pattern label.
- **Focused days:** count and share of reading days where one book accounts for at least 60% of that day's recorded reading time. Requires 5 reading days for a stable pattern label.
- **Reading breadth:** distinct book IDs plus distinct author metadata strings. Author strings are not verified people; a combined multi-author field counts as one entry. The two counts remain separate; no blended score is calculated.
- **Night-time share:** share of recorded reading seconds inside the selected night interval, using device-local time. The interval is configurable; this is a schedule description, not a quality rating. Requires at least 60 minutes recorded.
- **Book changes:** count and percentage of adjacent valid-session transitions where the book changed. The denominator is `valid sessions − 1`; at least 4 valid sessions are needed for a stable pattern label.
- **Longest reading streak:** longest run of consecutive local calendar days with reading events.
- **Weekend reading:** share of recorded time on Saturday and Sunday, plus number of weekend days with reading.

No 0–100 scores are shown: those earlier scales mixed unlike quantities and implied a quality ranking. Measures with small samples remain visible with a provisional note. The overall profile requires at least 14 active days and 5 hours recorded. Qualified pattern traits appear together rather than competing for one archetype: Steady (35%+ of history days), Long-session (30-minute median across 3+ sessions), Short-session (15-minute median or less across 5+ sessions), Focused (60%+ focused days), Explorer (8+ books), Night Owl (40%+ within selected night hours and 3+ hours recorded), Book Hopper (40%+ changed transitions across 4+ sessions), Streak Builder (5 consecutive reading days), and Weekend Regular (50%+ of reading time on weekends, across 4+ weekend reading days). These are descriptive labels, not goals or judgments.

The full-screen Fingerprint view uses a varied-height book shelf and eight compact evidence cards. Values stay in their original units; definitions appear beneath them. Where both equal-length windows have at least 3 active days and 30 minutes recorded, the view compares active days and minutes with the immediately preceding window.

Overlapping event intervals are clipped to the earliest event, preventing duplicated reading time. “History days” are a calendar span inferred from the earliest event, not a completeness guarantee. Session and book counts depend on KOReader's event data and metadata quality.

Completion is not scored: the statistics database does not provide reliable finished-state evidence. Genre exploration is omitted when metadata may be incomplete.

## Data and privacy

- Reads `statistics.sqlite3` in SQLite read-only mode.
- Uses `page_stat_data` events and `book` author metadata.
- Does not access the network, write to the statistics database, change book progress, or read book contents.
- Queries run after a tap or an analysis-setting change, in batches of up to 100 rows per UI tick. Card rendering uses cached aggregates and does not query SQLite.
- Saves only the aggregate profile through Bookshelf's `Kit.moduleStore("reading_dna")`.

## Repository layout

```text
micromodules/
  reading_dna.lua              Installable Bookshelf module
docs/
  DEVELOPMENT.md               Architecture and implementation notes
tests/
  test_reading_dna.lua          Lua regression checks
  test_statistics_fixture.py    SQLite schema/query fixture
.github/workflows/test.yml     Lua 5.1 test workflow
scripts/package_release.py     Reproducible install ZIP builder
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

