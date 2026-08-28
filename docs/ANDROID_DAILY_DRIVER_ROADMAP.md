# Hermes Android Daily Driver — product architecture and roadmap

Status: `[product direction validated; Phase 0 in progress]`

Date: 2026-08-25

## Product goal

Turn Hermes Android into the comfortable, complete mobile control center for a remote Hermes instance:

- conversations organized without constant manual filing;
- durable project context shared with Hermes Desktop and other clients;
- native attention management for running work, approvals, clarifications, failures, and completions;
- direct access to miniserver files and generated artifacts;
- practical access to Hermes configuration, profiles, skills, cron, memory, MCP, plugins, and diagnostics;
- resilient mobile behavior across backgrounding, process death, reconnects, and intermittent networks.

The target is **not** a phone-sized clone of Desktop and not merely a chat list with folders. It is a mobile mission control surface that preserves access to every capability while presenting each workflow in a phone-appropriate form.

---

## Executive decision: keep Flutter, replace the product architecture

Our current Flutter fork is the best available Android base, but its current information architecture is not the final one.

### Why Flutter remains the base

The current fork already has verified Android-native foundations that the alternatives do not combine:

- authenticated Dashboard REST plus Desktop Gateway JSON-RPC;
- durable turn recovery and reconnect handling;
- secure Android credential storage;
- native file/image picking and multi-attachment uploads;
- approvals, sudo, secrets, clarification, tools, reviews, subagents, and background events;
- speech input, TTS, native lifecycle handling, and local notifications;
- a large automated Flutter test suite and a verified Android APK pipeline.

These are the difficult mobile foundations. Rewriting them in Kotlin or React Native would delay the product without improving the organization model.

### Why not pivot to the Expo/WebView mobile PR

NousResearch/hermes-agent PR #52673 reuses the Desktop renderer inside a React Native WebView. It provides rapid visual parity for Settings, Cron, Profiles, Messaging, Skills, and Artifacts, and contains useful phone interaction work. It is not the right production base for this Android goal because:

- physical-device validation is iPhone-focused; Android is configured but not verified;
- credentials are currently stored in WebView `localStorage` rather than native secure storage;
- the terminal is explicitly stubbed out;
- native filesystem bridge methods are incomplete and unknown methods silently resolve to `undefined`;
- the copied Desktop renderer creates a large synchronization burden;
- the PR history shows repeated WebKit gesture, keyboard, safe-area, and layout regressions;
- native background execution, actionable Android notifications, deep links, and killed-app delivery still need a real native architecture.

Use it as a **design and parity reference**, not as our base.

### Why not use `goldenduo/hermes-agent-for-android`

The public repository contains marketing copy and screenshots but no application source and no declared license. It cannot be audited, extended, or trusted as a development base.

### Selective community reuse

Do not merge another fork wholesale. Port small, tested slices:

- **CristianGCiocoi:** native Projects UI concepts, Activity Center, capability-gated interaction modes;
- **grunjol:** consolidated tool cards, scroll restoration, voice locale selection;
- **danlil240:** foreground-service concepts, Active Runs, cached sessions/background sync, diagnostics UX, feature-based package layout;
- **official Desktop:** server-authoritative Projects, project trees, Files, Artifacts, schema-driven Settings, plugin/capability patterns;
- **official mobile PR:** touch target, drawer, master/detail, safe-area, keyboard, and long-press lessons only.

Every imported behavior must enter through a failing test and a small reviewed commit.

---

## Replace “Spaces” with a layered organization model

A single folder hierarchy cannot represent everything a Hermes user needs. The recommended model has five distinct layers.

### 1. Profile / connection

The hard isolation boundary: which Hermes instance and profile owns the data.

Examples: `default`, `research`, `work`, or another saved Gateway.

### 2. Project

A durable workspace with a real goal and optional folders/repos. It is server-owned and shared across Android, Desktop, and future clients.

A Project may contain:

- description and project brief;
- one or more miniserver folders/repos;
- conversations;
- files and generated artifacts;
- activity, approvals, and scheduled jobs;
- project-specific memory or pinned context in a later phase.

Projects should be few and stable: `Hermes Android`, `ScriptHive`, `C-MAY`, not one project per question.

### 3. Conversation

A durable Hermes session inside a Project or in the Inbox. It can have multiple AI/manual topics and a lifecycle state.

### 4. Topics / labels

Multi-value classifications such as `notifications`, `search`, `deployment`, `bug`, or `research`. These are mainly AI-assigned and allow one conversation to appear in several relevant views without duplicating it.

### 5. Smart Views

Derived views, not manually maintained folders:

- **Needs you** — approval, clarification, secret, sudo, failed action;
- **Running** — active turn, cron run, subagent, background process;
- **Inbox** — unclassified or low-confidence organization suggestions;
- **Continue** — recently active durable conversations;
- **Completed recently**;
- **Quick chats** — ephemeral sessions;
- **Pinned**;
- **Archived**;
- optional user-saved filters later.

This combination gives stable Projects, flexible Topics, and automatic operational views.

---

## Ephemeral conversations: “Quick chat”

Quick Chat is a separate creation mode, not another Project.

Default behavior:

- starts without a Project;
- is clearly marked `Quick`;
- does not clutter Project lists;
- uses normal Hermes/Hindsight memory behavior, so durable facts can still be retained;
- auto-archives after 72 hours, never silently deletes;
- remains searchable in Archived;
- can be promoted into a normal Project conversation at any time;
- after completion, one cheap classifier may suggest promotion when the work appears durable.

The retention interval remains configurable. Quick Chat is ephemeral only as an
organization/lifecycle state: it must not suppress normal memory extraction.

