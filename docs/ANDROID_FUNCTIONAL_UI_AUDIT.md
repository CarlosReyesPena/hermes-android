# Hermes Android — functional and interface audit

Audit date: 2026-08-29 (updated 2026-09-06)  
Evidence: live SM-S948B UI hierarchy, Flutter source, widget tests, and `ANDROID_DAILY_DRIVER_ROADMAP.md`.

## Status update — 2026-09-06

Findings below were written against the 2026-08-29 build. The following items
from the original audit are **resolved** and must not be re-reported without
re-verifying against current code:

- **Two homes (P0)** — Workspace is now the launch surface: HomeScreen
  auto-navigates into `WorkspaceScreen` on the last connection, and the legacy
  All-chats flow lives on as the **Chats** destination of the shell, not in a
  competing drawer root.
- **Incomplete Project management (P0)** — rename/archive/restore/delete are
  all surfaced from one consistent Project overflow menu (roadmap points 25,
  28, 29).
- **Unassigned/Inbox recovery surface (P0)** — Home exposes a counted Inbox
  action (actionable-only Activity), now extended with a capability-gated
  failing-cron banner (roadmap point 30 + follow-up).
- **Home/Activity duplicated status strings (P1)** — idle chips are omitted in
  the Continue-working section; status chips remain only where they carry
  information.
- **Quick Chat lifecycle (P1/P2)** — 72 h retention is enforced by
  `QuickChatStore`; Archived + Promote surfaced through the Chats views.
- **Project detail tabs (P1)** — chats/overview/search/move all present;
  remaining tabs stay absent until their server contracts land.
- **Cron health (new since audit)** — failing jobs are ranked first on the
  Cron screen with an attention banner, error prose, and relative time; the
  action Inbox shows a "N cron jobs need attention" banner when a dashboard is
  configured.
- **Biometric app lock (new since audit)** — optional fingerprint/face lock
  wraps the whole Navigator (Settings → Security), device-local by design.
- **Pinned Smart View + batch actions (backlog item 7, resolved)** — the Chats
  browser offers a **Pinned** chip backed by the durable server `pinned` flag,
  including archived pins. Its long-press menu now enters multi-selection for
  grouped Pin, Move, and Archive actions; every successful batch exposes Undo
  and restores each conversation’s original flag or Project destination.
- **Project card counts and current focus (backlog item 6, resolved)** — cards
  carry the server's own chat count, last activity, and the chat the server
  ranks first, all from the `projects.tree` overview the pane already loads. An
  uncounted project (older gateway) stays name-only rather than claiming
  `No chats yet` (roadmap point 36).
- **Global Workspace search (backlog item 8, resolved)** — the complete Search
  route (on-device / full-text / AI+full-text) is no longer reachable only from
  the Home app-bar magnifier: the More pane lists it as a native Workspace
  Smart View routing to the same view, and it stays available without a
  dashboard because on-device search still works (roadmap point 37).

Remaining open items from the list below: Settings offline resilience was
fixed 2026-09-06 (local sections survive a dashboard outage); the audit body
below is otherwise kept as the historical record and the ordered backlog
(still valid: AI-assisted filing, tablet/foldable, full a11y pass).


## Product-level verdict

The application has a strong technical foundation: durable turn recovery, server-owned Projects, Home attention ranking, Activity, Quick Chat retention, project chat creation/movement/search, files access, voice, attachments, and explicit offline/error states. The main weakness is no longer transport reliability; it is **product coherence and feature discoverability**.

The current APK exposes two competing information architectures:

1. launch opens the legacy **All chats** screen;
2. the drawer opens **Workspace — Projects, Activity — new navigation**;
3. Workspace then appears as a child route with a Back button, despite containing the intended primary navigation Home / Projects / Activity / More.

This makes the new daily-driver experience look optional and unfinished. Workspace should become the launch surface; All chats should remain available as a secondary Smart View.

## Screen and capability matrix

