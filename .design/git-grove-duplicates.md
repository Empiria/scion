# Git Grove Duplicates: Multiple Groves per Git Repository

**Created:** 2026-03-28
**Status:** Draft
**Related:** `hosted/git-groves.md`, `hosted/hub-groves.md`, `hosted/hosted-architecture.md`

---

## 1. Overview

Today, the system enforces a **1:1 relationship between git remote URLs and groves**. This is implemented through:

1. **Deterministic UUID5 IDs** — `HashGroveID(NormalizeGitRemote(url))` always produces the same grove ID for a given repository, making grove creation idempotent.
2. **UNIQUE constraint on `git_remote`** in the database schema, preventing multiple groves from sharing the same normalized remote URL.
3. **Lookup-by-git-remote** in the registration flow, which returns an existing grove rather than creating a new one when the URL matches.
4. **Suppressed "Register as new" option** in the linking dialog when `hasGitRemote=true`.

This design worked well for the initial model where one grove = one project = one repository. However, it prevents teams from running **multiple independent agent groups against the same repository** — a critical use case for larger projects where separate feature teams should work in isolation.

### Motivating Use Case

A team working on `github.com/acme/widgets` wants three independent groves:

- `acme-widgets` — mainline development, general-purpose agents
- `acme-widgets-1` — Team A working on the auth rewrite
- `acme-widgets-2` — Team B working on the API v2 migration

Each grove has its own set of agents, templates, and settings. Agents in one grove do not see or interact with agents in another grove, even though they all work against the same repository.

### Goals

1. Allow multiple groves to reference the same git remote URL.
2. Preserve convenient linking of local checkouts to existing hub groves.
3. Enforce unique slugs across all groves (with automatic serial numbering for duplicates).
4. Maintain backward compatibility — existing single-grove-per-repo workflows continue to work without changes.

### Non-Goals

- Merging or synchronizing work between groves sharing the same repository.
- Cross-grove agent visibility or communication.
- Changing the hub-native (non-git) grove model.

---

## 2. Current State Analysis

### 2.1 Where the 1:1 Assumption is Encoded

| Location | Mechanism | Impact |
|----------|-----------|--------|
| `pkg/util/git.go:710` | `HashGroveID()` — deterministic UUID5 from normalized URL | Same URL always = same ID |
| `pkg/store/sqlite/sqlite.go:174` | `git_remote TEXT UNIQUE` constraint | DB rejects duplicate git remotes |
| `pkg/hub/handlers.go:2605-2612` | `createGrove()` derives ID from git remote | New groves auto-collide on ID |
| `pkg/hub/handlers.go:3185-3193` | `handleGroveRegister()` looks up by git remote | Registration returns existing grove |
| `pkg/hubsync/prompt.go:172` | `hasGitRemote` suppresses "Register as new" option | Users cannot create duplicates via link dialog |
| `pkg/config/init.go:109-117` | `GenerateGroveID()` hashes git remote | Local init produces deterministic ID |
| `pkg/ent/schema/grove.go:46` | Ent schema: `git_remote` field marked `Unique()` | ORM enforces uniqueness |

### 2.2 Branch Qualifier (Partial Solution)

The system already supports an `@branch` qualifier in the identity string (e.g., `github.com/acme/widgets@release/v2`), which produces a different grove ID. However, this is tied to a specific branch and doesn't cover the general case of multiple teams working on the same branch or across branches freely.

### 2.3 Local Grove ID vs Hub Grove ID

The system already separates `grove_id` (local, drives config-dir paths) from `hub.groveId` (explicit hub link). This separation is crucial and will be preserved — it means local grove identity can differ from the hub grove being linked to.

---

## 3. Proposed Design

### 3.1 Remove the UNIQUE Constraint on `git_remote`

The `git_remote` column becomes a regular indexed (non-unique) column. Multiple grove records can share the same normalized git remote URL.

**Migration:**

```sql
-- Drop the unique index on git_remote and replace with a regular index.
-- The existing idx_groves_git_remote already exists as a regular index,
-- so we only need to drop the UNIQUE constraint added inline on the column.
-- SQLite requires table recreation for column constraint changes.
```