---

## AI organization policy

The organizer belongs on the Hermes server, not inside Android. That keeps organization consistent across clients and allows it to run while the phone app is closed.

### Decision ladder

Use the cheapest reliable signal first:

1. **Deterministic, no LLM:** existing `project_id`, session cwd, repo/worktree path, active Project, explicit user choice.
2. **Rules, no LLM:** source, branch, recurring exact labels, pinned routing rules.
3. **Cheap structured classification:** only for sessions still ambiguous.
4. **Periodic clustering:** detect recurring themes that may deserve a new Project.

The AI never receives an entire transcript just to file a chat. Input should normally be:

- current title;
- first user request;
- latest compact session summary;
- cwd/repo/branch/source;
- existing Project names and descriptions;
- current Topics;
- content hash and previous classification.

### Suggested schedule

- after the first completed turn: classify once;
- after later turns: rerun only when the compact input hash materially changes;
- every 15 minutes: batch pending classifications server-side, up to roughly 20 sessions per request;
- nightly: reconcile stale Inbox items and identify repeated clusters;
- on explicit **Organize now**: run immediately.

No phone polling is required.

### Cost controls

- use Hermes’ configurable light/cheap model tier, never the active chat model by default;
- require strict structured JSON output;
- cache by normalized input hash;
- batch several sessions in one model call;
- cap input and output tokens;
- do not reclassify unchanged sessions;
- expose monthly call/token estimates and a hard budget;
- degrade to deterministic organization when the model is unavailable.

### Confidence and automatic actions

Recommended defaults:

- confidence `>= 0.90`: automatically assign to an existing Project and apply Topics;
- confidence `0.65–0.89`: show a one-tap suggestion in Inbox;
- confidence `< 0.65`: leave unclassified without inventing a destination.

Automatic creation of Projects is intentionally stricter:

- the theme appears in at least three related conversations;
- activity spans at least two different days;
- no existing Project is a close match;
- the cluster has high confidence and a concise stable goal.

Default mode should create a visible proposal. An opt-in **Autonomous organization** mode may auto-create qualifying Projects, with an undo log. AI must never silently move pinned conversations or override a recent manual correction.

### Corrections teach the organizer

Every Move, Merge, Rename, Reject, and “Always route like this” action becomes an explicit routing rule. Recent manual decisions outrank model output.

---

## Recommended Android navigation

Use a stable bottom navigation shell rather than a growing drawer.

### Home

The attention-first dashboard:

1. Needs you;
2. Running now;
3. AI organization suggestions;
4. Continue working;
5. Recently completed.

A global New button offers **Project chat** and **Quick chat**.

### Projects

Project cards with status counts, not only chat counts. Opening a Project shows:

- **Overview** — brief, current work, pinned items;
- **Chats** — grouped by active/recent/archived;
- **Files** — the Project’s miniserver folders;
- **Assets** — generated artifacts, attachments, media, and outputs;
- **Activity** — running/completed/failed work for that Project.

### Activity

Global operational timeline and action center:

- running turns and subagents;
- pending approvals/clarifications/secrets;
- completed tasks;
- failures and reconnect problems;
- filters by Project/profile.

### More

- Global Files;
- Global Assets;
- Search;
- Cron;
- Skills and Tools;
- Memory;
- Profiles;
- MCP and Plugins;
- Diagnostics and logs;
- Settings.

Chat itself remains full-screen and reachable from every relevant card or notification.

---

## Interface overhaul

The current app is functional but reads as a utility list: flat sessions, drawer-driven navigation, dense uniform rows, and screens that each invent their own layout. Reaching daily-driver quality requires a deliberate interface rebuild, not incremental cosmetic tweaks. This work is a first-class deliverable, not polish deferred to the end.

### Problems to fix

- No shared design system: spacing, radius, elevation, and typography are decided per screen.
- Navigation hidden in a drawer, so most capabilities are invisible until searched for.
- Session rows carry no status, no project, and no urgency signal.
- Chat lacks visual hierarchy between prose, reasoning, tool activity, and results.
- Long-running and blocked work looks identical to finished work.
- No empty, loading, offline, or error states designed as real states.
- Touch targets, one-handed reach, and keyboard/IME behavior are inconsistent.
- Dark theme is the only well-tuned theme; light theme is an afterthought.

### Design system foundation

Introduce one typed theme layer that every screen consumes:

- **Tokens** — spacing scale, corner radii, elevation, motion durations/curves, and semantic colors (surface, raised, accent, success, warning, danger, running, blocked).
- **Typography ramp** — display, title, section, body, label, mono; the mono style owns code, paths, and terminal output.
- **Brand** — keep the Hermes gold accent, but as a semantic accent token rather than a hardcoded hex per widget.
- **Full Material 3 adoption** — dynamic color optional, contrast verified in both themes.
- **Component kit** — `HermesCard`, `HermesListTile`, `StatusChip`, `SectionHeader`, `EmptyState`, `ErrorState`, `LoadingSkeleton`, `MetricRow`, `ActionSheet`.

No feature screen may hardcode a color, radius, or spacing value once the token layer exists.

### Home

- Attention-first cards with clear rank: **Needs you** > **Running** > **Suggestions** > **Continue** > **Completed**.
- Each card shows what happened, where, and one primary action.
- Live progress for running turns; elapsed time for blocked work.
- Skeleton loaders instead of spinners.
- A calm, explicitly designed “nothing needs you” state — not an empty list.

### Projects

