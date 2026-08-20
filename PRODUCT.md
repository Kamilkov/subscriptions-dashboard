# Product

## Register

product

## Users

A single technical user (the owner) running the dashboard locally at
`127.0.0.1:8787`. They glance at it several times a day, usually alongside a
terminal and editor, to answer two questions fast: **which AI subscription am I
burning too fast, and when does each reset.** Context is a quick check, not a
sit-down session — legibility at a glance matters more than exploration.

## Product Purpose

A private, local-only monitor of AI-subscription usage (Claude, Codex, Cursor,
Antigravity, Copilot) against time. It reads each service's own usage API, normalizes every limit into
a window with a reset, and shows pace (used vs. elapsed) so overspend is visible
before the window runs out. Success = the user can tell in under two seconds
whether anything needs attention, without reading numbers one by one.

## Brand Personality

Instrument, not app. Precise, quiet, trustworthy — a gauge you trust because it
never dresses up the data. Three words: **precise, calm, honest.** No
persuasion, no celebration; just an accurate readout. Truthfulness is a feature:
stale and errored states are shown plainly, never hidden behind a polished
surface.

## Anti-references

- Generic SaaS dashboards: rows of identical rounded cards, icon + heading +
  big-number stat, gradient accents.
- Neon / gamer dark themes: glowing accents, heavy gradients, high saturation.
- Cluttered enterprise admin: heavy borders, gray-on-gray chrome, dense toolbars.

## Design Principles

- **The data is the interface.** Chrome recedes; the bars, the now-line, and the
  numbers carry all the meaning. Decoration that doesn't encode state is removed.
- **Legible at a glance.** Pace readable in one look (fill vs. now-line), status
  never conveyed by color alone. Optimized for a repeated 2-second check.
- **Honest under failure.** Stale, errored, and no-data states stay truthful and
  readable — category-accurate, never blaming credentials wrongly, never faded
  into illegibility.
- **Quiet precision.** Tabular/monospace numerals, hairline rules, restrained
  neutral surfaces; color spent only where it means something.
- **Local-first, dependency-free.** Single stdlib Python file, one self-contained
  HTML page. No external fonts, scripts, or network calls in the UI.

## Accessibility & Inclusion

- Pace conveyed by an explicit text token (word + emoji), not fill color alone —
  colorblind-safe.
- Bars are `role="progressbar"` with numeric + pace `aria-label`s; decorative
  marks are `aria-hidden`.
- Body text ≥ 4.5:1 contrast in both light and dark themes; respects
  `prefers-color-scheme`.
- Motion (if any) must honor `prefers-reduced-motion: reduce`.
