# Changelog

## 0.1.3 — Regression coverage

- Add synthetic interval, metadata, calendar-window, and database-error regression tests.
- Keep test helpers out of the production module unless test mode is explicitly enabled.

## 0.1.2 — Metric accuracy

- Clip overlapping event time to prevent double-counting durations and session lengths.
- Exclude pre-history days from the consistency denominator.
- Count complete author metadata credits instead of splitting ambiguous names on commas.
- Document measurement choices and limitations.

## 0.1.1 — Kindle UI polish

- Shorten full-screen supporting text to reduce clipping on narrow screens.
- Expose module version in the spec and establish per-update version tracking.

## 0.1.0 — Prototype

- Add offline Reading DNA Bookshelf micro-module.
- Read KOReader statistics in read-only mode and cache aggregate profile.
- Add consistency, session depth, loyalty, exploration, night-reading, and switching summaries.
- Add analysis-window, night-hours, score-visibility, and archetype-visibility settings.
- Document installation, data handling, scoring assumptions, and known limitations.