- Rich project cards: name, icon/color, current focus, counts for running/blocked/recent, last activity.
- Optional grid or list density.
- Project detail as tabs (Overview, Chats, Files, Assets, Activity) with a collapsing header.
- Pin, reorder, archive, and color/icon assignment.
- Inline creation flow with a preview of what the project will contain.

### Chat

Chat is where Carlos spends most of his time, so it gets the deepest rework:

- Clear separation between user prose, assistant prose, reasoning, tool activity, and results.
- Collapsible tool cards with icon, title, duration, and status — expandable to full output.
- Streaming presentation that does not jump the scroll position.
- Sticky context header: project, model, reasoning effort, connection state.
- Composer redesign: multiline growth, attachment strip, voice, model/effort switcher, send/stop as one adaptive control.
- Distinct visual treatment for approvals, clarifications, secrets, and errors — they must never read as ordinary messages.
- Code and diff blocks with syntax highlighting, horizontal scroll, copy, and wrap toggle.
- Message actions via long-press sheet rather than crowded inline icons.
- Jump-to-latest, jump-to-unread, and preserved scroll on reopen.

### Activity

- Timeline grouped by state, with color-coded status chips.
- Blocked items always sort first and stay visually urgent.
- Inline resolve actions where safe.

### Motion and feedback

- Shared-element transitions between cards and detail screens.
- Meaningful, short animations only (150–250 ms); no decorative motion.
- Haptics for approval, completion, failure, and destructive confirmation.
- Pull-to-refresh and optimistic updates with visible rollback on failure.

### States, accessibility, and form factors

- Every screen defines loading, empty, offline, permission-denied, unsupported-gateway, and error states explicitly.
- Minimum 48 dp touch targets; primary actions within thumb reach.
- Full text scaling without clipping; screen-reader labels on every actionable element.
- Verified contrast in dark and light themes.
- Tablet and foldable two-pane layouts (list + detail).
- Landscape support for chat and file preview.

### Verification

Interface work is only accepted with evidence:

- widget tests for each new component and each state;
- golden tests for the component kit in both themes;
- text-scale and small-width regression tests;
- a real device screenshot for every reworked screen.

---

## Native Android notifications

Local “turn complete” notifications are only the first step. The final notification model needs event types, priority channels, deep links, and killed-app delivery.

### Notification channels

1. **Action required — high priority**
   - approval, clarification, sudo, secret, blocked workflow;
   - heads-up notification and configurable strong vibration pattern;
   - persistent until handled;
   - optional reminder at +2 and +10 minutes;
   - tap opens the exact action card;
   - safe actions such as Approve/Deny may be offered directly, with device authentication when appropriate.

2. **Failures — high priority**
   - failed task, disconnected critical run, cron failure;
   - distinct vibration and direct retry/open action.

3. **Completed — default priority**
   - grouped by Project;
   - tap opens the exact conversation/activity item.

4. **Running — low priority ongoing**
   - foreground-service indicator only while Android must keep a live operation/socket alive.

Do not abuse Android full-screen/call-style notifications. They are policy-restricted and too intrusive for normal completions. Strong repeated vibration should be an explicit opt-in for **Action required**, not the default for every answer.

### Delivery architecture

- Phase 1: improve local notifications while the process is alive/backgrounded.
- Phase 2: foreground service for user-started long turns where appropriate.
- Phase 3: Gateway-to-device push registration for reliable delivery after Android kills the app. FCM is the pragmatic first transport; a self-hosted UnifiedPush/ntfy-compatible transport can follow.
- Every event must be idempotent and deep-link by profile, Project, session, turn, and request ID.

---

## Files and Assets

### Files

The Hermes Dashboard already exposes authenticated remote operations used by Desktop:

- `/api/fs/list`;
- `/api/fs/read-text`;
- `/api/fs/write-text`;
- `/api/fs/read-data-url`;
- `/api/fs/download`;
- `/api/fs/default-cwd` and `/api/fs/git-root`;
- authenticated managed-file upload/create/delete routes;
- remote Git status, diff, stage, commit, push, worktree, branch, and PR routes.

Build a native Android Files surface on these contracts:

- default to Project roots;
- optional explicit **Browse server** mode;
- breadcrumbs, search, sort, favorites, recent files;
- text/code preview and safe spot editing;
- image/PDF/media preview;
- upload from Android, download to Android, share to another app;
- add a file reference to the active chat;
- Git status/diff as progressive enhancement;
- sensitive-file rules and destructive confirmations inherited from the server.

### Assets

“Assets” should be a user-facing umbrella with four filters:

- **Artifacts** — generated HTML, SVG, code, documents, and versions;
- **Files changed/generated** by Hermes;
- **Attachments** uploaded by the user;
- **Media and downloads**.

Desktop Artifacts are currently reconstructed from transcripts and held in renderer memory. True cross-device parity therefore requires a small server-authoritative artifact index/RPC rather than a second Android-only registry. Android can initially render artifact cards from a session transcript, then move to the shared index.

---

## Hermes Settings parity

Do not hand-code every Hermes option in Flutter. The Desktop already consumes a configuration schema and a profile-scoped config record.

Recommended structure:

- **Native Settings renderer** generated from the Dashboard config schema;
- mobile-specific section for notification channels, vibration, background behavior, cache, biometrics, downloads, and text/voice preferences;
- safe confirmations for destructive changes;
- provider keys shown as configured/missing, never echoed;
- profile scope clearly visible;
- advanced JSON editor only as a fallback;
- embedded authenticated Dashboard view for not-yet-native features, so capability access is never blocked while native UX catches up.

The native menu should use capability discovery. Missing server support should disable an item with a precise explanation rather than hide it or crash.

---

