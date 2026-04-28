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
| 4 | Workspace switch operation | pending | refuse-while-busy is core invariant |
| 5 | MCP `X-Workspace` header | pending | v2-ready wire protocol |
| 6 | UI (File menu, window title, Settings, first-run sheet) | pending | macOS only |
| 7 | Test coverage sweep | pending | fill gaps from prior phases |
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

(pending)

### Phase 5 — MCP X-Workspace assertion

(pending)

### Phase 6 — UI

(pending)

### Phase 7 — Test coverage sweep

(pending)

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
