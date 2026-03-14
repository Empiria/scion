# Grove-Level Template Discovery and Hub Registration

## Status
**Exploration / Design Draft**

## 1. Problem Statement

Groves can contain their own templates in `.scion/templates/`, but these templates are not automatically known to the Hub. This creates several gaps:

1. **Linked groves**: Templates live on the broker's local filesystem and may vary across brokers serving the same grove. The Hub has no visibility into what templates a grove defines.
2. **Git groves**: Templates exist in the repository's `.scion/templates/` directory, but are only accessible inside an agent container after cloning. The Hub and web UI cannot see or offer these templates.
3. **CLI UX**: `scion templates push/sync` already supports grove-scoped uploads, but users must manually invoke it. There is no automatic discovery or suggestion flow.

### What We Want
- Grove-defined templates should be discoverable and usable from the Hub and web UI
- The experience should feel natural whether working from the CLI (where you're "inside" the grove) or the web (where you're looking at a grove from the outside)
- Multi-broker consistency for linked groves should be addressed or at least understood

---

## 2. Current State

### 2.1 Local Template Storage

Templates are stored as directories:
```
~/.scion/templates/<name>/          # Global scope
<project>/.scion/templates/<name>/  # Grove scope (in-repo or external config dir)
```

Each template directory contains `scion-agent.yaml`, `system-prompt.md`, and optional files (skills/, agents.md, etc.).

For git groves, the recent externalization change (d0507b1) moved settings and templates to the external grove-config directory (`~/.scion/grove-configs/<slug>__<uuid>/.scion/`), making them structurally consistent with non-git external groves.

### 2.2 Hub Template Storage

Templates on the Hub have a `scope` field (`"global"`, `"grove"`, `"user"`) and a `scopeID` (grove ID for grove-scoped). Storage is organized:
```
gs://bucket/templates/global/<slug>/
gs://bucket/templates/groves/<groveId>/<slug>/
gs://bucket/templates/users/<userId>/<slug>/
```

### 2.3 Template Sync (Current)

`scion templates sync <name>` uploads a local template to the Hub:
- Default scope: **grove** (uses current grove ID)
- `--global` flag: **global** scope
- Performs incremental upload via signed URLs
- Detects harness from config or template name

### 2.4 Template Resolution for Agents

When creating an agent, template resolution checks (in order):
1. Hub grove scope
2. Hub user scope
3. Hub global scope
4. Local grove filesystem
5. Local global filesystem

If a template is found only locally, the user is prompted to upload it (or `--upload-template` auto-uploads).

---

## 3. Exploration: Approaches

### Approach A: Broker-Reported Template Inventory

**Concept**: Brokers periodically scan their local grove template directories and report the inventory to the Hub. The Hub stores this as a "known templates" list per grove-provider, without uploading the actual files.

**Flow**:
1. Broker heartbeat (or grove link) includes a template manifest: `[{name, contentHash, harness}]`
2. Hub stores this per GroveProvider (broker + grove combination)
3. Web UI can display "templates available on broker X" for a grove
4. When creating an agent, the Hub can see which templates exist locally on the target broker
5. Users can trigger `sync` from the web UI to promote a broker-local template to Hub storage

**Pros**:
- Low friction: no upfront upload required
- Honest about multi-broker variance (shows per-broker inventory)
- Existing broker heartbeat infrastructure can carry this data
- Templates remain authoritative on the filesystem

**Cons**:
- Multi-broker inconsistency is visible but not solved
- Templates not actually on Hub, so cross-broker agent dispatch can't use them
- Web UI can show templates but can't inspect their contents without broker cooperation
- Adds complexity to the GroveProvider model

**Open Questions**:
- Should the manifest include file listings or just template names + hashes?
- How does this interact with the template cache on brokers?
- Should the Hub flag inconsistencies (template X on broker A but not broker B)?

---

### Approach B: Auto-Sync on Grove Link/Registration

**Concept**: When a grove is linked to the Hub (`scion hub link`) or when a broker registers as a provider, automatically sync grove-local templates to the Hub at grove scope.