## Architecture changes required in the Flutter app

### Server authority

- Replace `ChatSpaceStore` as the source of truth with a `ProjectsRepository` over `projects.*` RPC.
- Use SharedPreferences/SQLite only as an offline cache and migration source.
- Cache keys must remain scoped by connection/profile.
- Use optimistic updates with rollback and authoritative refresh.

### Generic Gateway capability layer

- Expose a typed generic JSON-RPC request method from the existing `WsClient`/`DesktopGatewayClient`.
- Build a `CapabilityRegistry` from `gateway.ready`, Dashboard probes, and missing-method responses.
- Keep compatibility fallbacks narrow and explicit.

### Feature modules

Incrementally move from `core/screens/*` into feature-owned modules:

- `features/home/`;
- `features/projects/`;
- `features/activity/`;
- `features/files/`;
- `features/assets/`;
- `features/settings/`;
- `features/chat/`;
- `features/search/`.

Do not perform a single massive directory rewrite. Move one tested feature at a time.

### Offline and lifecycle

- local SQLite cache for Projects, sessions, activity, and file metadata;
- explicit stale/offline indicators;
- queued safe mutations with idempotency keys;
- never automatically replay a prompt after ambiguous transport failure;
- deep-link restoration after notification taps or process recreation.

---

## Delivery roadmap

### Phase 0 — Contracts and shell foundation

**Goal:** make future features server-authoritative and capability-aware.

Deliverables:

- generic typed Gateway RPC adapter;
- capability registry;
- `ProjectsRepository` wrapping native `projects.list/create/update/archive/delete/set_active/tree/project_sessions` contracts;
- migration adapter from local Spaces to native Projects;
- bottom navigation shell with placeholder destinations;
- embedded Dashboard fallback entry;
- characterization tests for current chat/recovery/notification behavior.

Phase 0 also lands the **design system foundation** described in the Interface
overhaul section: the token layer, typography ramp, and the first component kit
widgets with tests. The navigation shell must be built on those tokens rather
than on per-screen styling, so no later phase inherits ad-hoc visuals.

Acceptance:

- no Project assignment depends exclusively on SharedPreferences;
- existing local Spaces can be previewed and migrated without losing assignments;
- older Gateways remain usable with a clearly labeled compatibility mode.
- every new widget consumes theme tokens; no hardcoded color, radius, or spacing.

### Phase 1 — Organization-first daily home

**Goal:** replace the flat session list with Projects, Smart Views, and Quick Chat.

Deliverables:

- Home attention dashboard;
- Projects list and Project detail with Chats/Overview;
- Inbox, Running, Needs you, Continue, Pinned, Archived;
- Quick Chat lifecycle and Promote action;
- native global and per-Project search;
- move, pin, archive, batch-select, and undo actions.

Acceptance:

- a normal day can be navigated without opening “All chats”;
- new Project chats inherit Project context/cwd;
- Quick Chats never pollute durable Project lists;
- all manual organization changes synchronize across clients.
- Home, Projects, and Activity ship with designed loading, empty, offline, and
  error states, not raw spinners or blank lists.

### Phase 1.5 — Chat interface rework

**Goal:** make the surface Carlos uses most both readable and fast.

Deliverables:

- message hierarchy separating prose, reasoning, tool activity, and results;
- collapsible tool cards with duration and status;
- distinct treatment for approvals, clarifications, secrets, and errors;
- code and diff rendering with highlighting, copy, and wrap toggle;
- composer redesign with adaptive send/stop, attachments, and voice;
- sticky context header (project, model, effort, connection);
- long-press action sheet, jump-to-latest, preserved scroll;
- haptics and non-jumping streaming.

Acceptance:

- a long tool-heavy turn stays readable without manual scrolling gymnastics;
- a blocked approval is impossible to mistake for an ordinary message;
- scroll position survives reopen, rotation, and process recreation;
- widget and golden tests cover each message type in both themes.

### Phase 2 — Cheap AI organizer

**Goal:** make organization mostly automatic without Project proliferation or uncontrolled cost.

Server deliverables:

- organization metadata store and RPC/event contract;
- deterministic routing engine;
- batched low-cost structured classifier;
- content-hash cache, budget cap, confidence thresholds;
- recurring-theme Project proposals;
- correction/routing-rule store and audit/undo history.

Android deliverables:

- organization suggestions in Inbox;
- explain/accept/reject/move controls;
- bulk review;
- organizer settings: Off, Suggest, Auto-file, Autonomous Projects;
- cost/activity readout and **Organize now**.

Acceptance:

- existing-project assignments at high confidence are automatic;
- uncertain cases remain visible and reversible;
- unchanged sessions produce no repeated model calls;
- one switch disables every AI organization call without disabling manual Projects.

### Phase 3 — Attention Center and reliable notifications

**Goal:** ensure Carlos notices when Hermes needs him and can act immediately.

Deliverables:

- unified Activity repository and screen;
- four notification channels and configurable vibration/reminders;
- deep links to exact session/request;
- notification actions for safe approvals/denials;
- foreground-service integration for active user-started work;
- push-token registration and Gateway notification delivery;
- grouping/deduplication/idempotency tests.

Acceptance:

- approval, clarification, failure, and completion each produce the correct priority;
- tapping works after process death;
- duplicate Gateway events never produce duplicate alerts;
- battery use remains bounded when no work is active.

### Phase 4 — Project Files and Assets

**Goal:** work with miniserver outputs without leaving Android.

Deliverables:

