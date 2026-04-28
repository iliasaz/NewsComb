# Workspaces — Implementation Plan

Branch: `feature/workspaces`
Started: 2026-04-28
Status: in progress

## Goal

Allow NewsComb to work on multiple independent SQLite knowledge bases. A
**workspace** is a directory containing `newscomb.sqlite` (and any side
artifacts). The user picks which workspace the app is using; the same
SwiftUI app + same MCP server target whichever workspace is currently
active.

## Non-goals (v1)

- Running multiple NewsComb processes concurrently, each on its own
  workspace. Postponed to v2. The wire protocol is designed v2-ready
  (see Phase 5) so users won't need to change MCP config when v2 ships.

## Decisions

- **Recent workspaces**: last 10, stored in `UserDefaults`.
- **Default workspace location**: `~/Documents/NewsComb-Workspaces/`.
- **Switching while jobs are running**: refuse. User cancels or quits.
- **Legacy DB at `~/Library/Application Support/NewsComb/newscomb.sqlite`**:
  left in place; the parent directory becomes the "Default" workspace on
  first launch after upgrade.
- **Settings split**:
  - Workspace-scoped → existing `app_settings` table inside each DB.
  - App-global → `UserDefaults`: `lastOpenedWorkspace`, `recentWorkspaces`.
- **Database accessor**: `Database.current` (mutable, workspace-aware).
  Old `Database.shared` is removed; ~55 call sites renamed mechanically.
- **MCP**: bridge accepts `--workspace <dir>` and sends an `X-Workspace`
  header. App rejects mismatched headers with a JSON-RPC error (single
  active workspace at a time in v1).

## Architecture sketch

```
NewsCombApp.init
    ↓
WorkspaceCoordinator.bootstrap
    ↓ (resolves: --workspace arg | env | UserDefaults | legacy | picker)
    ↓
WorkspaceCoordinator.active = Workspace(directory: …)
    │
    ├─ Database.current  ← reads from coordinator
    ├─ MainViewModel     ← rebuilt on switch
    └─ MCPServerService  ← unchanged port; checks X-Workspace header
```

## Phases

| # | Title | Status | Notes |
|---|-------|--------|-------|
| 1 | Foundation types (Workspace, WorkspaceCoordinator skeleton, WorkspaceDefaults) | **done** | new files only, no behavior change |
| 2 | Database refactor (`init(directory:)`, `Database.current`, rename ~55 sites) | **done** | mechanical |
| 3 | App launch + legacy migration | **done** | wires bootstrap into `NewsCombApp.init` |
| 4 | Workspace switch operation | **done** | refuse-while-busy is core invariant; v1 ships as "stage + relaunch" |
| 5 | MCP `X-Workspace` header | **done** | v2-ready wire protocol |
| 6 | UI (File menu, window title, Settings, first-run sheet) | **done** | macOS only |
| 7 | Test coverage sweep | **done** | fill gaps from prior phases |
| 8 | Documentation (README, .mcp.json, CLAUDE.md) | pending | final commit |

## Per-phase log

Each phase adds an entry below with: scope as executed, files
touched, tests added, deviations from plan, and follow-ups.

### Phase 1 — Foundation types

**Status:** complete. 21 unit tests, all green. SwiftLint clean.

**Files added:**
- `NewsCombApp/Models/Workspace.swift` — value type (directory URL + helpers).
  Includes a top-level internal `URL.canonicalDirectoryURL` helper that
  standardizes and strips trailing `/` so `/tmp/Foo` and `/tmp/Foo/` are equal.
- `NewsCombApp/Services/WorkspaceDefaults.swift` — `UserDefaults` wrapper.
  `lastOpenedWorkspace` (single URL) and `recentWorkspaces` ([URL], capped at 10).
  Tests use a per-test `UserDefaults(suiteName:)` to avoid polluting `.standard`.
- `NewsCombApp/Services/WorkspaceCoordinator.swift` — `@MainActor @Observable`.
  `setActive(_:)` records active + persists last-opened + pushes to recents.
  Phase 2/3/4 will add Database wiring, bootstrap, and switchTo respectively.
- `NewsCombAppTests/WorkspaceTests.swift` (7 tests)
- `NewsCombAppTests/WorkspaceDefaultsTests.swift` (9 tests)
- `NewsCombAppTests/WorkspaceCoordinatorTests.swift` (5 tests)