**Flow**:
1. `scion hub link` detects templates in `.scion/templates/`
2. Each template is automatically uploaded to Hub at grove scope (same as `scion templates sync`)
3. For linked groves: first broker to link seeds the Hub; subsequent brokers can pull from Hub
4. For git groves: templates are synced when the grove is created from a git URL (requires cloning to discover templates)

**Pros**:
- Templates become Hub-native automatically
- Cross-broker consistency solved: Hub is source of truth after initial sync
- Web UI has full template content for display/editing
- Works with existing sync infrastructure

**Cons**:
- Which broker's version wins? First-write-wins may not be correct
- Git groves require a clone to discover templates (expensive for `grove create`)
- Users may not expect `hub link` to upload their templates
- Ongoing drift: local edits aren't auto-synced (need a sync trigger)
- Privacy/security: some grove templates may contain sensitive instructions

**Open Questions**:
- Should auto-sync be opt-in (`hub link --sync-templates`) or opt-out?
- How to handle template conflicts when a second broker links with different versions?
- Should there be a `scion templates sync --all` to bulk-sync all grove templates?

---

### Approach C: Git-Integrated Template Discovery for Git Groves

**Concept**: For git groves, the Hub clones/fetches the repository (shallow, sparse) to discover `.scion/templates/` and imports them. This leverages the fact that git groves already have a known remote URL.

**Flow**:
1. On `scion hub grove create <url>`, Hub does a sparse checkout of just `.scion/templates/`
2. Templates are registered at grove scope, with files uploaded to storage
3. A webhook or periodic job re-syncs when the repo's `.scion/` directory changes
4. For branches: each branch-scoped grove gets its own template set

**Pros**:
- Zero CLI interaction needed: git push is the sync trigger
- Templates are version-controlled alongside code (GitOps natural)
- Branch-scoped groves get branch-appropriate templates
- Hub can show template history via git log