- Project Files browser over existing Dashboard APIs;
- previews, safe text editing, upload, download, share, add-to-chat;
- file change refresh and basic Git status/diff;
- Project and global Assets galleries;
- artifact preview/version UI;
- server-side artifact index contract for cross-device parity.

Acceptance:

- a generated report can be found, previewed, downloaded, shared, and reattached from the phone;
- a Project source file can be inspected and safely edited;
- secrets and sensitive paths remain blocked by server policy.

### Phase 5 — Settings and control-plane parity

**Goal:** remove the need to reach for a PC for normal Hermes administration.

Deliverables:

- schema-driven profile-scoped Settings;
- Profiles management;
- complete Skills/Tools configuration;
- MCP and Plugins management;
- Cron parity;
- Memory/Hindsight viewer and controls;
- Gateway platforms, diagnostics, logs, processes, updates;
- embedded Dashboard fallback for any remaining surface.

Acceptance:

- every Dashboard capability is either native or reachable through the in-app fallback;
- dangerous changes are explicit and reversible where possible;
- secrets are never displayed or stored outside secure storage.

### Phase 6 — Mobile polish and parity closure

**Goal:** make the app genuinely pleasant as Carlos’s primary Hermes surface.

Deliverables:

- offline cache and conflict handling;
- share-target integration (“Send to Hermes”);
- home-screen shortcuts and widgets;
- biometric app lock and approval confirmation;
- tablet/foldable layouts;
- accessibility, selectable content, polished tool cards, scroll restoration;
- battery/network telemetry and automatic recovery;
- feature-parity checklist against current Desktop releases.

Acceptance:

- normal mobile workflows survive network loss, backgrounding, process death, and updates;
- the parity checklist has no unexplained missing capability;
- phone UX remains task-focused rather than becoming a cramped Desktop clone.

---

## Migration of the current Spaces prototype

The current local Spaces implementation was useful to validate filtering and navigation, but its storage decision is now obsolete because native Projects are available.

Migration strategy:

1. read local Spaces and assignments once;
2. match by normalized name against native Projects;
3. create missing Projects only after showing the migration preview;
4. associate sessions using native Project/session contracts or cwd/project metadata;
5. retain the local snapshot until server read-back verifies every migrated assignment;
6. rename the UI from Spaces to Projects;
7. remove local authority only after rollback tests pass.

The existing `docs/ANDROID_SPACES_SPEC.md` remains a record of the prototype, not the target architecture.

---

## First implementation slice after validation

Implement **Phase 0 only**, in this order:

1. add tests for generic Gateway RPC request/response/error handling;
2. add the minimal generic request API;
3. add contract tests for native `projects.list` and capability fallback;
4. implement `ProjectsRepository` read-only list/tree support;
5. replace the Spaces home data source with native Projects in read-only mode;
6. add a migration preview for local Spaces without executing it yet;
7. run focused tests, full Flutter tests, analysis, APK build, and real Gateway smoke test;
8. update Graphify and commit one clean feature slice.

Do not implement AI organization, Files, or notification escalation until the new Project information architecture is visually validated on Android.

### Verified progress

Steps 1–6 of the slice above are implemented and covered by passing tests:

1. generic Gateway RPC request/response/error handling — `test/projects_gateway_client_test.dart`;
2. `ProjectsRepository` with offline cache, optimistic mutations, and an
   `unsupported` compatibility mode — `test/projects_repository_test.dart`;
3. the Home/Projects/Activity/More shell — `test/hermes_shell_test.dart`;
4. the token layer and component kit — `test/hermes_theme_test.dart`,
   `test/hermes_components_test.dart`;
5. the Projects pane on server-owned Projects — `test/projects_pane_test.dart`;
6. the **read-only** Spaces migration preview, reachable from the Projects pane
   and executing nothing — `test/space_migration_preview_test.dart`;
7. the gateway capability registry — `test/capability_registry_test.dart`.
   It reads `gateway.ready`, refines its verdicts from the outcome of real
   calls, and treats an absent advertisement as `unknown` rather than
   `unsupported`, so older gateways are still tried instead of being locked
   out. `ProjectsGatewayClient` reports every outcome into it and skips a
   method already proven missing.
8. the **compatibility mode** for gateways without `projects.*` —
   `test/projects_pane_test.dart`. Instead of a dead-end error screen, the
   Projects pane stays usable: it is labelled `Compatibility mode`, explains
   why organization is device-local, lists the local Spaces with their chat
   counts read-only, and never offers to create a server project the gateway
   cannot host. Pull-to-refresh still re-probes, so a gateway upgrade is
   picked up without reinstalling.
9. the **More destination and the embedded Dashboard fallback entry** —
   `test/more_pane_test.dart`, `test/workspace_screen_test.dart`. The fourth
   shell destination now lists every capability instead of a placeholder:
   Files/Assets/Search are labelled `Coming next` rather than hidden, Cron,
   Skills, Memory and the Dashboard fallback open the existing screens, and a
   connection with no reachable dashboard host disables exactly those entries
   *with a stated reason* rather than removing them. Settings stays reachable
   in every case so a broken connection can be repaired from inside the app.

10. the **notification characterization tests** —
    `test/turn_notification_service_test.dart`. `TurnNotificationService` now
    posts through a `TurnNotificationSink` seam instead of calling the
    `flutter_local_notifications` plugin directly, so the shipped behaviour is
    pinned before Phase 3 replaces it: one idempotent initialization that
    degrades to a silent no-op (and can be retried) when the platform channel
    is missing, notifications dropped while uninitialized, the `Hermes Turns`
    channel identity, the turn id carried as the deep-link payload, and one
    stable non-negative id per turn so a turn replaces its own notification
    instead of stacking duplicates. The id is now masked to the 31-bit range
    rather than negated, which removes the `hashCode.abs()` overflow edge case.