**Deviations from plan:**
- `WorkspaceDefaults` is `@unchecked Sendable` (UserDefaults isn't Sendable in
  Swift 6, but is documented thread-safe). Acceptable for an injection-friendly
  wrapper held by the `@MainActor` coordinator.
- Added a `URL.canonicalDirectoryURL` extension (not in the original plan) once
  trailing-slash equality bit two tests. Used in both `Workspace` init and the
  defaults getters/setters/dedup helpers so canonicalization happens in exactly
  one place.

**Follow-ups for later phases:**
- Phase 2: `WorkspaceCoordinator` will gain a `database: Database` field;
  `setActive(_:)` will need a Database parameter or build one internally.
- Phase 4: `setActive(_:)` is currently the only state-change entry. Phase 4's
  `switchTo(_:)` should route through it (or supersede it) so recents/last-opened
  bookkeeping isn't duplicated.

### Phase 2 — Database refactor

**Status:** complete. 24 unit tests green (incl. DB-touching DeleteSourceGRDBTests
sanity check). SwiftLint clean (4 pre-existing warnings unchanged).

**Files modified:**
- `NewsCombApp/Services/DatabaseService.swift`:
  - Removed `static let shared`, removed `private init()`.
  - Added `public init(directory: URL) throws` — opens
    `<directory>/newscomb.sqlite`, runs migrations.
  - Added `public let workspaceDirectory: URL` (canonicalized) for callers
    that need to know which workspace they're talking to.
  - Added `private static let active = Mutex<Database?>(nil)` (Synchronization.Mutex).
  - Added `public static var current: Database` — lazy-bootstraps to
    `Workspace.legacyDirectory` if `setCurrent(_:)` hasn't been called yet.
    This is the **transitional** path that keeps existing code working until
    Phase 3 wires explicit bootstrap.
  - Added `public static func setCurrent(_:)` and `static func resetCurrentForTesting()`.
- `NewsCombApp/Services/WorkspaceCoordinator.swift`:
  - `setActive(_:)` (Phase 1) split into two:
    - `recordActive(_:)` — bookkeeping only (no I/O), useful for tests.
    - `openWorkspace(at:) throws -> Workspace` — builds Database, calls
      `Database.setCurrent`, then `recordActive`.
- 49 files: mechanical rename `Database.shared` → `Database.current` via sed.
  64 occurrences across 57 files now reference `current`. 0 `shared` remain.

**Phase 1 test updates:**
- `WorkspaceCoordinatorTests` — split into two groups:
  - bookkeeping (uses `recordActive`, no DB I/O)
  - real I/O (uses `openWorkspace` against a per-test temp directory; cleaned
    up in `tearDown` along with `Database.resetCurrentForTesting()`)

**Deviations from plan:**
- Renamed `setActive` → `recordActive` to clarify it's the internal bookkeeping
  helper. The new public API is `openWorkspace(at:)`.
- Used `Synchronization.Mutex` (already in use elsewhere — `MCPHTTPServer`)
  instead of an actor or `nonisolated(unsafe)`. Cleanest fit for a
  cross-actor singleton accessor.

**Follow-ups for later phases:**
- Phase 3: replace lazy-bootstrap fallback in `Database.current` with a
  `fatalError` once `bootstrap()` always runs at app launch.
- Phase 4: `switchWorkspace(to:)` should refuse-while-busy, then call
  `openWorkspace(at:)`, and tear down the old DB.

### Phase 3 — App launch + legacy migration

**Status:** complete. 12 new bootstrap unit tests, all green. SwiftLint clean.

**Files modified:**
- `NewsCombApp/Services/WorkspaceCoordinator.swift`:
  - Added `BootstrapSource` enum (commandLine / environment / lastOpened / legacy).
  - Added `BootstrapResult` enum (`opened(Workspace, source:)` / `needsSelection`).
  - Added `bootstrap(commandLineArgs:environment:legacyDirectory:fileManager:) throws -> BootstrapResult`
    with full dependency injection for testability.
  - Added `static func parseWorkspaceArg(from:)` — handles
    `--workspace <value>` and `--workspace=<value>` forms; rejects empty values.
- `NewsCombApp/NewsCombApp.swift`:
  - Replaced `_ = Database.current` with `try WorkspaceCoordinator.shared.bootstrap()`.
  - Logs the bootstrap source (CLI / env / lastOpened / legacy) on success.
  - Catches explicit-source failures and logs them. Falls through to the
    `Database.current` lazy fallback (Phase 6 will surface errors in the UI).

