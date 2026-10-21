# Development notes

## Target and module contract

Target device runs KOReader `v2026.07.1` with Bookshelf installed. The installed contract describes a micro-module as a Lua file returning a spec table with a stable `key`, `title`, `summary`, and `render(ctx)`. The host sizes the card and provides `ctx.scale`, `ctx.surface`, and related context. User modules belong under `settings/bookshelf/micromodules/`; no registry edit is needed.

The module uses Bookshelf's `lib/bookshelf_module_kit` for value cards, scaling, grayscale color roles, and `Kit.moduleStore("reading_dna")`. The three full-screen layouts are presentation functions in the same installable file; they share one snapshot and calculation path. Their preference uses the namespaced `reading_dna_layout` entry field; avoid Bookshelf's generic `layout` field. Compact cards retain their existing renderer. Keeping one file preserves the direct-copy install step.

## Data access

The stats adapter resolves `statistics.sqlite3` through `datastorage`, opens it with SQLite read-only mode, sets a short busy timeout, uses a parameterized time range, and closes the connection after each explicit analysis. It selects raw `page_stat_data` rows joined to `book`. Do not switch to `page_stat`: that view expands/rescales page rows and is not the event source for session grouping.

Rendering never queries SQLite. Tap or changing the analysis window/night interval schedules read-only query batches of up to 100 rows across UI ticks, then persists only the aggregate snapshot. Newer analysis requests supersede older pending results. Preview draws static sample text. Missing DB, failed query, empty history, and pending analysis have separate UI states.

The tap reads twice the selected period once. The calculation splits those rows into current and immediately previous equal-length local-calendar windows. It reports active-day and minute deltas only when each window has at least 3 active days and 30 recorded minutes.

## Known measurement limits

- A “session” is inferred from event timestamps and a 20-minute gap; KOReader does not store a session ID in this table.
- Event durations approximate reading time. Night allocation splits each event duration across device-local hours.
- Book authors are metadata strings; incomplete or inconsistent metadata weakens exploration counts.
- Completion and genre scores are intentionally omitted.
- Archetype labels are descriptive and provisional below the evidence gate.

## Device review checklist

- Check picker preview, hero card, and all three full-screen layouts.
- Check touch interaction, long-press settings, refresh, suspend/resume, and cold start.
- Check empty, missing, and locked statistics database states.
- Compare displayed totals against read-only SQL on the same device.
- Check 167-ppi grayscale legibility and render latency.
- Back up Bookshelf settings before copying the module; uninstall by removing the module file.

## Regression tests

Run `lua tests/test_reading_dna.lua` with Lua 5.1. Synthetic checks cover empty and short histories, interval overlaps, free-form author metadata, local calendar boundaries, async batch limits, and query/schema errors. `python -m unittest discover -s tests -p "test_*.py"` also exercises the statistics SELECT against a real SQLite fixture matching the inspected schema. The production module exposes Lua test helpers only when `READING_DNA_TEST` is set.

Build a local install archive with `python scripts/package_release.py`. The script checks that the module version has a changelog entry and writes `dist/reading-dna-v<version>.zip`. Only tag a release after manual Kindle checks; the release workflow rejects a tag that differs from the module version.

## Local references

Device-source snapshots and the inspection summary are kept in the workspace's ignored `references/` folder. They are excluded from this repository so version snapshots and local development material do not ship with the module.