11. the **chat display characterization tests** —
    `test/chat_display_items_test.dart`. The chat list projection that lived
    inline in `chat_screen.dart` is now the pure `buildChatDisplayItems`
    helper in `lib/core/utils/chat_display_items.dart`, so the shipped
    rendering order is pinned before Phase 1.5 reworks message hierarchy:
    user/assistant prose in order, `_retry_prompt` carrying the last user
    prompt onto each assistant reply (and never onto the first message when no
    prompt preceded it), non-chat roles dropped, empty messages dropped,
    consecutive tool results collapsed into one positionally matched activity
    card, unmatched streamed tool activities appended as a trailing card, the
    caller's activity list left unmutated, reasoning emitted as its own
    `ChatReasoningItem` before the bubble (expanded in verbose mode or when the
    gateway marks it verbose), and subagents then notices appended last. One
    test deliberately records a known wart rather than fixing it: an assistant
    reply that *embeds* a raw tool-result block is classified as a tool result
    and its prose is dropped, so Phase 1.5 changing that becomes a visible,
    intentional decision instead of a silent regression.

12. the **turn-recovery fallback characterization tests** —
    `test/turn_recovery_fallback_test.dart`. The decision that used to live
    inline in `_recoverPendingTurn` is now the pure
    `classifyTurnRecoveryFailure` helper in
    `lib/core/utils/turn_recovery_fallback.dart`, so the last guard against a
    double submit is pinned before Phase 3 touches recovery: only an explicit
    `unsupportedCapability` on the *first* recovery pass may switch a chat to
    the labelled legacy transport. Every other coordinator failure — including
    `unsupportedCapabilityWithPendingTurns`, where durable turns already exist
    server-side — plus transport errors, `JsonRpcError` authorization
    failures, and arbitrary exceptions all resolve to `reportUnavailable`,
    which keeps the durable transport and the composer blocked. A later resume
    (`allowLegacyFallback: false`) can never degrade a gateway that already
    recovered successfully. The enum-driven test iterates
    `GatewayTurnCoordinatorFailure.values`, so a new failure mode added later
    defaults to the safe branch or fails the suite.

13. the **Home attention digest** — `test/home_digest_test.dart`. The ranking
    half of the Phase 1 Home screen is the pure `buildHomeDigest` helper in
    `lib/core/utils/home_digest.dart`, so the attention rules are pinned
    before any pixel is drawn: sections are emitted in the validated order
    (Needs you > Running > Continue > Recently completed), empty sections are
    dropped rather than rendered as empty lists, a blocked session appears in
    `Needs you` *only* and never also as running, blocked work is never aged
    out while idle and completed work respect their windows, a finished
    session is ranked by its end time rather than its start time, a clock
    skewed into the future is shown rather than dropped, unknown attention or
    running ids are ignored instead of conjuring phantom rows, a capped
    section reports its `overflow` and true `totalCount`, and `blockedCount`
    ignores the cap so the shell badge stays accurate. The digest is a pure
    function of `(sessions, now, attention, running, projectNames)` and does
    not mutate the caller's list, so the widget that consumes it in the next
    slice inherits no hidden state.

14. the **Home pane** — `test/home_pane_test.dart`,
    `test/workspace_screen_test.dart`. `HermesDestination.home` no longer shows
    a `Coming next` placeholder: it renders `buildHomeDigest` through the new
    `HomePane` in `lib/core/widgets/home_pane.dart`, with the four states
    Phase 1 acceptance requires expressed as designed states rather than
    spinners. The behaviours that are pinned by test: a skeleton holds the
    screen until the *first* read lands, sections draw in the validated
    attention order, a blocked row states its reason and is never also drawn as
    running, a stale attention id draws nothing, a capped section says how many
    rows it hid, and the calm `Nothing needs you` state replaces an empty list.
    Two failure paths are distinguished on purpose: a *first* read that fails
    becomes a retryable `ErrorState`, while a *later* failure keeps the last
    known digest on screen behind an offline notice — losing the network must
    never blank the screen the user relies on. Sessions are read through an
    injectable `HomeSessionsLoader` that defaults to the same authenticated
    `ApiClient.getSessions()` REST call the session list already uses, so no
    new gateway contract is required and legacy gateways keep working.

15. the **Home chat route** — `test/workspace_screen_test.dart`,
    `test/workspace_entry_point_test.dart`. Home ranked the work that needed
    Carlos and then refused to open it: `WorkspaceScreen` passed
    `onOpenSession` straight through, so a row was inert unless a host
    supplied a callback, and nothing did. The shell now opens the chat itself
    through `buildWorkspaceChatScreen`, and four rules are pinned by test: a
    host `onOpenSession` still wins outright and suppresses the built-in route
    (a host that owns navigation must not get a second screen pushed under its
    own), the shipped default really is a `ChatScreen` carrying the right
    session and connection, returning from a chat re-reads the digest through
    the new public `HomePaneState.refresh` (the reason a chat was blocked
    usually stops being true while the user is inside it, and coming back to a
    stale digest is worse than a spinner), and the chat inherits the
    application-scoped `GatewayTurnApplicationController` so a turn started
    from Home survives leaving the screen exactly like one started from the
    session list. That last rule is guarded at the *real* call site as well:
    `workspace_entry_point_test.dart` drives the session-list drawer entry
    that constructs the shell, because a dropped controller there would lose
    durable turn recovery for every chat opened from Home while every
    `WorkspaceScreen` test still passed in isolation. `test/support/
    inert_turn_application_session.dart` is the reusable no-op turn session
    those widget tests mount against.