**Files added:**
- `NewsCombAppTests/WorkspaceCoordinatorBootstrapTests.swift` (12 tests):
  - 6 tests for `parseWorkspaceArg` (space form, equals form, missing, empty, etc.)
  - 6 tests for `bootstrap` resolution priority + sources + fall-through.

**Resolution priority:**
1. `--workspace <path>` CLI arg — explicit, errors propagate.
2. `NEWSCOMB_WORKSPACE` env var — explicit, errors propagate.
3. `WorkspaceDefaults.lastOpenedWorkspace` — implicit, falls through if dir missing.
4. Legacy `~/Library/Application Support/NewsComb/newscomb.sqlite` — implicit.
5. Returns `.needsSelection` — UI handles in Phase 6.

**Deviations from plan:**
- Made `legacyDirectory` an injectable parameter on `bootstrap` rather than
  a hardcoded reference to `Workspace.legacyDirectory`. Lets tests simulate
  legacy detection without touching the user's actual Application Support dir.
- Implicit-source failures (deleted lastOpened directory, broken legacy DB)
  log + fall through rather than throwing. Explicit-source failures throw —
  user-supplied bad input should fail loudly.

**Follow-ups for later phases:**
- Phase 4: `switchWorkspace(to:)` reuses `openWorkspace(at:)` + `Database.setCurrent`.
  Adds refuse-while-busy and tear-down semantics.
- Phase 6: capture bootstrap errors in coordinator state for UI display.
  Show first-run picker when bootstrap returns `.needsSelection`.

### Phase 4 — Workspace switch operation

**Status:** complete. 9 unit tests, all green. SwiftLint clean.

**Design decision:** rather than tear down `Database.current` and rebuild
`MainViewModel` while SwiftUI views hold references (fragile), v1 ships as
"stage + relaunch". `switchWorkspace(to:)` validates and persists; the UI
relaunches the app, and Phase 3's `bootstrap()` resolves the new workspace
cleanly. Same UX, dramatically less complexity.

**Files modified:**
- `NewsCombApp/Services/WorkspaceCoordinator.swift`:
  - Added `busyReasonsProvider: () -> [String]` (injectable for tests).
  - Added `var busyReasons: [String]` and `var canSwitchWorkspace: Bool`.
  - Added `static func defaultBusyReasons()` that inspects `MainViewModel.shared`
    for in-flight operations: hypergraph processing, RSS refresh, OPML import,
    graph reset, graph simplification, node classification.
  - Added `enum SwitchError: Error, LocalizedError, Equatable` with
    `.busy(reasons:)` case.
  - Added `switchWorkspace(to:) throws -> Workspace` — validates busy state,
    persists target as last-opened, pushes to recents. **Does not relaunch.**

**Files added:**
- `NewsCombAppTests/WorkspaceCoordinatorSwitchTests.swift` (9 tests):
  - Busy gating (true/false).
  - Switch succeeds when not busy / refuses when busy / lists all reasons.
  - Persists last-opened + pushes to recents.
  - Does NOT change `active` or open the database (relaunch will).
  - Error message formatting.

**Deviations from plan:**
- "Rebuild MainViewModel" became unnecessary because we relaunch instead.
  Caller (Phase 6 UI) is responsible for the actual `NSApplication.terminate` +
  `Process.run("open <bundle path>")` choreography.
- `busyReasonsProvider` is injectable rather than hardcoded so tests don't
  depend on `MainViewModel.shared` state.

**Follow-ups:**
- Phase 6: UI handles the relaunch choreography after `switchWorkspace(to:)`
  succeeds. Show an alert with "busy because…" reasons when it throws.

### Phase 5 — MCP X-Workspace assertion

**Status:** complete. 14 unit tests, all green. Existing MCPToolTests still pass.

**Files added:**
- `NewsCombApp/MCP/MCPWorkspaceValidator.swift` — pure value-level validator.
  `validate(requestedHeader:active:) -> ValidationFailure?` decides allow vs.
  reject. Two failure cases: `.noActiveWorkspace(requested:)` and
  `.mismatch(active:requested:)`. JSON-RPC error code -32001 (server-defined).

**Files modified:**
- `NewsCombApp/MCP/MCPHTTPServer.swift`:
  - `dispatchRequest` checks the `X-Workspace` header before routing to a
    transport. Mismatch → 400 Bad Request with a JSON-RPC error body.
  - Added `validateWorkspaceHeader(_:)` (hops to MainActor for the active
    workspace lookup).
  - Added `static func makeJSONRPCErrorHTTPResponse(requestId:code:message:)` —
    constructs HTTP/1.1 400 with JSON body, escapes quotes/backslashes.
  - Added `static func extractRequestId(from:)` — extracts the JSON-RPC `id`
    (string or int) from a request body.
