# Attested Apple maintenance windows

These tools do not authorize or activate storage reclamation. The policy tool
does not delete resources; the separate cleanup adapter's explicit `apply`
command requires an already authorized window and inherited exclusive lease.
Neither tool removes `SUSPENDED`, writes `rollout-policy-v1`, resolves lease
records, changes schedules, or stops writers. A feature merge does not enable
global cleanup.

An additive operational implementation is now available at
`tools/apple-build-operations.py`. Unlike the two original v1 tools, it can
reconcile **one explicitly released retained lease record**, represent an
affirmatively retired missing owner, and prepare/install reviewed policy files
**while suspension remains in place**. It never removes `SUSPENDED`. See
[Operational lifecycle (v2)](#operational-lifecycle-v2) below. None of these
capabilities installs itself, authorizes production deletion, or reports disk
recovery from a code change.

## Compatibility and rollout

Build clients use the unchanged v1 namespace and lease protocol from commit
`b1d24c0def3e980a9487d9042420a149298db867`. Vendor these four paths byte-for-byte,
preserving relative layout:

| File | SHA-256 |
| --- | --- |
| `tools/lib/apple_build_lease.py` | `56a54b71f9a642ddd5e10a51128bc59610cbe6e3f9600cc7f6799c3b196bdca2` |
| `tools/lib/apple-build-lease.sh` | `bcb0a687d32ffa740953a687c812515d2516bd0ba90ea824c01c21fc6303c705` |
| `tools/lib/apple_build_lease.rb` | `c7726eaf3470da9dacbacbdf65d86ce353770f47da15882624be4455b7008372` |
| `tools/with-apple-build-lease.sh` | `dc3d932b08b8056704bd37920694952effca451abb155cce1cf8e356752f1b99` |

`tools/apple-maintenance-policy.py protocol` reports the same manifest. New
policy tooling additionally needs `tools/apple-maintenance-policy.py` and
`tools/lib/apple_maintenance_policy.py` from the reviewed policy feature commit.
The two companion files must travel together.

Public build entrypoint:

```bash
tools/with-apple-build-lease.sh app/whole-release-lane -- command arguments
```

The wrapper changes working directory to its bundle's repository root. Use an
absolute command or explicitly change directory *inside* the protected command.
It must wrap the whole lane, including generation, package resolution, signing,
both platform builds, upload/processing/distribution, tagging, and queued gaps.
Wrapping each command separately does not protect the gaps between agent turns.
Python launchers must authenticate and explicitly pass the lease descriptors;
see `tools/run-bounded.py`. Never use `close_fds=False`.

The frozen `rollout-policy-v1` has no Hozz tokens. Adding tokens would break its
exact-match old readers, so this feature does **not** modify that schema. Instead,
enhanced global cleanup must require the companion
`apple-build-interlock-v1/maintenance-window-v1.json` as well as the existing v1
exclusive lease. Every old v1-only or broad cleanup entrypoint must be disabled
or upgraded before any activation. Otherwise an old reader could ignore Hozz,
expiry, owner holds, and target scope. Installing the companion alone does not
close this bypass.

## Operator workflow

1. Inventory every registered root, unregistered clone, raw/manual writer, and
   cleanup entrypoint on this machine. Include current **and** legacy Plozz,
   Mozz, Twozz, and Hozz. Account for active and queued work, not just processes.
2. Obtain actual owner attestations and durable evidence for that exact scope.
   Unwrapped owners may explicitly hold their work for a bounded window; this
   tool does not request such holds or manufacture agreement.
3. Obtain explicit human approval of the complete window package and the exact
   owner-released manifest, including provenance/evidence. Approval must be
   issued during the window, after its owner attestations.
4. Validate, then install the companion using compare-and-swap. This does not
   activate cleanup. Separately approved activation of existing suspension and
   legacy gates still requires their conflicting policy lock.
5. Enhanced cleanup acquires the v1 exclusive lease, checks the companion before
   each destructive step, and also enforces target eligibility, per-path open-use
   checks, process safety checks, age, and release evidence. All remain required.

There are no `--all-clear`, owner-generation, auto-approval, resume, or
stale-record-resolution options.

```bash
# Read-only identity aids. Namespace must already exist.
/usr/bin/python3 tools/apple-maintenance-policy.py host
/usr/bin/python3 tools/apple-maintenance-policy.py worktree-snapshot /physical/repo

# Review a supplied package without installing it.
/usr/bin/python3 tools/apple-maintenance-policy.py validate \
  --request /private/window-request.json --manifest /private/manifest.json

# Future explicitly authorized companion installation, NOT performed by this change.
/usr/bin/python3 tools/apple-maintenance-policy.py install \
  --request /private/window-request.json --manifest /private/manifest.json \
  --expect-current absent
```

For replacement, `--expect-current` is the current companion's raw SHA-256, not
`absent`. Install takes `policy.lock` exclusively and nonblocking **before**
reading/validating its request. Concurrent maintenance or an updater denies the
operation. Publication is mode-0600, fsynced, atomic, and compare-and-swap guarded.
A failure never fabricates a successful approval. A failed fsync may leave the
new companion present; it still does not activate anything. Inspect before retry.

Runtime contract, called by the installed adapter with inherited exclusive FDs:

```bash
/usr/bin/python3 /reviewed/bundle/tools/apple-maintenance-policy.py check \
  --manifest /private/manifest.json --window-id 00000000-0000-0000-0000-000000000000
```

The UUID above is a placeholder, not an approval. Exit 0 returns `window_id`,
`scope_sha256`, `expires_at` (UTC/RFC3339), and `policy_sha256`. Exit 75 refuses.
Missing, stale, malformed, forged, or closed inherited capabilities never fall
back to a new lease. The frozen protocol authenticates the capabilities and
retains the policy's shared lock throughout maintenance. Companion checks repeat
lease/suspension validation after evidence inspection.

Adapters must check the deadline before **every unlink**, not just each root.
Expiry/cancellation stops further deletion without signalling another process.
A partly processed target or quarantine and its journal remain protected for
owner review, not automatic resumption. A filesystem operation already in
progress at the deadline cannot be undone or forcibly interrupted safely.

## Document contract (schema 1)

All paths are absolute physical paths: no symlink aliases. Evidence, manifests,
requests, approvals, attestations, and installed companion files must be owned
by the effective UID and mode 0600 (or stricter). Writer sources may be readable
by others, but not writable by others. JSON duplicate fields and nonfinite
numbers fail closed.

Manifest top-level contract:

```json
{
  "schema": 1,
  "scope": "apple-owner-released-build-outputs-only",
  "targets": ["ADAPTER-VALIDATED EXACT TARGET RECORDS"]
}
```

This illustrative placeholder is **not** a valid adapter deletion target. The
adapter owns the target schema/validator: exact physical path and kind
(`worktree-apple-build` or `xcode-derived-data`), owner worktree/session, root
device/inode, release evidence, timestamps, whole-tree age of at least 72 hours,
and an inode-aware tree digest. This companion checks the nonempty schema/scope
and approval binding, not destructive eligibility. It must never be used alone
as a deletion implementation.

## Exact-manifest cleanup adapter

`tools/apple-build-cleanup.py` and `tools/lib/apple_build_cleanup.py` implement
inventory, non-destructive validation, and separately authorized application.
There is no default deletion, automatic discovery/sweep, installation, owner
record generation, or automatic resume. Only paths named by supplied owner
release records are inspected. Inventory reads metadata, not target file
contents, and writes only stdout unless an explicit new output file is requested.

```bash
/usr/bin/python3 -B tools/apple-build-cleanup.py inventory \
  --release-record /physical/private/owner-release.json \
  --output /physical/private/manifest.json
/usr/bin/python3 -B tools/apple-build-cleanup.py validate \
  --manifest /physical/private/manifest.json
```

`--release-record` can be repeated. All inputs must already exist, be physical
and owned by the effective UID, and meet the existing private evidence rules.
Use the executable's `-B` shebang or the explicit `python3 -B` invocations above:
setting a flag inside Python is too late to prevent interpreter-startup bytecode
cache writes. The CLI also suppresses bytecode writes in its descendants.

Output/journal parents must already exist and be private, outside owner
worktrees, targets, protected resources and the maintenance configuration/lease
namespace. Existing output files are never overwritten. `validate` does not
acquire a lease, install a policy,
write a journal, or delete anything; it is not an authorization check.

Owner release schema (exact keys; this is documentation, not an attestation):

```json
{
  "schema": 1,
  "scope": "apple-owner-released-build-outputs-only",
  "owner": "<responsible owner>",
  "session_id": "<owner session UUID>",
  "released_at": "<UTC time of actual release>",
  "worktree": {"path": "<physical Git worktree>", "device": 1, "inode": 2},
  "evidence": [{"path": "<private durable owner evidence>", "sha256": "<digest>"}],
  "targets": [{
    "kind": "worktree-apple-build",
    "identity": {"path": "<exact released output>", "device": 1, "inode": 3}
  }]
}
```

The owner evidence must establish that these exact outputs are retired,
reconstructable, not active/queued or still-needed warm resources, and contain
no required evidence or protected data. An idle process or an old file does not
establish that. A file's inode must match the owner's release record before
inventory; a later replacement cannot inherit the old owner's release.

Eligibility is deliberately narrower than an entire cache:

- `worktree-apple-build`: a file or directory at/below that owner's `.build`.
  Git-tracked entries are refused, even if they have generated-looking names.
- `xcode-derived-data`: a file or subtree in a direct app root of the canonical
  `~/Library/Developer/Xcode/DerivedData`. That root's existing `info.plist`
  must identify a workspace within the declared owner worktree. Top-level shared
  `.noindex` roots, aliases and alternate cache-root overrides are not supported.
- Regular files must have a recognized compiler-output suffix: `.o`, `.pcm`,
  `.swiftmodule`, `.swiftdoc`, `.swiftsourceinfo`, `.swiftdeps`,
  `.swiftconstvalues`, `.dia`, or `.hmap`. Unknown files, including ambiguous
  `.d`/`.pch` source/header files, are refused rather than guessed disposable.
- Any protected path component or suffix refuses the whole nominated tree:
  source/Git, package stores/checkouts/artifacts, logs/evidence,
  archives/IPAs/dSYMs/xcresults, credentials/signing, SDKs/toolchains, simulators,
  VMs, Trash, and shared dependency stores. Symlinks, hard-linked files, special
  files, cross-filesystem descendants and group/world-writable entries also
  refuse. No automatic carving around exclusions occurs.
- The actual owner release and **every** entry must be at least 72 hours old.
  Entry age uses the youngest of mtime, ctime and birthtime, not the root's
  mtime alone. `--minimum-age-hours` can increase, never reduce, that minimum.
  Nested/overlapping targets and evidence within any target are rejected.

Consequently a normal `.build` containing `SourcePackages`, logs or release
outputs is **not** an eligible target. Its owner can instead release precise
retired compiler files or clean compiler-only subtrees. This adapter does not
solve shared dependency retention, absent-owner/orphan recovery, or release
artifact retention by widening the deletion policy.

When `operational-controls-v2.json` is installed, this older adapter refuses
`apply` and requires an explicitly selected v2 campaign unit. This prevents the
compatible v1 manifest envelope from bypassing operational protections. Its
inventory and validation commands remain available.

### Supported limits and scaling

The adapter deliberately accepts only **256 exact targets** per manifest or
owner release record, at most 256 supplied release records, and **4,096 total
filesystem entries** (including directories) across a manifest. The existing
**4 MiB per-document** limit remains unchanged for manifests, releases and
companion/evidence inputs. These are refusal ceilings, not measured capacity
or a promise to finish within a maintenance window. There are no override or
automatic splitting/batching options; an oversized request must be narrowed
and reviewed rather than silently turned into new approvals.

Manifest target/advertised-entry bounds are checked before tree inspection.
Inventory also enforces the actual aggregate entry budget while traversing,
with bounded directory enumeration rather than materializing an unlimited
directory listing. An incrementally encoded manifest must fit the document
limit before stdout or an output file receives it. An 85,000-file request is
**not supported**, even if bundled into a small number of manifest targets.

Overlap checks use sorted component paths and adjacent-prefix checks; evidence
containment uses a binary-search index and unique reference paths. Each owner
release is parsed/indexed once per inspection, not once per nominated file.
All collected reference bytes are freshly SHA-validated at the inspection
boundary, so a late change cannot hide behind the parsed snapshot. Directory
child lists are indexed once rather than rescanning the entire target's entry
map for every directory.

During apply, each removal revalidates the **current target's** eligibility and
owner identity, rather than running Git and eligibility checks for every other
target. Structural membership/protected-reference checks are reused only while
the manifest is pinned and the exact companion digest is freshly verified.
This is not a cache of mutable authorization: the existing full `policy.check`
still runs at both per-removal guard points, rereading current approval,
attestation, evidence, writer fingerprints, root identities and Git registries.
Every unique target-release/evidence reference is also reread and SHA-checked
at each guard, including references for future or already processed targets.
Thus changed evidence for another target still stops the current operation.

**Residual cost is intentionally explicit.** For `R` removals and `T` targets,
there are `2R + 2` full companion checks (including construction/start) and
`2R + T` full open-file scans. Each companion check still rereads/canonicalizes
the complete bounded manifest and inspects all approved writer/registry
inputs; each guard rereads all unique release/evidence bytes. Therefore runtime
still includes work proportional to removals times those global input sizes.
Only the redundant all-target eligibility/Git traversal, release reparsing,
containment and child-list loops have been removed. This does **not** claim
linear total wall time as the authorization package grows.

Removing that remaining global cost safely would require a separately reviewed
authorization/invalidation design with equivalent detection of mutable
evidence, registry and open-use changes. Neither a metadata-only freshness
guess, a timed cache, nor omission of global checks is adopted here. Keep
manifests small and preserve per-unlink expiry/partial-journal behavior;
substantial landscape-scale reclamation still needs separate design and
performance work, as does historical-owner support for deleted worktrees.

Each manifest target has exactly `kind`, `path`, `owner`, `session_id`,
`worktree`, `released_at`, `release_record`, `release_evidence`, `observed_at`,
`retention`, `root`, and `tree`. `release_record` and `release_evidence` are
private SHA-bound references; worktree identity is path/device/inode.
`retention` contains `minimum_seconds` and `youngest_entry_at`.
`root` contains device/inode.
`tree` contains `sha256`, `entries`, `allocated_bytes`, and `apparent_bytes`.
Its digest binds sorted relative entries, type, UID/mode, device/inode, link
count, size/blocks, and modification/change/birth timestamps. These are metadata
identities, not content hashes. Renames, edits, additions and replacements
invalidate the approved inventory.

Sizes are sums of `st_size` and `st_blocks * 512`, **not** uniquely owned APFS
extents or a promise of physical free space. APFS clones and snapshots can
retain blocks after unlink. Neither inventory nor committing this tool reclaims
bytes; a future authorized cleanup must report actual filesystem free-space
changes separately, with concurrent-writer attribution limits.

Only in a later, separately approved and fully covered window:

```bash
/reviewed/bundle/tools/with-apple-build-lease.sh --exclusive cleanup/exact-manifest -- \
  /usr/bin/python3 -B /reviewed/bundle/tools/apple-build-cleanup.py apply \
  --manifest /physical/private/manifest.json \
  --window-id 00000000-0000-0000-0000-000000000000 \
  --journal /physical/private/new-window-journal.jsonl
```

The zero UUID is illustrative; a real call must use its approved window ID.

The global-cleanup cohort must fingerprint the executing CLI/module,
`apple_maintenance_policy.py`, `apple-build-guard.sh`, and all four frozen lease
files in that same reviewed bundle. The target owner worktrees must appear in
the approved app cohorts/registries. These extra checks prevent merely
fingerprinting an unrelated cleanup script. They do not automatically discover
unregistered/raw/manual writers.

Apply repeats the existing full companion/lease validation, exact registry
inspection, owner evidence hashes, bundle/coverage checks and existing build
process defense before each removal. New unresolved records, changed evidence,
missing inherited capabilities, an unlocked coordination file, suspension,
window drift/expiry or backward clock movement stop it. Open paths **and**
device/inode aliases are refreshed during each step; incomplete `lsof` output
refuses. Only its own known directory descriptors are excluded from that scan.
Elapsed-time and UTC deadlines are checked immediately before every
descriptor-relative unlink/rmdir. Directories are opened without following
links and their ancestor identities are rechecked; arbitrary path-recursive
deletion is never used.

A private, create-new JSONL journal is outside all targets. It contains the
manifest and authorization digests, a complete manifest snapshot, and durable
per-entry intent/outcome records. Intent is fsynced (including `F_FULLFSYNC` on
macOS) before unlink; parent directories and outcomes are synced afterward.
Short writes are completed; write/fsync failures are surfaced. A crash can leave
an intent without an outcome, which means **possibly removed**, not untouched.
SIGINT/SIGHUP/SIGTERM stop subsequent removals and preserve a stopped record when
the journal remains writable. The wrapper retains failed lease evidence.
There is no rollback, automatic retry/resume, or automatic journal deletion.
Partial trees and journals require owner review and a newly approved manifest.

This is a cooperative, same-UID operational boundary, not protection against a
malicious process that ignores the approved hold. No portable pathname unlink
can atomically assert an inode while excluding arbitrary uncooperative writers.
Descriptor-relative traversal and repeated checks detect observed drift; the
whole-lane interlock and verified writer coverage are mandatory. Per-entry
inspection intentionally prioritizes refusal over throughput: use bounded
manifests, not a two-hour promise to drain an entire machine.

### Remaining rollout gates

Keep production suspension, both broad schedules, installed scripts, warm
roots, leases and evidence unchanged until separately authorized:

1. Review/land this adapter and install an exact fingerprinted bundle outside
   shipping. Retire or enhance **every** machine-wide cleanup entrypoint; the
   repository legacy scripts' refusal does not update installed copies.
2. Inventory all writers, including unattended update jobs and raw Xcode/MCP
   paths. Complete whole-lane wrapping or obtain actual bounded owner holds.
   Account for active and queued work and all current/legacy cohorts.
3. Investigate retained lease records with their actual owners and durable lane
   evidence. Any exact owner-approved record resolution is a separate operation;
   this adapter neither performs it nor treats records as stale.
4. Obtain genuine exact-target releases, wait the full retention period, inspect
   the inventory, and obtain cohort attestations followed by human approval of
   that exact manifest/window. Install its companion with the existing CAS tool.
5. Only a separately approved policy-lock activation may open the existing
   suspension/rollout gates. A first bounded cleanup requires the exclusive
   lease, complete runtime checks and retained journal. Recurrence requires new
   eligible owner releases and approved windows, not an age-based unattended
   sweep or blanket standing deletion permission.

## Canonical digests and window documents

The manifest digest includes **all** parsed fields, including provenance and
release evidence, using:

```python
hashlib.sha256(json.dumps(
    manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False
).encode("utf-8")).hexdigest()
```

The same canonical encoding is used for `scope_sha256`. Other document
references use SHA-256 of their exact file bytes. A reference is exactly
`{"path": "/physical/private/file", "sha256": "<64 lowercase hex>"}`.

Window request fields (exact, no unknown fields):

| Field | Value |
| --- | --- |
| `schema` | Integer `1` |
| `host` | Exact `host` command result: effective UID, physical home/namespace identities, coordination device/inode |
| `window` | `id` UUID, UTC `not_before`/`expires_at`, exact `scope` above, canonical `manifest_sha256` |
| `cohorts` | One `{"name": "...", "roots": [...]}` for each required cohort |
| `registries` | `{"app": "plozz\|mozz\|twozz\|hozz", "root": "/physical/repo", "sha256": "..."}` entries |
| `approval` | Private SHA-bound reference to a supplied human approval document |

The window must be open now, positive, and no longer than two hours. Each root
is `{"identity": {"path": "...", "device": 1, "inode": 2}, "writers": [...]}`.
`writers` is a nonempty list of path/SHA-256 references covering the actual
entrypoints reviewed by its owner. Paths must be inside that root. These are
not proof that every entrypoint was discovered; owner review must provide that.

Required cohorts (exact set):

```text
global-cleanup-entrypoints
manual-xcode-writers-disabled-or-wrapped
mozz-current-writers
mozz-legacy-writers
plozz-current-writers
plozz-legacy-writers
twozz-current-writers
twozz-legacy-writers
hozz-current-writers
hozz-legacy-writers
```

Registry digests cover the exact bytes of
`git -C ROOT worktree list --porcelain -z`. The read-only `worktree-snapshot`
command supplies them. Every registered root must appear in that app's combined
current/legacy inventories; every declared app root must be registered. New
roots, removed roots, or HEAD/branch changes require renewed review and approval.
Multiple repositories/clones may be listed per app. Unregistered/unrecognized
repositories are **not** magically discovered: exhaustive host inventory remains
an explicit owner/human responsibility, including raw writers outside Git.

Compute `scope_sha256` over the request with just `approval` omitted. Each
supplied owner attestation has exactly:

```json
{
  "schema": 1,
  "scope_sha256": "<canonical scope digest>",
  "cohort": "<one required cohort>",
  "owner": "<real responsible owner>",
  "session_id": "<actual owner session UUID>",
  "attested_at": "<UTC within the window>",
  "disposition": "<wrapped|held|disabled|absent|enhanced>",
  "active_queued": "<none|protected-by-full-lane-shared-leases>",
  "evidence": [{"path": "<actual durable evidence>", "sha256": "<exact digest>"}]
}
```

`wrapped` requires the frozen four protocol files in every root, in addition to
owner-reviewed writer fingerprints. It permits active/queued work only when
protected by a **whole-lane** shared lease. `held` and `disabled` require explicit
owner evidence covering the entire approved window and no active/queued work;
neither can be inferred from an empty `ps`. `absent` is allowed only for an empty
app cohort, with owner evidence, never for manual/global writers. `enhanced` is
required only for the cleanup cohort: its evidence must confirm every path uses
the companion or has been disabled. A self-labelled v1-only wrapper is rejected.

The human approval document has exactly:

```json
{
  "schema": 1,
  "scope_sha256": "<same exact scope digest>",
  "approved_by": "<actual human approver>",
  "approved_at": "<UTC within window, after every owner attestation>",
  "evidence": {"path": "<actual approval evidence>", "sha256": "<exact digest>"},
  "attestations": ["ONE SHA-BOUND DOCUMENT REFERENCE PER COHORT"]
}
```

Again, placeholders are not real approvals. SHA-bound files prove consistency
with the reviewed package; they do not authenticate a human against another
process running as the same UID. The responsible operator must verify identity,
authority, inventory completeness, and the meaning of approval evidence. A
script cannot police a manual/raw writer that ignores an agreed hold. If those
conditions cannot be established, cleanup remains blocked.

## Evidence retention and tests

Install never inspects away, clears, or resolves failed lease records. Runtime
cleanup still refuses every unresolved record through v1. Owner attestation for
a finished failed lane must name the exact record ID and durable lane evidence;
it is input to a **later separately authorized** resolution, not permission for
this tool to delete it. Archives, IPAs, dSYMs, xcresults, session/release evidence,
Git/worktrees/source, shared dependencies, SDKs, simulators, VMs, Cargo/npm
resources, and Trash remain ineligible regardless of window approval.

Fixture-only validation, no app build:

```bash
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest \
  tools.tests.test_apple_build_cleanup tools.tests.test_apple_maintenance_policy
```

Tests create synthetic attestations exclusively under private temporary HOME
fixtures; no production owner assertions are generated. They cover missing
Hozz, scope/manifest/evidence/identity changes, expiry, raw queued owners,
wrapped-client bytes, registered-root snapshots, exclusive policy-update races,
compare-and-swap, real inherited exclusive checking, suspension, orphan evidence
retention, fixture confinement, and malformed JSON. Cleanup fixtures additionally
exercise no-follow traversal, changed ancestors/files, refreshed open-inode
checks, late evidence/lease drift, unlocked capabilities, protected source and
dependency data, per-removal expiry, short writes, sync/journal failures,
interruptions, partial-progress evidence, and non-activating legacy refusals.

## Operational lifecycle (v2)

`tools/apple-build-operations.py` with `tools/lib/apple_build_operations.py`
adds the missing administrative and missing-owner operations. It reuses the
bounded compiler-only scanner, descriptor-relative remover, durable journal,
full per-unlink v1 authentication, process/open-inode guards, and companion
validator. The four frozen protocol files and their hashes above are unchanged.
There is **no ignore list, force mode, PID-based auto-release, automatic
partitioning, sweep, automatic resume, installation side effect, or suspension
removal command**.

The v1 companion's manifest **envelope** remains exactly
`{"schema":1,"scope":"apple-owner-released-build-outputs-only","targets":[...]}`.
Existing-owner targets keep the complete original target schema and real
existing-worktree release requirement. A retired-owner target adds exactly
`"ownership":"retired-v2"`; its `release_record` points to a reviewed schema-2
retirement, and its `worktree` is the original historical identity, not a
newly created or adopted directory. The old adapter rejects that extra field.
Once operational controls are installed, the updated old adapter also rejects
all `apply` calls, including otherwise valid existing-owner units.

### Exact missing-owner provenance

Operators supply, not generate through this tool, these private documents.
All evidence references are `{path, sha256}` binding original **raw bytes**.
Approvals are affirmative human review, not cryptographic identity proof; a
same-UID agent fabricating JSON is not an approval. Review-only inventories,
session metadata, similar slugs, old process observations, missing directories,
or old `info.plist` files alone never constitute retirement.

The historical-owner document has exactly:

| Field | Required meaning |
| --- | --- |
| `schema` | Integer `2` |
| `owner`, `session_id` | Original responsible lane owner and exact session UUID |
| `worktree` | Original `{path, device, inode}`; path must currently be absent |
| `repository` | Existing physical Git anchor `{path, device, inode}`, covered by the window's writer inventory |
| `common_git` | Original repository's exact Git common-directory identity; must still match the anchor |
| `head` | Original full 40-character commit; must still exist as a commit in that repository |
| `workspace` | Exact original absolute workspace path below the original worktree |
| `recorded_at` | UTC time of the historical observation, not a fabricated backdate |
| `registry` | Preserved historical `git worktree list --porcelain -z` bytes; must contain that exact worktree/HEAD and repository anchor |
| `evidence` | Nonempty durable evidence references establishing the original owner and identity |

The current Git registry is inspected again: a missing-but-still-registered
worktree is **not** retired. A recreated path, symlink alias, different
repository/common directory, missing historical commit, or ambiguous registry
refuses. Names/slugs are never matched. If trustworthy historical registry and
identity evidence were not preserved, this interface refuses; do not reconstruct
an imaginary registry to satisfy it.

A retirement has exactly `schema:2`, `scope`, `historical_owner` (reference),
`retired_at`, `targets`, `evidence`, and `approval`. Actual retirement must follow
the historical observation and be at least **72 hours old**. That waiting period
starts at the real retirement, not at the age of the cache or last successful
retry. Each nominated target has exactly:

```json
{
  "kind": "xcode-derived-data",
  "identity": {"path": "<exact compiler root/file>", "device": 1, "inode": 2},
  "store": {"path": "<direct app DerivedData store>", "device": 1, "inode": 3},
  "info_sha256": "<raw SHA-256 of that store's info.plist>"
}
```

Only exact compiler files/subtrees **below** that non-shared store qualify.
`info.plist` must still have the identical bytes and exact historical
`WorkspacePath`. No `.build` under a missing owner, whole DerivedData store,
`SourcePackages`, dependency, log/result, unknown file, or protected artifact
becomes eligible. Every entry's existing age, link, ownership, permissions,
filesystem and suffix checks remain mandatory.

Every schema-2 approval has exactly:

```json
{
  "schema": 2,
  "purpose": "<operation-specific purpose below>",
  "payload_sha256": "<SHA-256 of canonical payload without its approval field>",
  "approved_by": "<actual affirmative human approver>",
  "approved_at": "<UTC actual approval time>",
  "evidence": [{"path": "<private affirmative evidence>", "sha256": "<raw digest>"}]
}
```

Purposes are `retire-missing-owner`, `bounded-campaign`, `resolve-exact-record`,
`operational-rollout`, and `install-suspended-rollout`. The install approval
binds the entire staged document, which has no embedded approval field.
Canonical JSON is the existing `apple_maintenance_policy.canonical` encoding.
Changing targets, provenance, scope, bytes, or approval invalidates that review.

### Exact retained-record reconciliation

```bash
python3 -B tools/apple-build-operations.py resolve-record \
  --request /private/exact-resolution.json --journal /private/resolution.jsonl
```

This is a **separately authorized administrative mutation**, not an inventory.
It never runs automatically and does not infer release from a dead PID. The
request has exactly `schema:2`, `host` (existing `host` command output),
`record` (exact live record path/raw digest), `record_identity` (its exact
`{path,device,inode}`), `registry_sha256`, `not_before`, `expires_at`,
`owner_release`, and `approval`. The window is positive, current,
and at most two hours. `registry_sha256` is
`apple_build_operations.registry_digest()`: canonical sorted live-record
`{path,sha256}` observations. Observing it is not permission to resolve anything.

The `owner_release` reference names a document with exactly `schema:2`,
`record_sha256`, the original `owner`, `cwd`, `request_pid`, `request_start`,
`released_at`, `active_queued:"none"`,
`disposition:"owner-relinquished-entire-lane"`, and nonempty `evidence`.
It must establish actual affirmative relinquishment of the **entire lane**,
including queued gaps and descendants. Human blanket cleanup permission, an
idle session, or a later successful retry cannot supply this assertion.
An administrator cannot use this interface to end an owner's active lane.

The resolver requires the existing private `SUSPENDED` marker and acquires
`policy.lock`, `coordination.lock`, then `registry.lock` exclusively,
nonblocking, with inode checks. Old clients/finalizers use those same locks.
It verifies the exact registry snapshot, original record bytes/inode and lock
identity, original requester absence in a successful process-identity census,
no open original proof inode, and no Apple build activity. **Any present
requester PID, including a reused PID with a different start, refuses.**
Unknown process/open-file results refuse. Evidence, records, deadlines and
locks are rechecked after slow probes and journal synchronization.

Before unlinking the one live record, it durably preserves its exact original
bytes, request, owner release, approval, and their evidence under
`apple-build-interlock-v1/resolutions-v2/<lease-id>/`. Then it records intent,
revalidates, unlinks only that record, fsyncs the registry directory, and records
the outcome. Other records are unchanged and continue to block v1 maintenance.
Archives are outside `leases/`; readers do not skip or reinterpret any retained
record. No record is rewritten to fabricate `release_requested`.

On the first reconciliation, the interlock directory is fsynced after creating
`resolutions-v2`, before any live-record unlink. Syncing only the child archive
would not durably publish the new archive root's directory entry.

An archive-write failure retains the live record. Cancellation after archive
creation retains both archive and live record. A post-unlink fsync failure may
leave the live record absent; the original and durable intent remain and the
journal reports `removed:true` with `stopped`, not success. Existing archive or
journal paths refuse reuse. Review the exact partial transaction separately;
there is no bulk-clear or automatic recovery/resumption command.

### Explicit bounded campaigns

```bash
python3 -B tools/apple-build-operations.py inventory-unit \
  --retirement /private/retirement.json \
  --release-record /private/existing-owner-release.json \
  --output /private/unit-01.json

python3 -B tools/apple-build-operations.py validate-unit \
  --manifest /private/unit-01.json
python3 -B tools/apple-build-operations.py validate-campaign \
  --campaign /private/campaign.json --unit-id '<explicit-unit-UUID>'
```

The release and retirement switches are repeatable; supply whichever provenance
types the selected unit actually needs. No directory discovery or automatic
carving occurs. A campaign has exactly `schema:2`, `units`, `reviewed_at`, and
`approval`. Each `units` entry is exactly
`{"id":"<UUID>","manifest":{"path":"<unit manifest>","sha256":"<raw digest>"}}`.
The human reviews that exact list. Duplicate IDs, duplicate/overlapping targets
across units, changed manifests, protected evidence overlaps, and an unlisted
selected unit refuse.

Isolation and freshness cover the **schema-known reference closure of every
unit**, including nonselected units' release records, retirements, historical
owner/registry evidence and nested approval evidence. No unit may delete another
unit's authority. These references are rechecked per unlink without requiring
already completed units' deleted targets to exist.

Each execution unit retains **256 targets, 4,096 total entries, and 4 MiB per
document**. A campaign contains at most **64 explicitly reviewed units**; it is
an approval index, not an enlarged execution manifest. Every invocation selects
one unit, requires its own exact approved window/controls, and stops at that
unit's completion or first failure. It never advances to the next unit. Prior
completed target absence does not invalidate the campaign's immutable manifest
references, but a partial unit cannot be replayed against its original tree
digest. Its remaining contents require a new review.

The per-campaign representational ceiling is 16,384 nominated roots and 262,144
entries, not guaranteed deletion capacity. A landscape with 155,017 individually
nominated files needs more than one separately reviewed campaign; compiler-only
subtrees can use fewer roots when the scanner proves every descendant eligible.
Mixed stores cannot be called disposable to save approvals. No ceilings were
raised in the adapter and no approvals are automatically split.

### Reviewed rollout preparation and suspended installation

```bash
python3 -B tools/apple-build-operations.py stage-rollout \
  --window /private/window-request.json --manifest /private/unit-01.json \
  --controls /private/controls.json --output /private/staged-rollout.json \
  --journal /private/staging.jsonl

python3 -B tools/apple-build-operations.py install-prepared \
  --stage /private/staged-rollout.json --approval /private/install-approval.json \
  --journal /private/installation.jsonl
```

The window remains the complete v1 companion package described above, including
Hozz and all current/legacy/manual cohorts, exact current registries, writer
fingerprints, owner attestations and human approval. All owner attestations
must report no active/queued lane during preparation or installation. A held
kernel lock or **any retained record** refuses these operations. The commands
do not edit writer code, stop writers, install executable bundles, update
schedules, or obtain owner agreement on the operator's behalf.

Controls have exactly `schema:2`, `window_sha256` (canonical package digest),
`manifest_sha256` (canonical unit digest), `protected_roots` (nonempty exact
identity list), `entrypoints`, `coverage_evidence`, `reviewed_at`, and `approval`.
The protected list must cover actual active/pending/unknown work and all linked
global outputs; ancestor/descendant overlap with a nominated target refuses.
Coverage evidence must affirm completeness of old/current/legacy/scheduled/raw
cleanup routes and full-lane writer protection, not just an idle process scan.

The approved global cohort must fingerprint every path in
`apple_build_operations.OPERATIONS_FILES` in the **actual executing bundle**,
plus every additional cleanup route. This includes both new Python files, the
scanner/remover, process guard, companion library and all four frozen clients.
Every non-library global route must occur exactly once in `entrypoints`, with
`path`, `sha256`, and `enforcement`. The only `operational-v2` entrypoint is the
exact fingerprinted `tools/apple-build-operations.py`. Other cleanup routes
must have `enforcement:"disabled"` and these exact refusal-stub bytes:

```sh
#!/bin/sh
# Retired cleanup entrypoint; reviewed v2 rollout required.
exit 75
```

An executable permission change, an unchecked checkbox, or an old v1-only
script is not accepted as disabling a route. Source fingerprints cannot prove
that an omitted manual command or schedule does not exist; affirmative complete
owner/human census evidence remains necessary. Installation of these files alone
cannot police an uncooperative same-user writer. When that prerequisite cannot
be established, leave cleanup suspended.

Preparation takes all three conflicting locks and writes an inactive staged
document containing host identity, raw input references, suspension reference,
and exact expected current policy-file digests (or `absent`). Installation
requires a **new explicit install approval** for that stage and repeats current
validation under the same locks. It journals originals and publication intent,
then publishes the companion, operational controls, and the exact original
frozen `rollout-policy-v1` token list with durable writes and compare-and-swap
checks. The existing suspension marker is never removed or rewritten: it is the
transaction's safety barrier across partial multi-file publication.

The install approval's own evidence references are revalidated after slow
operations, immediately before each replacement and at completion. An unchanged
approval JSON file cannot hide withdrawal of installation-only evidence.

Results are `prepared-inactive` or `installed-suspended`, always with
`activation:"not-authorized"`, never “ready.” Missing inputs, stale evidence,
unknown coverage, changed registries or target bytes, held locks, active/queued
shipping, and partial writes/fsyncs refuse. A failed install can leave some
policies published or an exact `.operations-*` candidate retained. The journal
names published files and preserves originals; suspension remains. Do not erase
that evidence or blindly retry a partially published stage.

**Production activation still requires separate reviewed authorization** for
the installed writer/route rollout and suspension transition under the
conflicting policy lock, outside shipping. No command in this implementation
performs that transition. The tests activate only their private temporary HOME
under that lock, then acquire a real frozen-v1 exclusive lane.

Once separately authorized and active, the operator explicitly acquires a v1
exclusive lease through the frozen shell client and invokes only:

```bash
python3 -B /reviewed/bundle/tools/apple-build-operations.py apply-unit \
  --campaign /private/campaign.json --unit-id '<explicit-unit-UUID>' \
  --window-id '<approved-window-UUID>' --journal /private/deletion.jsonl
```

The command does not acquire a substitute lease when inherited descriptors are
missing. Each unlink rechecks the actual inherited capabilities, exclusive
kernel lock, single exact lease record, suspension, companion, writer and Git
registry fingerprints, operational controls, campaign, evidence, all missing
owner paths, current target provenance, target identity, open paths/inodes and
deadline. Slow probes/fsyncs are followed by another check. Monotonic and UTC
deadlines detect expiration/backward clock movement. A durable intent precedes
every unlink; partial counts, failure and cancellation are recorded. Only the
lane's actual owner can end its lease.

### Operational fixture validation and measured scale

```bash
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest \
  tools.tests.test_apple_build_operations \
  tools.tests.test_apple_build_cleanup \
  tools.tests.test_apple_maintenance_policy
PYTHONDONTWRITEBYTECODE=1 bash tools/tests/test-apple-build-interlock.sh
```

No Xcode/Swift build, package resolve, installation or device deployment is
needed for these maintenance-only changes. Fixtures use actual temporary Git
repositories and historical registered worktrees, then really remove the owned
synthetic worktrees. They do not create/adopt fake replacement owners. All
approvals/retirements are labeled synthetic. File ages are shifted **in test
memory only** because ctime/birthtime cannot legitimately be backdated; there
is no operational flag for lowering retention. Host-wide build activity and
lsof observations are supplied by fixture seams, never used as fake production
success. Other checks, real kernel locks, frozen lease authentication,
publications, journals, fsyncs and unlinks run normally.

The scale fixture nominates **328 tiny compiler files in 41 stores**, preserves
one log per store, and executes **three independently approved units/windows**.
It removes exactly **369 entries** (files plus compiler-only directories), with
**785 real companion checks**. Observed runs took **87.081–103.103 seconds**,
excluding fixture construction. This deliberately measures the actual per-unlink
validation path rather than replacing the guard with a no-op.

It is not a 155,017-file throughput claim. The existing repeated full evidence,
writer/registry, process and open-use checks remain expensive. Production lsof
and process census costs are not represented in that elapsed time and can
dominate. Campaign indexing bounds execution and makes exact review units
operational; it does not remove per-unlink safety costs or promise completion
inside a two-hour window. Start with a separately approved small unit and stop
on its deadline; never infer authorization for another unit from elapsed time,
free-space pressure, or an incomplete previous attempt.