Since SQLite doesn't support `ALTER TABLE ... DROP CONSTRAINT`, the migration will use the standard recreate-table pattern.

### 3.2 Move Away from Deterministic UUID5 for Grove IDs

**New behavior:** Grove IDs are always randomly generated UUIDs (`uuid.New()`), regardless of whether the grove has a git remote.

**Rationale:** Deterministic IDs were designed to enforce the 1:1 mapping. With multiple groves per URL, deterministic IDs would cause collisions. Random UUIDs are already used for hub-native groves and work correctly.

**`HashGroveID()` is retained** but repurposed: it is no longer used for grove ID generation. It may still be useful for other deterministic identifiers (e.g., cache keys), so it is not removed. Callers that used it for grove ID generation are updated.

**`GenerateGroveID()` and `GenerateGroveIDForDir()` simplified:** Always return `uuid.New().String()`.

### 3.3 Enforce Unique Slugs with Serial Numbering

Slugs must remain unique because they are used in:
- Filesystem paths (`~/.scion/groves/<slug>/` for hub-native, `~/.scion/grove-configs/<slug>__<uuid>/` for external)
- API routing (`/api/v1/groves/<slug-or-id>/...`)
- CLI references (`scion start agent --grove <slug>`)

**Slug generation for duplicate git remotes:**

When a grove is created for a git remote that already has one or more groves, the slug is derived with a serial suffix:

1. Base slug derived from repo name: `acme-widgets`
2. If `acme-widgets` is taken: `acme-widgets-1`
3. If `acme-widgets-1` is taken: `acme-widgets-2`
4. And so on.

**Implementation:** A new store method `GetGrovesByGitRemote(ctx, gitRemote) ([]*Grove, error)` returns all groves for a given remote. The hub handler computes the next available slug by checking existing slugs.

