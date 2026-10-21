# Development notes

## Target and module contract

Target device runs KOReader `v2026.07.1` with Bookshelf installed. The installed contract describes a micro-module as a Lua file returning a spec table with a stable `key`, `title`, `summary`, and `render(ctx)`. The host sizes the card and provides `ctx.scale`, `ctx.surface`, and related context. User modules belong under `settings/bookshelf/micromodules/`; no registry edit is needed.

The module uses Bookshelf's `lib/bookshelf_module_kit` for value cards, scaling, grayscale color roles, and `Kit.moduleStore("reading_dna")`. It is intentionally one file so the install step remains a direct copy.

## Data access

The stats adapter resolves `statistics.sqlite3` through `datastorage`, opens it with SQLite read-only mode, sets a short busy timeout, uses a parameterized time range, and closes the connection after each explicit analysis. It selects raw `page_stat_data` rows joined to `book`. Do not switch to `page_stat`: that view expands/rescales page rows and is not the event source for session grouping.

Rendering never queries SQLite. Tap schedules read-only query batches of up to 100 rows across UI ticks, then persists only the aggregate snapshot. Preview draws static sample text. Missing DB, failed query, empty history, and pending analysis have separate UI states.

## Known measurement limits

- A “session” is inferred from event timestamps and a 20-minute gap; KOReader does not store a session ID in this table.
- Event durations approximate reading time. Night allocation splits each event duration across device-local hours.
- Book authors are metadata strings; incomplete or inconsistent metadata weakens exploration counts.
- Completion and genre scores are intentionally omitted.
- Archetype labels are descriptive and provisional below the evidence gate.

## Device review checklist

- Check picker preview, hero card, and full-screen rendering.
- Check touch interaction, long-press settings, refresh, suspend/resume, and cold start.
- Check empty, missing, and locked statistics database states.
- Compare displayed totals against read-only SQL on the same device.
- Check 167-ppi grayscale legibility and render latency.
- Back up Bookshelf settings before copying the module; uninstall by removing the module file.

## Regression tests

Run `lua tests/test_reading_dna.lua` with Lua 5.1. Synthetic checks cover empty and short histories, interval overlaps, free-form author metadata, local calendar boundaries, and query/schema errors. The production module exposes these helpers only when the global `READING_DNA_TEST` flag is set by the test runner.

## Local references

Device-source snapshots and the inspection summary are kept in the workspace's ignored `references/` folder. They are excluded from this repository so version snapshots and local development material do not ship with the module.