- `NewsCombMCPBridge/Sources/main.swift`:
  - Parses `--workspace <path>` / `--workspace=<path>` from `CommandLine.arguments`.
  - Falls back to `NEWSCOMB_WORKSPACE` env var.
  - When set, sends `X-Workspace: <path>` on every POST so the app can assert.

**Files added (tests):**
- `NewsCombAppTests/MCPWorkspaceValidatorTests.swift` (14 tests):
  - 4 allow-path tests (no header / empty / matching / matching-with-trailing-slash).
  - 2 reject-path tests (no active workspace / mismatch).
  - 3 message-formatting tests.
  - 5 JSON-RPC response-formatting + ID-extraction tests.

**Backward compatibility:** Bridges that don't send `X-Workspace` (older
versions, manual curl, third-party clients) are accepted unchanged. Only
explicit assertions are checked.

**v2 readiness:** The wire protocol (`--workspace <path>` → `X-Workspace`
header → server-side dispatch) is the same shape v2 will use for routing to
multiple app processes by port. v1 only validates equality; v2 will add a
discovery step. **No future config changes required for users.**

**Follow-ups:**
- Phase 6: surface a "MCP rejected" notification in the app UI when an
  `X-Workspace` mismatch is logged (so the user knows to switch the workspace).
- Phase 8: update `.mcp.json` examples to show `--workspace` arg.

### Phase 6 — UI

**Status:** complete. Build clean. SwiftLint clean. New observable-recents
tests added; full workspace suite (~50 tests) green.

**Files added:**
- `NewsCombApp/Views/WorkspaceRelauncher.swift` — wraps the standard macOS
  app-relaunch pattern (spawn `/bin/sh -c "sleep 0.4 && open <bundle>"`,
  then `NSApplication.shared.terminate(nil)`).
- `NewsCombApp/Views/WorkspaceCommands.swift` — `Commands` provider injected
  via `.commands { … }` on the main `WindowGroup`. Adds File-menu items
  (after `.newItem`):
  - **New Workspace…** (⇧⌘N) — `NSOpenPanel` with `canCreateDirectories`.
  - **Open Workspace…** (⇧⌘O) — `NSOpenPanel` directories-only.
  - **Open Recent Workspace ▸** — submenu populated from
    `coordinator.recentWorkspaces` (auto-disabled when empty); includes
    "Clear Menu".
  - **Reveal Workspace in Finder** — disabled when no active workspace.
  Each switch attempt routes through `coordinator.switchWorkspace(to:)` and,
  on success, prompts an `NSAlert` with Relaunch/Cancel before calling
  `WorkspaceRelauncher.relaunchApp()`. Refused-while-busy errors surface as
  a warning alert with the human-readable reason list.
- `NewsCombApp/Views/WorkspaceSettingsSection.swift` — `Section` for the
  Settings `Form`. Shows active workspace name + path (monospaced,
  selectable, truncated middle). Buttons: Reveal in Finder, Switch
  Workspace…. Disabled-with-explanation when `busyReasons` is non-empty.
- `NewsCombApp/Views/FirstRunWorkspaceSheet.swift` — sheet shown when
  `coordinator.active == nil`. Two prominent buttons (Create New / Open
  Existing) plus an inline list of up to 5 recent workspaces. Default folder
  for the create panel is `~/Documents/NewsComb-Workspaces/`.
- `interactiveDismissDisabled(true)` — the user can't accidentally dismiss
  the first-run sheet without picking a workspace.

**Files modified:**
- `NewsCombApp/Services/WorkspaceCoordinator.swift`:
  - Added observable `recentWorkspaces: [URL]` synced from `WorkspaceDefaults`
    after each push/remove. SwiftUI menus + the first-run list track this.
  - Added `removeRecent(_:)` — used by the "Clear Menu" item.
- `NewsCombApp/NewsCombApp.swift`:
  - Attached `.commands { WorkspaceCommands(...) }` to the main `WindowGroup`
    (wrapped in its own `#if os(macOS)` because mixing modifiers and new
    scenes inside a single `#if` confuses the scene builder).
