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
| 2 | Database refactor (`init(directory:)`, `Database.current`, rename ~55 sites) | pending | mechanical |
| 3 | App launch + legacy migration | pending | wires bootstrap into `NewsCombApp.init` |
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

(pending)

### Phase 3 — App launch + legacy migration

(pending)

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