**Cons**:
- Requires Hub to have git access (credentials, network)
- Adds operational complexity (git clone, sparse checkout, webhooks)
- Only works for git groves, not linked groves or hub-native groves
- Latency: webhook-based sync is not instant
- Repository may not have `.scion/templates/` committed (externalized groves don't)

**Open Questions**:
- Should the Hub have its own git credential management for this?
- How does this interact with the existing git clone credentials (GITHUB_TOKEN)?
- Is sparse checkout reliable enough across git providers?
- What about private repos where the Hub server doesn't have direct access?

---

### Approach D: Template Declaration in Grove Metadata

**Concept**: Instead of syncing actual template files, groves declare their template requirements in metadata. Templates are referenced by name (or name + version), and the Hub resolves them from a registry.

**Flow**:
1. Grove metadata includes a `templates` field: `[{name: "code-reviewer", source: "grove", version: "latest"}]`
2. The `source` field indicates where to find it: `"grove"` (this grove's storage), `"global"`, or a specific template ID
3. CLI `scion templates declare <name>` adds to grove metadata
4. Actual template content is synced separately (via push/sync)
5. Web UI shows declared templates and their sync status

**Pros**:
- Clean separation of "what templates a grove uses" vs "where they're stored"
- Works for all grove types
- Grove metadata is lightweight (just names/refs)
- Can reference global templates without copying

**Cons**:
- Two-step process (declare + sync) adds friction
- Declaration can drift from actual template availability
- Doesn't solve the fundamental problem of getting template content to the Hub

**Open Questions**:
- Is this just adding metadata without solving the real sync problem?
- Could this be combined with another approach (e.g., A or B)?

---

### Approach E: Hybrid - Broker Inventory + On-Demand Promotion

**Concept**: Combine Approach A's discovery with on-demand sync. Brokers report what templates they have locally; the Hub makes these visible but lazily syncs content only when needed.

**Flow**:
1. Broker reports template inventory in heartbeat (name, hash, harness type)
2. Hub stores inventory per GroveProvider and aggregates a "grove template catalog"
3. Web UI shows available templates with sync status:
   - "Available on broker(s)" (local only)
   - "Synced to Hub" (uploaded and cached)
   - "Inconsistent" (different versions across brokers)
4. When a user selects a template from the web UI for agent creation:
   - If already on Hub: use it directly
   - If local-only: Hub requests the broker to upload it (broker-initiated sync)
5. CLI `scion templates sync` still works for explicit upload
6. Multi-broker conflict: Hub can prompt user to choose which broker's version to promote

**Pros**:
- Lazy: no upfront cost; only syncs what's actually used
- Multi-broker awareness with clear conflict resolution
- Works for linked groves naturally (broker already has the files)
- Progressive: starts with visibility, adds full sync on demand
- Web UI can show a complete picture without requiring all templates to be uploaded

**Cons**:
- First agent creation on a "local-only" template incurs sync delay
- Requires broker to support "upload this template" API (new capability)
- Complexity: multiple states to track and display
- Git groves still need a mechanism to get templates onto a broker first

**Open Questions**:
- What's the API for Hub to request a broker to upload a specific template?
- Should promotion be automatic (first use triggers sync) or manual (user clicks "sync to hub")?
- How to handle the case where the broker that has the template is offline?

---

## 4. Specific Challenges by Grove Type

### 4.1 Linked Groves

**Core challenge**: Multiple brokers may link the same grove but have different local templates.

**Scenarios**:
- Broker A has `code-reviewer` template, Broker B does not
- Both brokers have `code-reviewer` but with different content
- A user pushes a template from Broker A; later Broker B updates its local copy

**Potential resolution strategies**:
1. **First-write-wins**: First broker to sync sets the Hub version; subsequent syncs are no-ops unless forced
2. **Content-hash comparison**: Hub tracks content hash; syncs only if hash differs; conflicts flagged for user resolution
3. **Broker-authoritative**: Each broker's version is independent; Hub stores per-broker variants
4. **Hub-authoritative**: Once synced to Hub, Hub version is pushed to all brokers (reverses flow)

### 4.2 Git Groves

**Core challenge**: Templates live in git but are only materialized after a clone.

**Scenarios**:
- Templates are committed to `.scion/templates/` in the repo
- Templates are in the externalized grove-config dir (not in git, broker-local)
- Mix of both: some templates in repo, some external

**Key insight**: The recent externalization change (d0507b1) means git grove templates now live in `~/.scion/grove-configs/<slug>__<uuid>/.scion/templates/` on the broker, **not** in the repo. This means:
- Git grove templates behave like linked grove templates from the broker's perspective
- The "git-integrated discovery" (Approach C) would only find templates that are committed to the repo, not externalized ones
- Agents running in git groves create their worktree from the repo clone, but template resolution uses the external config dir

**Implication**: For git groves, Approach C alone is insufficient. The broker-inventory approach (A or E) better captures what templates are actually available.

### 4.3 Hub-Native Groves

**Simplest case**: Templates are managed entirely on the Hub. The web UI creates/edits templates at grove scope. No filesystem variance to reconcile.

---

## 5. CLI UX Considerations

### 5.1 Current `scion templates sync` Behavior

Today, `scion templates sync <name>` defaults to grove scope. This is correct behavior and should be preserved. The `--global` flag explicitly overrides to global scope.

### 5.2 Proposed CLI Enhancements

**Discovery hint on link**:
```
$ scion hub link
Grove linked to Hub: my-project (id: abc123)

Found 3 grove templates not yet synced to Hub:
  - code-reviewer
  - security-auditor
  - docs-writer

Run 'scion templates sync --all' to upload them, or sync individually.
```

**Bulk sync**:
```
$ scion templates sync --all
Syncing grove templates to Hub...
  code-reviewer:    uploaded (3 files, 2.1KB)
  security-auditor: uploaded (4 files, 3.4KB)
  docs-writer:      uploaded (3 files, 1.8KB)
3 templates synced to grove scope.
```

**Status command**:
```
$ scion templates status
Grove: my-project (abc123)

Template            Local    Hub      Status
code-reviewer       yes      yes      synced (hash match)
security-auditor    yes      yes      out of date (local newer)
docs-writer         yes      no       local only
default             yes      yes      synced (global)
custom-gemini       no       yes      hub only
```

### 5.3 Web UI Considerations

The web UI needs to:
1. Show templates available for a grove (both Hub-stored and broker-reported)
2. Allow creating agents with grove-scoped templates
3. Provide a way to create/edit grove templates inline
4. Show sync status for templates known to be on brokers but not uploaded
5. Allow promoting a broker-local template to Hub storage

---

## 6. Recommendation

### Phased Approach

**Phase 1: CLI improvements (low effort, high value)**
- Add `scion templates sync --all` for bulk grove template sync
- Add `scion templates status` to show sync state between local and Hub
- Add discovery hint during `scion hub link` (suggest syncing grove templates)
- Ensure `scion templates sync` defaults to grove scope (already does - confirm and document)

**Phase 2: Broker inventory reporting (medium effort)**
- Extend broker heartbeat to include template manifest per grove
- Hub stores per-GroveProvider template inventory
- Web UI shows "available templates" for a grove (aggregated across brokers)
- Mark templates as "local only" or "synced to Hub"

**Phase 3: On-demand promotion (medium effort)**
- Hub can request a broker to upload a specific template
- Web UI "sync to Hub" button for local-only templates
- Auto-promotion option: first agent creation with a local-only template triggers sync
- Conflict detection and resolution for multi-broker groves

**Phase 4: Git-integrated discovery (optional, git groves only)**
- For git groves with in-repo templates, sparse checkout discovery on grove creation
- Webhook-based re-sync on push events
- Only relevant if teams commit templates to the repo (not externalized)

---

## 7. Open Questions

### Architectural
1. **Source of truth**: After a template is synced to the Hub, which version is authoritative - Hub or local filesystem? Should the Hub version be pushed back to brokers?
2. **Sync direction**: Is sync unidirectional (local -> Hub) or bidirectional? If bidirectional, how to handle conflicts?
3. **Template identity**: Should grove-scoped templates with the same name on different brokers be considered the same template? Or should broker provenance be part of the identity?

### UX
4. **Auto-sync appetite**: How much automatic syncing do users expect? Is explicit `sync` preferred, or should linking/heartbeat handle it?
5. **Web-first template creation**: Should the web UI support creating grove templates directly (Hub-native), or is the CLI the primary authoring tool?
6. **Template visibility in agent creation**: When creating an agent from the web UI, should users see local-only templates (that would need sync first), or only Hub-synced templates?

### Technical
7. **Broker upload API**: If the Hub requests a broker to upload a template, what's the auth model? Can any user trigger this, or only grove owners?
8. **Content hash stability**: Are content hashes computed the same way on broker and Hub? (Currently yes - SHA-256 of concatenated file hashes)
9. **Externalized git grove templates**: Since templates are now in the external config dir (not in-repo), what is the expected flow for a brand-new broker linking a git grove? The external config dir starts empty - how do templates get there?

### Multi-Broker
10. **Consistency model**: For linked groves with multiple brokers, is eventual consistency acceptable, or do we need stronger guarantees?
11. **Conflict resolution UI**: What does multi-broker template conflict resolution look like in the web UI? Side-by-side diff? Pick-a-winner?
12. **Offline brokers**: If the only broker with a specific template goes offline, should the Hub have cached the template content proactively?

---

## 8. Related Design Documents

- [Hosted Templates](hosted/hosted-templates.md) - Hub template storage and management
- [Decoupling Templates](decouple-templates.md) - Template/harness separation analysis
- [Git Groves](hosted/git-groves.md) - Git grove architecture
- [Hub Groves](hosted/hub-groves.md) - Hub-native grove design
- [Settings Externalization](../commit d0507b1) - Recent change moving git grove config external
- [Agnostic Template Design](agnostic-template-design.md) - Harness-agnostic template system