16. the **Home turn signals** — `test/home_turn_signals_test.dart`,
    `test/workspace_screen_test.dart`. `HomePane` accepted `attention` and
    `running` but `WorkspaceScreen` passed neither, so every row ranked as
    `Continue working` and the shell's attention badge stayed empty. Both
    inputs are now derived from the durable turn recovery journal by the pure
    `buildHomeTurnSignals` helper in `lib/core/utils/home_turn_signals.dart`:
    the journal is the only store that already survives process death and
    knows what a chat was doing, so **no new gateway contract is required and
    legacy REST connections keep working** — a connection with no Desktop
    Gateway simply has no journal scope and reports nothing. The rules pinned
    by test: `waiting_input` and `failed` become attention with distinct
    reasons, a *recovery* failure is attention even on a turn the server
    completed (the composer stays blocked, which is the whole point), a turn
    with no status yet still counts as running because the submit is
    outstanding, attention outranks a concurrent running turn on the same
    session so a chat is never drawn twice, the freshest blocking reason wins,
    a running turn whose entry has not moved for `kHomeRunningStaleAfter` is
    dropped rather than displayed as live while blocked work is never aged
    out, a clock skewed behind the journal keeps the turn running rather than
    hiding it, and entries whose binding belongs to another connection *or
    another gateway endpoint* are excluded. The endpoint scope comes from the
    new `DesktopGatewayClient.endpointDigestFor`, which the client itself now
    uses when constructing the coordinator registry, so the scope Home reads
    can never drift from the one the coordinator writes — one test asserts
    the two are byte-identical. On the screen side: blocked work raises the
    Home badge so it is visible from Projects or More, returning from a chat
    re-reads the signals as well as the sessions (the reason a chat was
    blocked usually stops being true inside it), and a journal read that
    throws degrades the *ranking* to empty without ever blanking or blocking
    the screen — the signal read is deliberately not awaited before the
    sessions render, so a slow secure-storage read costs a better ranking a
    frame later rather than a skeleton.

17. the **global New button** — `test/new_chat_options_test.dart`,
    `test/workspace_screen_test.dart`, `test/hermes_shell_test.dart`. Home
    could rank and open existing work but never *start* any. The two validated
    creation modes now live in the pure `new_chat_options.dart` helper —
    `buildNewChatOptions` decides what is runnable, `buildNewChatDraft` shapes
    the session — so the product rules are assertable without pumping a frame.
    What is pinned by test: both modes are always listed and a mode that
    cannot run is returned *disabled with a reason* rather than hidden, an
    unprobed gateway says it is still loading instead of claiming Projects are
    unsupported, a `native` gateway with no project yet asks for one instead
    of blaming the gateway, an archived project cannot enable Project chat
    while a *stale cached* listing still can (offline degrades freshness, not
    the ability to work), **Quick chat stays enabled on a legacy gateway** so
    a REST-only connection can still start work from Home, a Quick chat never
    inherits the active project even when one is passed, it is marked `Quick`
    and carries its `kQuickChatRetention` (72 h) deadline, a Project chat
    without a project throws rather than silently degrading to a Quick chat,
    and the drafted session is shaped like one the gateway returns
    (seconds-since-epoch `startedAt`, so a brand new chat ranks correctly in
    the digest instead of at 1970). On the screen side: the button appears on
    Home only, the picker is skipped when exactly one project exists,
    dismissing either sheet creates nothing, each tap gets a fresh session id,
    and the shipped default really opens a `ChatScreen` through the same
    `_openSession` path as a Home row — so a chat started from New inherits
    the application-scoped turn controller and durable recovery.

    One real regression was found and fixed by this slice rather than shipped:
    a FAB placed on the *outer* `Scaffold` floated over the shell's own bottom
    bar and swallowed every tap on the `More` destination. `HermesShell` now
    owns `floatingActionButton` for both the bar and the rail layout, and
    `hermes_shell_test.dart` pins that navigation still works underneath one.

Still open in Phase 0: step 7 of the slice above (real Gateway smoke test on a
device). The migration *write* path stays unimplemented on purpose until the
preview has been validated against a real gateway.