**Database enforcement:** Add a proper `UNIQUE` constraint on the `slug` column (currently it's only a non-unique index in SQLite, despite the Ent schema declaring it unique — this is a pre-existing bug that this work fixes).

### 3.4 Update the Linking Dialog

The `ShowMatchingGrovesPrompt()` function is updated to **always show the "Register as new grove" option**, regardless of `hasGitRemote`. The `hasGitRemote` parameter is removed.

When creating a new grove for a URL that already has groves, the dialog shows the proposed serial-numbered slug and asks for confirmation:

```
Found 2 existing grove(s) with the name 'acme-widgets' on the Hub:

  [1] acme-widgets (ID: abc123, remote: github.com/acme/widgets)
  [2] acme-widgets-1 (ID: def456, remote: github.com/acme/widgets)
  [3] Register as a new grove (will be created as 'acme-widgets-2')

Enter choice (or 'c' to cancel):
```

### 3.5 Update the Registration Flow

**`handleGroveRegister()` changes:**

Currently the flow is:
1. Look up by client-provided ID
2. Look up by git remote (returns single grove)
3. Look up by slug (for non-git groves)
4. Create if not found

New flow:
1. Look up by client-provided ID (unchanged)
2. Look up by git remote → returns **list** of matching groves
   - If exactly one match and no explicit ID was provided: return it (backward compatible for existing single-grove setups)
   - If multiple matches: return the list for client-side disambiguation (or use slug to pick one)
3. Look up by slug (for non-git groves, unchanged)
4. Create if not found (with random UUID, serial slug)

**`createGrove()` changes:**

- No longer derives ID from git remote. Always uses client-provided ID or generates a random UUID.
- Computes serial-numbered slug when git remote already has groves.
- Validates slug uniqueness before insert.

### 3.6 Local `scion init` Changes

`GenerateGroveID()` always returns a random UUID. This means re-running `scion init` in the same repository will produce a different grove ID each time (rather than the same deterministic one). This is acceptable because:

- `scion init` is typically run once per project.
- The grove ID is persisted in `.scion/grove-id` (git groves) or the marker file (external groves), so it doesn't need to be re-derivable.
- Hub linking uses name/slug matching (not ID matching) for discovery, so a different local ID doesn't prevent linking.

### 3.7 Preserve Clone vs Shared Workspace Modes

Both workspace strategies continue to work unchanged:
- **Shared workspace (local):** Agents share a bind-mounted worktree from the host.
- **Clone (hub-first):** Agents clone the repository at startup.

The workspace strategy is determined by grove configuration, not by the number of groves sharing a URL.

---

## 4. API Changes

### 4.1 `POST /api/v1/groves` (createGrove)

**Request:** No structural changes. The `id` field becomes optional (random UUID if omitted). The `gitRemote` field is no longer required to be unique.

**Response:** Unchanged. Returns the created grove.

**Behavior change:** No longer returns an existing grove when `gitRemote` matches. Each call creates a new grove. Idempotency is achieved by client-provided `id` only.

### 4.2 `POST /api/v1/groves/register` (handleGroveRegister)

**Request:** Unchanged.

**Response:** Extended with a `matches` field when multiple groves share the same git remote:

```json
{
  "grove": { ... },
  "created": false,
  "matches": [
    { "id": "abc123", "name": "acme-widgets", "slug": "acme-widgets" },
    { "id": "def456", "name": "acme-widgets", "slug": "acme-widgets-1" }
  ]
}
```

When `matches` has more than one entry, the client should prompt the user to choose. When it has exactly one entry, the existing behavior (auto-link) is preserved for backward compatibility.

### 4.3 `GET /api/v1/groves` (listGroves)

**Filter addition:** `gitRemote` filter already exists but currently returns at most one result. After this change, it may return multiple results. No API change needed.

### 4.4 Store Interface Changes

**New method:**
```go
// GetGrovesByGitRemote returns all groves matching the normalized git remote.
// Returns empty slice (not error) if none found.
GetGrovesByGitRemote(ctx context.Context, gitRemote string) ([]*Grove, error)
```

**Modified method:**
`GetGroveByGitRemote` is retained for backward compatibility but may return the first match (by creation date) when multiple exist. Callers that need all matches use `GetGrovesByGitRemote`.

---

## 5. Alternatives Considered

### 5.1 Extend the Branch Qualifier Model

**Approach:** Require users to specify a branch (or arbitrary qualifier) when creating duplicate groves, extending the existing `@branch` mechanism.

**Pros:**
- Minimal schema changes — the identity string is different, so UUID5 and UNIQUE constraints still work.
- Natural semantic meaning when groves actually target different branches.

**Cons:**
- Artificial when teams work across branches freely (the qualifier becomes meaningless, e.g., `@team-a`).
- Couples grove identity to branch selection, which may not reflect actual usage.
- The existing `@branch` mechanism stores the qualifier in the normalized remote and labels, creating a tighter coupling than desired.

**Decision:** Rejected as the primary mechanism. The `@branch` qualifier remains available for branch-specific groves but is not the solution for the general multi-team case.

### 5.2 Grove "Groups" or "Namespaces"

**Approach:** Introduce a namespace/group layer above groves, where a git remote maps to a group and individual groves exist within it.

**Pros:**
- Clean hierarchical model.
- Could support cross-grove features (shared templates, agent migration) in the future.

**Cons:**
- Significant schema and API changes (new entity, new relationships).
- Over-engineered for the immediate need.
- Adds conceptual complexity for users.

**Decision:** Rejected for now. May be revisited if cross-grove coordination becomes a requirement.

### 5.3 Keep Deterministic IDs, Use Composite Key

**Approach:** Keep UUID5 but include a sequence number in the hash input: `HashGroveID(normalized + "#2")`.

**Pros:**
- Deterministic IDs are preserved (useful for idempotent creation in some flows).

**Cons:**
- The sequence number itself needs coordination (what if two clients try to create grove #2 simultaneously?).
- Deterministic creation was valuable precisely because it avoided coordination — adding a sequence number undermines the benefit.
- Random UUIDs are simpler and already proven (hub-native groves use them).

**Decision:** Rejected. Random UUIDs are simpler and sufficient.

### 5.4 Allow Duplicate Slugs (Disambiguate by ID)

**Approach:** Allow multiple groves to share the same slug. Use ID for disambiguation in API calls.

**Pros:**
- Simpler slug generation (no serial numbering).

**Cons:**
- Breaks CLI usability (`scion start agent --grove acme-widgets` becomes ambiguous).
- Breaks filesystem path derivation (slug is used in directory names).
- Breaks API routing (slug is used as grove identifier in URLs).

**Decision:** Rejected. Slug uniqueness is a hard requirement.

---

## 6. Open Questions

### Q1: Should `GetGroveByGitRemote` return the "primary" grove?

When multiple groves share a git remote, `GetGroveByGitRemote` currently returns a single grove. After removing the UNIQUE constraint, it could return:
- The oldest (first created) grove — preserves backward compatibility for existing integrations.
- An error requiring callers to use `GetGrovesByGitRemote` — forces explicit handling.

**Proposed answer:** Return the oldest grove. This preserves backward compatibility for the `EnsureHubReady` flow where a broker auto-links to a grove. New code paths should use `GetGrovesByGitRemote`.

### Q2: Should the serial suffix be on the slug only, or also the display name?

Options:
- Slug only: name="acme-widgets", slug="acme-widgets-2" — cleaner display but potentially confusing.
- Both: name="acme-widgets-2", slug="acme-widgets-2" — consistent but less friendly.
- Name with qualifier: name="acme-widgets (2)", slug="acme-widgets-2" — best of both.

**Proposed answer:** The user should be prompted to provide a distinct display name. The serial-numbered slug is offered as a default, but the name field remains user-editable. If not explicitly set, name defaults to match the slug.

### Q3: How should `EnsureHubReady` behave with multiple matches?

The auto-sync flow (`EnsureHubReady`) currently finds a grove by ID or git remote and auto-links. With multiple groves per remote, it needs a disambiguation strategy:
- If the local `grove_id` matches a hub grove ID exactly: use that grove (unchanged).
- If the local `hub.groveId` setting is set: use that grove (unchanged).
- If neither matches but git remote matches multiple groves: prompt the user (extending current name-match behavior).

**Proposed answer:** Use the existing disambiguation flow. The prompt already handles multiple matches by name — extend it to also trigger for multiple git remote matches.

### Q4: Impact on GitHub App integration?

The GitHub App installation is tied to a grove record. With multiple groves per repo, should the GitHub App installation be shared or per-grove?

**Proposed answer:** Per-grove. Each grove independently configures its GitHub App integration. This is consistent with groves being independent workspaces.

### Q5: Should we add a `UNIQUE` constraint on `slug` in this migration?

The Ent schema declares `slug` as `Unique()`, but the SQLite implementation only has a non-unique index. This is a pre-existing bug. Should this migration fix it?

**Proposed answer:** Yes. This migration should add the proper UNIQUE constraint on `slug`, fixing the existing discrepancy and ensuring the serial-numbering logic is actually enforced at the database level.

---

## 7. Migration Considerations

### 7.1 Existing Data

All existing groves retain their current IDs, slugs, and git remote values. No data migration is needed — only the constraint is relaxed.

### 7.2 Backward Compatibility

- **Existing single-grove-per-repo setups:** Continue to work identically. The registration flow returns the existing grove when exactly one matches.
- **Existing local configurations:** `grove_id` and `hub.groveId` settings are preserved. No local config changes needed.
- **Hub API clients:** The `register` endpoint returns a new `matches` field but the existing `grove` field is still populated. Old clients that ignore `matches` continue to work (they get the first/only match).

### 7.3 Rollback

If this change needs to be reverted, groves that were created as duplicates (sharing a git remote) would need to be manually deleted or have their git remotes cleared before re-adding the UNIQUE constraint.

---

## 8. Implementation Phases

### Phase 1: Schema and Store Layer

**Goal:** Remove the 1:1 constraint and add slug uniqueness enforcement.

1. **Database migration:** Drop UNIQUE constraint on `git_remote`, add UNIQUE constraint on `slug`.
2. **New store method:** `GetGrovesByGitRemote()` returning `[]*Grove`.
3. **Update `GetGroveByGitRemote()`:** Return oldest match when multiple exist.
4. **Update Ent schema:** Remove `Unique()` from `git_remote` field.
5. **Slug validation helper:** `NextAvailableSlug(ctx, baseSlug) string` that queries existing slugs and returns the next serial-numbered variant.
6. **Tests:** Store-level tests for multi-grove-per-remote scenarios, slug uniqueness enforcement, and serial numbering.

### Phase 2: Grove ID Generation

**Goal:** Stop generating deterministic IDs from git remotes.

1. **Simplify `GenerateGroveID()` and `GenerateGroveIDForDir()`:** Always return `uuid.New().String()`.
2. **Update `createGrove()` handler:** Remove deterministic ID derivation from git remote. Use client-provided ID or random UUID.
3. **Update `handleGroveRegister()` handler:** Same — no deterministic ID fallback.
4. **Update `scion hub grove create` CLI command:** Remove `HashGroveID()` call for ID generation.
5. **Retain `HashGroveID()` function:** Mark as not used for grove IDs but keep for other potential uses.
6. **Tests:** Verify that creating two groves for the same URL produces different IDs.

### Phase 3: Registration and Linking Flow

**Goal:** Support creating new groves for URLs that already have groves.

1. **Update `handleGroveRegister()`:** When git remote matches multiple groves, return the match list in the response. When exactly one match, preserve current auto-link behavior.
2. **Update `RegisterGroveResponse`:** Add `Matches []GroveMatch` field.
3. **Update `ShowMatchingGrovesPrompt()`:** Remove `hasGitRemote` parameter. Always show "Register as new grove" option. Show proposed serial-numbered slug.
4. **Update `runHubLink()`:** Handle multiple git remote matches by showing the disambiguation prompt.
5. **Update `EnsureHubReady()`:** When git remote matches multiple groves, trigger the disambiguation prompt (same as name-match flow).
6. **Serial slug display:** Show the next available slug in the "Register as new" option.
7. **Tests:** End-to-end linking flow with multiple groves per remote.

### Phase 4: CLI and Hub-First Creation

**Goal:** Allow hub-first creation of duplicate groves.

1. **Update `scion hub grove create`:** When the URL already has a grove, show existing groves and offer to create a new one with the serial-numbered slug.
2. **Add `--slug` override validation:** Verify provided slug is unique before creation.
3. **Update web UI grove creation:** When git URL matches existing groves, show them and allow creation of a new grove with the next serial slug.
4. **Tests:** CLI integration tests for duplicate grove creation.

### Phase 5: Cleanup and Documentation

1. **Audit all callers of `HashGroveID()`:** Ensure none rely on it for grove ID generation.
2. **Audit all callers of `GetGroveByGitRemote()`:** Ensure they handle the possibility of the "first match" behavior correctly, or switch to `GetGrovesByGitRemote()`.
3. **Update design docs:** Mark `git-groves.md` section 2.2 as superseded by this design.
4. **Update test fixtures:** Any test that assumes git remote uniqueness or deterministic IDs.

---

## 9. Affected Files

| File | Change |
|------|--------|
| `pkg/store/sqlite/sqlite.go` | Migration: drop UNIQUE on git_remote, add UNIQUE on slug. New `GetGrovesByGitRemote()`. |
| `pkg/store/store.go` | Add `GetGrovesByGitRemote()` to interface. |
| `pkg/store/models.go` | No structural changes. |
| `pkg/ent/schema/grove.go` | Remove `.Unique()` from `git_remote` field. |
| `pkg/ent/migrate/schema.go` | Update generated migration schema. |
| `pkg/config/init.go` | Simplify `GenerateGroveID()` / `GenerateGroveIDForDir()`. |
| `pkg/hub/handlers.go` | Update `createGrove()`, `handleGroveRegister()`. |
| `pkg/hubsync/prompt.go` | Update `ShowMatchingGrovesPrompt()` — remove `hasGitRemote` param, show serial slug. |
| `pkg/hubsync/sync.go` | Update `EnsureHubReady()` for multi-match handling. |
| `cmd/hub.go` | Update `runHubLink()`, `scion hub grove create`. |
| `pkg/util/git.go` | No changes to `HashGroveID()` itself, but callers change. |
| `pkg/hub/handlers_grove_test.go` | Update tests for new behavior. |
| `pkg/util/git_test.go` | Update/add tests. |