| Surface | Working now | Important gaps |
|---|---|---|
| Legacy All chats | Local/full-text/AI search modes, profiles, chat actions, new chat | Competes with Workspace as the app home; visually belongs to an older navigation system |
| Home | Needs you, Running, Continue, Recently completed; badges; New flow | No Inbox/Unassigned, Pinned, or explicit Archived views; many idle/done chips add noise |
| Projects list | Server source of truth, cache/offline states, create, migration entry | No counts/current-focus summary on cards; no archived section; no reorder/pin/color/icon controls |
| Project detail | Chats/Overview, create chat, move chat, per-project search, repositories/location | Rename and archive absent; deletion added in this audit slice; Files/Assets/Activity tabs absent |
| Activity | Durable per-turn timeline with grouped states and elapsed time | Local journal only; no unified approvals/clarifications/cron/platform events or action controls |
| More | Files, Cron, Skills, Memory, Search, Settings/Dashboard fallback | Assets remains a placeholder pending a server Assets index; long flat list lacks stronger grouping/navigation hierarchy |
| Chat | Durable recovery, model/effort controls, attachments, voice, approvals/clarifications, reasoning/tool cards, code copy/wrap, long-press actions | Phase 1.5 remains partial: sticky context header, richer diff rendering, scroll/process restoration audit, haptic polish |
| Project administration | Create and server-backed assignment | Rename/archive/restore not surfaced; archived Projects are invisible; destructive management was missing until this slice |
| Quick Chat | 72-hour local archive lifecycle, never deletes sessions | No visible Archived destination and no Promote action, so the lifecycle is technically present but hard to manage |
| Global organization | Manual Project creation/move and Project search | No global Workspace search, batch selection, undo, Inbox/Unassigned triage, pinned chats, or AI organizer |

## Interface coherence findings

### P0 — information architecture

- **Two homes:** launch goes to legacy All chats; Workspace is hidden in the drawer and has a Back button. Make Workspace the launch route and place All chats under Home/More as a Smart View.
- **Incomplete Project management:** create and move exist, while rename/archive/restore were implemented below the UI but unavailable. Complete one consistent Project actions menu.
- **No organization recovery surface:** Unassigned exists as a move destination but there is no browsable Inbox/Unassigned screen. Users cannot easily find chats that were never filed or became unassigned after Project deletion.

### P1 — visible consistency and density

- Project cards show name/description/path and Active, but not the server counts/current-focus data expected by the roadmap; the list is visually sparse while Home cards are operationally dense.
- Home and Activity expose duplicated accessibility/status strings such as `Idle · Idle` and `Done · Done`. The chip and parent semantics should be merged; idle chips should usually be omitted.
- More rows expose repeated labels (`Files · Files`, `Cron · Cron`) in the accessibility tree because title and semantic label overlap.
- Project detail uses Chats/Overview only, whereas the validated model promises Overview/Chats/Files/Assets/Activity. Missing tabs should be capability-gated rather than silently absent once implemented.
- Destructive and management actions should use the same pattern everywhere: overflow menu, explicit confirmation, honest consequence text, progress state, rollback/retry.

### P2 — completeness

- Global server-backed search and an Archived surface.
- Pin, batch select, undo, and Quick Chat Promote.
- Project Files/Assets/Activity tabs and richer cards.
- Unified actionable Activity Center.
- AI-assisted filing only after manual organization is complete and reversible.
- Tablet/foldable layout, full accessibility audit, and localization.

## Ordered implementation backlog

1. **Project delete** — confirmed destructive action; chats survive and return to Unassigned; optimistic repository rollback. Implemented in this audit slice.
2. **Project rename + archive/restore + Archived section** — reuse existing RPC/repository methods and one consistent actions menu.
3. **Inbox / Unassigned Smart View** — essential recovery path after deletion or failed classification.
4. **Make Workspace the default launch surface** — retain All chats as a Smart View; eliminate the competing-root navigation.
5. **Quick Chat Archived + Promote** — expose the lifecycle already implemented.
6. **Project card counts/current focus** — consume the existing `projects.tree` overview.
7. **Pin/batch/undo** — complete manual organization before AI filing.
8. **Global Workspace search** — unify the existing search capabilities under the new information architecture.
9. **Semantics/density cleanup** — deduplicate labels and remove non-actionable idle chips.
10. Continue Phase 1.5 chat polish, then the AI organizer and expanded Activity Center.

## Project deletion interaction contract

- Entry: Project detail app-bar overflow → **Delete project**.
- Confirmation title names the Project.
- Copy explicitly states that Project deletion is permanent but chat sessions are not deleted and return to **Unassigned**.
- Cancel performs no write.
- Confirm calls the server-authoritative `projects.delete` RPC through `ProjectsRepository`.
- The repository removes the Project optimistically, clears the active selection when necessary, updates the connection-scoped cache, and restores the exact prior state on failure.
- Success returns to the refreshed Projects list.
- Failure keeps the detail open and offers Retry.