18. the **Activity destination** — `test/activity_feed_test.dart`,
    `test/activity_pane_test.dart`, `test/workspace_screen_test.dart`. The
    fourth shell destination was the last `Coming next` placeholder. It now
    renders a real global operational timeline, split the same way the rest of
    Phase 1 is: the pure `buildActivityFeed` helper in
    `lib/core/utils/activity_feed.dart` owns every grouping rule, and
    `ActivityPane` in `lib/core/widgets/activity_pane.dart` owns only
    presentation and the four designed states.

    Its source is the durable turn recovery journal — the same store
    `buildHomeTurnSignals` reads — so **no new gateway contract is required
    and legacy REST connections keep working**: a connection with no Desktop
    Gateway has no journal scope and reports an empty timeline rather than an
    error. Where Activity deliberately differs from Home is recorded by test
    rather than left implicit: Home deduplicates to one row per *chat* because
    it ranks conversations, while Activity emits one row per *turn* because it
    is a timeline of work, so a chat that ran three jobs reports three rows;
    and where Home silently drops a running turn whose journal entry has gone
    stale (drawing it as live would be a lie), Activity reports it as
    `Stalled — no update from Hermes`, because an operational timeline that
    quietly loses work is worse than one that admits it. Also pinned: groups
    emit in the validated order Needs you > Running > Failed > Completed with
    empty groups dropped, a recovery failure outranks the status the server
    reported (a turn the server completed but the client could not reconcile
    leaves the composer blocked, so filing it under Completed would state the
    opposite of the truth), an interrupted turn reads as `Stopped` rather than
    as completed work, blocked work is never aged out while finished work
    respects its window, a clock skewed behind the journal keeps a turn
    running instead of fabricating a failure, entries whose binding belongs to
    another connection *or another gateway endpoint* are excluded, a capped
    group reports its overflow while the badge counts ignore the cap, and an
    enum-driven test iterates `GatewayRecoveryTurnStatus.values` so a status
    added later must be classified deliberately instead of vanishing from the
    timeline.

    On the screen side the pane matches `HomePane` on purpose, so the two
    never disagree about the same failure: a skeleton holds the screen until
    the first read lands, a *first* read that fails becomes a retryable
    `ErrorState`, a *later* failure keeps the last known timeline behind an
    offline notice, and an empty feed becomes the calm `Nothing is running`
    state. Rows state their elapsed time (a blocked row without "for how long"
    is not actionable) and are drawn inert rather than fake-tappable when no
    handler is supplied.

    Two wiring rules are pinned at the real call site in `WorkspaceScreen`.
    First, the journal stores no prose, so the timeline would otherwise read
    `Untitled chat` end to end: titles are reused from the session list Home
    already fetched, at no extra request and no new contract, and a turn whose
    chat is absent keeps its row untitled rather than being dropped or given a
    fabricated name. Second, the journal outlives a deleted session, so a row
    naming a chat the gateway no longer has is a deliberate no-op instead of a
    push to a screen that can never load. The Activity badge is refreshed from
    the Home read as well as from the pane, because a badge that only appears
    once the user visits Activity cannot do the one job a badge has.

19. the **`projects.project_sessions` drill-in contract** —
    `test/project_sessions_tree_test.dart`. `ProjectsRepository` was specified
    to wrap `projects.list/create/update/archive/delete/set_active/tree/
    project_sessions`, but only the mutation half existed: nothing could answer
    *which chats live in this project*, so opening a project card had nowhere
    to go. `ProjectsGatewayClient.projectSessions` now calls the native RPC and
    parses it into `ProjectSessionsTree`
    (`lib/core/models/project_sessions_tree.dart`), mirroring the server's own
    project → repo → lane grouping from `tui_gateway/project_tree.py` rather
    than deriving a second one on device — Android and Desktop cannot disagree
    about where a chat belongs if only one of them decides. Lane rows decode
    into the same `Session` model the chat list already renders, so a project
    chat will open through the existing route with no parallel model.

    Pinned by test: an unknown project id answers `{"project": null}` and is
    read as an *empty* result rather than an error (the caller shows "no chats
    yet", never a red screen), a repo the server seeded with no lanes is kept
    because a brand-new project is exactly that and dropping it would render
    an entered project blank, a sparse compacted row renders with defaults
    instead of crashing the project view while a row with **no id** is dropped
    (it could only ever be a dead tap target), `allSessions` flattens lanes in
    server order and de-duplicates a chat that legitimately appears under two
    lanes, a repo with no reported `sessionCount` falls back to the rows it
    actually holds, a blank id throws without spending a request, and a 5063
    argument rejection stays a `JsonRpcError` instead of being misread as an
    old gateway.

    One real bug was found by this slice rather than shipped. Any unknown
    `projects.*` method set the cached family verdict to unsupported, so a
    gateway that serves `projects.list` perfectly but predates the drill-in
    would have dropped the **whole** Projects pane into local-only
    compatibility mode — permanently, since the verdict is cached and nothing
    re-probes. Support is now decided by `projects.list` alone; a missing
    sibling is recorded against that method in the `CapabilityRegistry` and
    leaves the family intact. Both directions are pinned, so the guard cannot
    be loosened into never detecting a genuinely old gateway either.

Still open in Phase 0: step 7 (real Gateway smoke test on a device). It cannot
run unattended — no device is attached in the automated environment — and it
remains the only item blocking the migration *write* path. Every Phase 1 shell
destination (Home, Projects, Activity, More) is implemented and covered, so no
*screen* slice should begin until the shell has been validated against a real
gateway on hardware; the data layer above is contract-level work that the
device test does not gate.

Note for a later slice: `NewChatDraft.projectId` and `expiresAt` are currently
*carried* rather than *persisted*. Associating a new chat with its server
Project, and enforcing the 72 h Quick-chat archive, both belong to the write
path that Phase 0 deliberately leaves unimplemented until the migration
preview is validated against a real gateway.

---

## Validated product decisions

1. **Primary navigation:** Home / Projects / Activity / More.
2. **Quick Chat default:** auto-archive after 72 hours, remain searchable, and use normal Hermes/Hindsight memory so interesting durable information is retained.
3. **AI default:** automatically file into existing Projects at high confidence, but only propose new Projects; autonomous Project creation remains an opt-in.

Validated by Carlos on 2026-08-25. Phase 0 can begin without further product ambiguity.

---

## Evidence reviewed

- current Flutter fork and tests in `CarlosReyesPena/hermes-android`;
- upstream `rusty4444/hermes-android` and 44-fork ecosystem;
- CristianGCiocoi, grunjol, and danlil240 fork diffs;
- official Hermes Desktop Projects, Files, Artifacts, Settings, and remote filesystem implementation;
- Hermes Gateway `projects.*` RPC implementation and tests;
- Hermes Dashboard `/api/fs/*`, managed files, and Git routes;
- NousResearch/hermes-agent PR #52673 mobile shell source and history;
- `goldenduo/hermes-agent-for-android` public repository contents.
