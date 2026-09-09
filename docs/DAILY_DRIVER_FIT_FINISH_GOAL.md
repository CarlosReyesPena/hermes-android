# Hermes Android — Daily-Driver Fit & Finish Goal

Status: `[active — operating goal on top of the roadmap]`

Date: 2026-09-09

## Mission (one line)

Sweep **every screen of the whole app** — Files, Chat, Projects, Home, Activity,
More, Settings, Cron, Skills, Memory, and the cross-cutting shell — and bring
each from "technically works" to "finished daily-driver product", proactively,
without Carlos having to spell out what a real file manager / chat manager /
project app obviously needs.

**Scope is the entire application, not any one screen.** "Files first" names a
starting point in the sweep order, never the whole job. The goal is only met
when the whole app clears the bar, surface by surface.

This goal sits *above* `ANDROID_DAILY_DRIVER_ROADMAP.md`: the roadmap says what
to build; this goal says the bar every built surface must clear, and drives the
continuous pass back over the whole app.

## The lens — 4 questions asked of every surface before it is "done"

1. **Completeness** — what would a real user expect here that is still missing?
   (file size, modification time, sort, item count, breadcrumbs…)
2. **No dead UI** — is any chip, badge, or action rendering an empty string or
   a silent no-op? Hide it or make it work.
3. **Consistency** — one canonical formatter (`formatFileSize`,
   `formatRelativeAge`), one wording, one action pattern reused app-wide.
4. **States** — loading, empty, offline, and error are all designed as real
   states; no raw spinners, no blank lists, no dead-end error screens.

## Sweep order (priority)

This is the **order of the full-app sweep**, not a menu to pick one item from.
Files is first because it is the shallowest finish; every later surface gets the
same treatment in turn until the whole app is done.

1. **Files** — finish what the file-size slice started: modification time,
   sort toggle (name / size / date), folder item count, breadcrumbs.
2. **Chat** — the surface used most, deepest polish: sticky context header,
   richer diff rendering, scroll restoration, haptics, non-jumping streaming.
3. **Projects** — verify card counts/focus, archived section,
   reorder / pin / color / icon.
4. **Home + Activity** — accessibility dedup, idle-chip cleanup, full a11y pass.
5. **More + Settings** — grouping/hierarchy, whole-screen refresh recovery,
   per-section loading/empty/error states (in progress).
6. **Cron / Skills / Memory** — same lens.
7. **Cross-cutting** — tablet/foldable two-pane, light-theme tuning.

## Working rules

- Each slice: failing test first (RED) → implement (GREEN) → `dart format` +
  `flutter analyze` → full suite green → APK built + signed + published on the
  Tailnet share → real-device screenshot.
- A fix must encode the standard into the skill so it applies to the whole
  surface, not just the one spot Carlos named.
- Propose gaps proactively; never wait for "it's obvious".
- No destructive data loss across reinstalls; server changes synced to both
  git mirrors (`localfork/main`, `fork/main`).

## Acceptance for the goal

- Every screen answers the 4 lens questions affirmatively.
- No empty/dead UI anywhere.
- One canonical formatter and one action pattern reused app-wide.
- Full suite + `flutter analyze` green after every slice.