- `NewsCombApp/Views/ContentView.swift`:
  - Reads `WorkspaceCoordinator.shared`. Sets `.navigationTitle` to
    "NewsComb — &lt;workspace name&gt;" or just "NewsComb".
  - Presents `FirstRunWorkspaceSheet` via a `Binding(get:set:)` driven by
    `coordinator.active == nil`; the sheet self-dismisses when the user
    picks a workspace and `openWorkspace(at:)` flips active to non-nil.
- `NewsCombApp/Views/SettingsView.swift`:
  - Inserts `WorkspaceSettingsSection` at the top of the Form (macOS only).

**Test coverage added in Phase 6:**
- `WorkspaceCoordinatorTests.testRecentWorkspacesInitiallyMatchesDefaults`
- `WorkspaceCoordinatorTests.testRecordActiveUpdatesObservedRecents`
- `WorkspaceCoordinatorTests.testRemoveRecentUpdatesObservedList`

**Deviations from plan:**
- The relauncher is a separate file (`WorkspaceRelauncher.swift`) rather
  than living inside the coordinator. Keeps the coordinator AppKit-free
  and unit-testable from any platform.
- File-menu items are placed under `CommandGroup(after: .newItem)` so they
  group naturally with macOS's existing File-menu items.
- Window title uses `.navigationTitle(...)` on `ContentView` rather than a
  per-`WindowGroup` static title, since the workspace name is dynamic.

**Manual smoke test deferred:** the app couldn't be launched safely from
this session (would bind port 63548 and open windows). A real launch should
verify: (a) bare launch with no workspace shows the first-run sheet;
(b) File → New Workspace creates a folder + opens it; (c) Switch Workspace
prompts relaunch and reopens with the new DB; (d) menu greys out when
nothing's active.

**Follow-ups:**
- Phase 7: add a smoke test or UI test that exercises the first-run sheet
  binding logic if practical.
- Phase 8: docs.

### Phase 7 — Test coverage sweep

**Status:** complete. **530 tests passing**, 71 of them new for the
workspace feature across 7 files. The single remaining failure
(`OasisEnvironmentServiceTests.testPersonaNodeTypes_containsExpectedTypes`)
is **pre-existing on `main`** — verified by checking out `main` and
re-running. Not a workspace regression.

**Files added:**
- `NewsCombAppTests/DatabaseWorkspaceInitTests.swift` (7 tests):
  - `init(directory:)` creates the directory tree if absent.
  - `init(directory:)` creates the `newscomb.sqlite` file.
  - `init(directory:)` runs migrations — verified by spot-checking 5 core
    tables via `sqlite_master`.
  - `workspaceDirectory` is canonicalized (trailing slash stripped).
  - Two `Database` instances at different paths are independent.
  - `setCurrent(_:)` replaces the active reference.
  - `resetCurrentForTesting()` clears active without crashing on
    subsequent `setCurrent`.

**Coverage by phase (cumulative):**
| Phase | New tests |
|-------|-----------|
| 1 | 21 |
| 2 | +3 |
| 3 | +12 |
| 4 | +9 |
| 5 | +14 |
| 6 | +3 |
| 7 | +7 |
| **Total new** | **69** |

**Gaps NOT covered (intentionally):**
- UI layer (commands menu items, sheet presentation): would require
  XCUITest infrastructure that doesn't exist in the project. Manual smoke
  test deferred — see Phase 6 follow-ups.
- The relauncher itself (`Process.run` + `NSApplication.terminate`): can't
  be unit-tested without killing the test runner.
- Live MCP HTTP server reject path: tested via the pure validator + the
  HTTP-response builder; an end-to-end TCP test would add value but
  requires standing up a real port.

**Pre-existing failure (out of scope):**
- `OasisEnvironmentServiceTests.testPersonaNodeTypes_containsExpectedTypes`
  fails on both `main` and `feature/workspaces`. Out of scope for the
  workspace feature.

### Phase 8 — Documentation

(pending)

## Risks & open issues

- **MainViewModel rebuild on switch**: holds many SwiftUI bindings via
  `@Observable`. Rebuilding may briefly invalidate active views. Plan:
  switch happens via a coordinator that the views observe; views should
  re-bind to the new VM through environment injection.
- **Embedding model dimension across workspaces**: NomicEmbeddingService
  is process-wide; if two workspaces use different dimensions, the cached
  model is wrong. v1 mitigation: warn the user; lazy-reload on dimension
  mismatch.
- **In-flight MCP requests during switch**: handled by refuse-while-busy
  invariant — busy state includes pending MCP work.
