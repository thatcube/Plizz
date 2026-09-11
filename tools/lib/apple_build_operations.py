#!/usr/bin/env python3
"""Additive v2 operations; frozen v1 leases are never reinterpreted or ignored.

Evidence is an explicitly reviewed same-UID administrative trust boundary, not
a signature service. No command generates approvals or removes SUSPENDED.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import time
from typing import Any, Callable

import apple_build_cleanup as cleanup
import apple_build_lease as lease
import apple_maintenance_policy as policy

VERSION = 2
CONTROLS_NAME = cleanup.OPERATIONAL_CONTROLS_NAME
MAX_UNITS = 64
DISABLED_ENTRYPOINT = b"#!/bin/sh\n# Retired cleanup entrypoint; reviewed v2 rollout required.\nexit 75\n"
HISTORY_KEYS = {
    "schema", "owner", "session_id", "worktree", "repository", "common_git",
    "head", "workspace", "recorded_at", "registry", "evidence",
}
RETIREMENT_KEYS = {
    "schema", "scope", "historical_owner", "retired_at", "targets", "evidence", "approval",
}
OPERATIONS_FILES = (
    *policy.PROTOCOL_FILES, "tools/apple-build-cleanup.py",
    "tools/lib/apple_build_cleanup.py", "tools/lib/apple_maintenance_policy.py",
    "tools/lib/apple-build-guard.sh", "tools/apple-build-operations.py",
    "tools/lib/apple_build_operations.py",
)


def v2(value: Any) -> None:
    if type(value) is not int or value != VERSION:
        lease.fail("expected operational schema 2")


def missing_path(value: Any) -> Path:
    """Validate original physical spelling without inventing an existing owner."""
    path = Path(policy.text(value, "original path"))
    if not path.is_absolute() or path != path.resolve(strict=False):
        lease.fail("original path has an alias or nonphysical spelling")
    if os.environ.get("APPLE_BUILD_INTERLOCK_TESTING") == "1":
        home = lease.paths()["home"]
        if home not in path.parents:
            lease.fail("original path escapes fixture HOME")
    return path


def absent(path: Path) -> None:
    missing_path(str(path))
    try:
        path.lstat()
    except FileNotFoundError:
        return
    lease.fail(f"retired owner path exists again: {path}")


def historical_identity(value: Any) -> Path:
    policy.exact(value, cleanup.IDENTITY_KEYS, "historical identity")
    cleanup.integer(value["device"], "historical device")
    cleanup.integer(value["inode"], "historical inode", minimum=1)
    return missing_path(value["path"])


def refs(values: Any) -> None:
    if not isinstance(values, list) or not values:
        lease.fail("affirmative durable evidence is required")
    for value in values:
        policy.reference(value)


def evidence_outside(value: Any, index: cleanup.TargetIndex) -> None:
    if isinstance(value, dict):
        if {"path", "sha256"} <= set(value) and index.contains(Path(value["path"])):
            lease.fail("operational evidence or writer is inside cleanup scope")
        for child in value.values():
            evidence_outside(child, index)
    elif isinstance(value, list):
        for child in value:
            evidence_outside(child, index)


def artifact_outside(path: Path, manifest: dict, controls: dict | None = None) -> None:
    cleanup.secure_parent(path)
    for target in manifest["targets"]:
        if cleanup.path_within(path, Path(target["path"])) or cleanup.path_within(
            path, Path(target["worktree"]["path"])
        ):
            lease.fail("operational artifact overlaps a nominated owner or target")
    for root in (controls or {}).get("protected_roots", []):
        if cleanup.path_within(path, Path(root["path"])):
            lease.fail("operational artifact is inside a protected scope")


def approved(payload: dict, reference: dict, *, purpose: str, earliest: dt.datetime,
             now: dt.datetime) -> dict:
    approval = policy.document(policy.reference(reference))
    policy.exact(approval, {
        "schema", "purpose", "payload_sha256", "approved_by", "approved_at", "evidence",
    }, "operational approval")
    v2(approval["schema"])
    if approval["purpose"] != purpose or approval["payload_sha256"] != policy.digest(policy.canonical(payload)):
        lease.fail("approval does not bind this exact operation")
    policy.text(approval["approved_by"], "affirmative approver")
    if not earliest <= policy.timestamp(approval["approved_at"]) <= now:
        lease.fail("approval predates evidence or is in the future")
    refs(approval["evidence"])
    return approval


def git(root: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        capture_output=True, timeout=30, check=False,
    )
    if result.returncode:
        lease.fail(f"cannot verify historical Git evidence at {root}: {result.stderr.decode(errors='replace')}")
    return result.stdout


def historical_owner(reference: dict, *, now: dt.datetime) -> dict:
    history = policy.document(policy.reference(reference))
    policy.exact(history, HISTORY_KEYS, "historical owner")
    v2(history["schema"])
    lease.validate_owner(history["owner"])
    lease.validate_uuid(history["session_id"], "original owner session")
    owner = historical_identity(history["worktree"])
    absent(owner)
    anchor = Path(cleanup.validate_identity(history["repository"], "repository anchor")["path"])
    common = cleanup.validate_identity(history["common_git"], "historical Git common directory")
    actual = git(anchor, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip()
    if actual != common["path"]:
        lease.fail("historical owner belongs to a different repository")
    head = policy.text(history["head"], "historical HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        lease.fail("historical HEAD must be an exact Git commit")
    git(anchor, "cat-file", "-e", head + "^{commit}")
    workspace = missing_path(history["workspace"])
    if owner not in workspace.parents:
        lease.fail("historical workspace must be within the exact original owner")
    if policy.timestamp(history["recorded_at"]) > now:
        lease.fail("historical observation is in the future")
    registry = policy.reference(history["registry"]).decode()
    matching = [
        entry.split("\0") for entry in registry.split("\0\0")
        if entry.startswith("worktree " + str(owner) + "\0")
    ]
    if len(matching) != 1 or "HEAD " + head not in matching[0]:
        lease.fail("historical registry does not bind the exact worktree path and HEAD")
    if not any(entry.startswith("worktree " + str(anchor) + "\0") for entry in registry.split("\0\0")):
        lease.fail("historical registry lacks its exact repository anchor")
    _, registered = policy.worktree_snapshot(anchor)
    if str(owner) in registered:
        lease.fail("retired owner is still registered")
    refs(history["evidence"])
    return history


def retirement(reference: dict, *, now: dt.datetime, check_targets: bool = True) -> tuple[dict, dict]:
    record = policy.document(policy.reference(reference))
    policy.exact(record, RETIREMENT_KEYS, "retirement")
    v2(record["schema"])
    if record["scope"] != cleanup.SCOPE:
        lease.fail("retirement has an unsupported scope")
    history = historical_owner(record["historical_owner"], now=now)
    retired = policy.timestamp(record["retired_at"])
    if not policy.timestamp(history["recorded_at"]) <= retired <= now - dt.timedelta(
        seconds=cleanup.MINIMUM_RETENTION_SECONDS
    ):
        lease.fail("actual retirement must follow historical evidence and complete 72h retention")
    refs(record["evidence"])
    approved(
        {k: v for k, v in record.items() if k != "approval"}, record["approval"],
        purpose="retire-missing-owner", earliest=retired, now=now,
    )
    targets = record["targets"]
    if not isinstance(targets, list) or not targets:
        lease.fail("retirement requires exact nominated targets")
    cleanup.require_target_limit(len(targets))
    roots = []
    for target in targets:
        policy.exact(target, {"kind", "identity", "store", "info_sha256"}, "retired target")
        if target["kind"] != "xcode-derived-data":
            lease.fail("missing owners can retire only attributed global DerivedData compiler outputs")
        path = historical_identity(target["identity"])
        policy.sha(target["info_sha256"])
        historical_identity(target["store"])
        roots.append(path)
        if check_targets:
            cleanup.validate_identity(target["identity"], "retired target identity")
            retired_location(target, history)
    cleanup.TargetIndex(roots)
    return record, history


def retired_location(target: dict, history: dict) -> None:
    path = policy.physical_path(target["identity"]["path"])
    cleanup.validate_entry_name(path)
    store = Path(cleanup.validate_identity(target["store"], "DerivedData store")["path"])
    root = cleanup.derived_data_root()
    if store.parent != root or store.name.endswith(".noindex") or store not in path.parents:
        lease.fail("retired target must be below its exact non-shared DerivedData store")
    if path.lstat().st_dev != target["store"]["device"]:
        lease.fail("retired target crosses its attributed store filesystem")
    data = policy.read_bytes(store / "info.plist", private=False)
    if policy.digest(data) != target["info_sha256"]:
        lease.fail("DerivedData attribution changed")
    info = plistlib.loads(data)
    if not isinstance(info, dict) or info.get("WorkspacePath") != history["workspace"]:
        lease.fail("DerivedData attribution does not match the exact historical workspace")


def collect_references(reference: dict, index: cleanup.ReferenceIndex, seen: set[str] | None = None) -> None:
    """Only schema-known JSON documents recurse; opaque affirmative evidence does not."""
    seen = seen if seen is not None else set()
    index.add(reference, "operational evidence")
    if reference["path"] in seen:
        return
    seen.add(reference["path"])
    value = policy.document(policy.reference(reference))
    if set(value) == RETIREMENT_KEYS:
        collect_references(value["historical_owner"], index, seen)
        collect_references(value["approval"], index, seen)
    if set(value) == HISTORY_KEYS:
        index.add(value["registry"], "historical registry")
    for evidence in value.get("evidence", []):
        index.add(evidence, "affirmative evidence")


def inventory(releases: list[Path], retirements: list[Path], *, now: dt.datetime) -> dict:
    cleanup.require_target_limit(len(releases) + len(retirements))
    targets = cleanup.inventory(releases, current_time=now)["targets"] if releases else []
    for path in retirements:
        reference = cleanup.reference_for(path)
        record, history = retirement(reference, now=now)
        for item in record["targets"]:
            cleanup.require_target_limit(len(targets) + 1)
            targets.append({
                "kind": item["kind"], "path": item["identity"]["path"],
                "owner": history["owner"], "session_id": history["session_id"],
                "worktree": history["worktree"], "released_at": record["retired_at"],
                "release_record": reference, "release_evidence": record["evidence"],
                "observed_at": cleanup.utc(now), "ownership": "retired-v2",
            })
    if not targets:
        lease.fail("an explicit bounded unit needs releases or retirements")
    cleanup.validate_disjoint_targets(targets)
    remaining = cleanup.MAX_TREE_ENTRIES
    for target in targets:
        scanned, _ = cleanup.scan_tree(
            Path(target["path"]), minimum_seconds=cleanup.MINIMUM_RETENTION_SECONDS,
            current_time=now, maximum_entries=remaining,
        )
        remaining -= scanned["tree"]["entries"]
        target.update(scanned)
    result = {"schema": 1, "scope": cleanup.SCOPE, "targets": targets}
    cleanup.encode_manifest(result)
    return result


def validate_unit(path: Path, *, now: dt.datetime) -> tuple[dict, bytes, dict]:
    manifest, data = cleanup.read_private_document(path)
    policy.exact(manifest, {"schema", "scope", "targets"}, "operational unit")
    if type(manifest["schema"]) is not int or manifest["schema"] != 1 or manifest["scope"] != cleanup.SCOPE:
        lease.fail("invalid operational unit envelope")
    targets = manifest["targets"]
    if not isinstance(targets, list) or not targets:
        lease.fail("unit needs explicit targets")
    cleanup.require_target_limit(len(targets))
    count = sum(cleanup.integer(t["tree"]["entries"], "declared entries", minimum=1) for t in targets)
    if count > cleanup.MAX_TREE_ENTRIES:
        lease.fail("unit exceeds aggregate entry limit; no automatic splitting")
    cleanup.validate_disjoint_targets(targets)
    entries = {}
    releases = cleanup.ReleaseIndex(now)
    index = releases.references
    retired_records = {}
    remaining = cleanup.MAX_TREE_ENTRIES
    for target in targets:
        if "ownership" not in target:
            _, records = cleanup.validate_manifest_target(
                target, manifest_path=path, current_time=now, releases=releases,
                maximum_entries=remaining,
            )
        else:
            policy.exact(target, cleanup.TARGET_KEYS | {"ownership"}, "retired manifest target")
            if target["ownership"] != "retired-v2":
                lease.fail("unknown owner representation")
            ref = target["release_record"]
            key = (ref["path"], ref["sha256"])
            if key not in retired_records:
                retired_records[key] = retirement(ref, now=now)
                collect_references(ref, index)
            record, history = retired_records[key]
            nominated = [t for t in record["targets"] if t["identity"]["path"] == target["path"]]
            if len(nominated) != 1 or nominated[0]["identity"] != {"path": target["path"], **target["root"]}:
                lease.fail("target is not in exact retirement approval")
            expected = {
                "kind": "xcode-derived-data", "owner": history["owner"],
                "session_id": history["session_id"], "worktree": history["worktree"],
                "released_at": record["retired_at"], "release_evidence": record["evidence"],
            }
            if any(target[k] != v for k, v in expected.items()):
                lease.fail("target differs from historical owner and retirement")
            if not policy.timestamp(record["retired_at"]) <= policy.timestamp(target["observed_at"]) <= now:
                lease.fail("invalid retirement observation time")
            scanned, records = cleanup.scan_tree(
                Path(target["path"]), minimum_seconds=target["retention"]["minimum_seconds"],
                current_time=now, maximum_entries=remaining,
            )
            if any(scanned[k] != target[k] for k in ("tree", "root", "retention")):
                lease.fail("retired compiler target changed since inventory")
        entries[target["path"]] = records
        remaining -= len(records)
    target_index = cleanup.TargetIndex([Path(t["path"]) for t in targets])
    for reference in [*index.references.values(), {"path": str(path)}]:
        if target_index.contains(Path(reference["path"])):
            lease.fail("operational evidence is inside nominated deletion scope")
    index.validate()
    return manifest, data, entries


def campaign(path: Path, unit_id: str, *, now: dt.datetime) -> Path:
    value, _ = cleanup.read_private_document(path)
    policy.exact(value, {"schema", "units", "reviewed_at", "approval"}, "campaign")
    v2(value["schema"])
    units = value["units"]
    if not isinstance(units, list) or not 1 <= len(units) <= MAX_UNITS:
        lease.fail("campaign must explicitly review 1..64 bounded units")
    reviewed = policy.timestamp(value["reviewed_at"])
    approval = approved({k: v for k, v in value.items() if k != "approval"}, value["approval"],
                        purpose="bounded-campaign", earliest=reviewed, now=now)
    roots, ids, manifests = [], set(), {}
    for unit in units:
        policy.exact(unit, {"id", "manifest"}, "campaign unit")
        identity = lease.validate_uuid(unit["id"], "unit id")
        if identity in ids:
            lease.fail("duplicate campaign unit")
        ids.add(identity)
        document = policy.document(policy.reference(unit["manifest"]))
        policy.exact(document, {"schema", "scope", "targets"}, "campaign unit envelope")
        if type(document["schema"]) is not int or document["schema"] != 1 or document["scope"] != cleanup.SCOPE:
            lease.fail("unknown campaign unit format")
        targets = document["targets"]
        if not isinstance(targets, list) or not targets:
            lease.fail("empty campaign unit")
        cleanup.require_target_limit(len(targets))
        if sum(cleanup.integer(t["tree"]["entries"], "entries", minimum=1) for t in targets) > cleanup.MAX_TREE_ENTRIES:
            lease.fail("campaign unit exceeds aggregate entry limit")
        roots.extend(missing_path(t["path"]) for t in targets)
        manifests[identity] = Path(unit["manifest"]["path"])
    index = cleanup.TargetIndex(roots)
    for protected in [path, *manifests.values(), Path(value["approval"]["path"]),
                      *(Path(r["path"]) for r in approval["evidence"])]:
        if index.contains(protected):
            lease.fail("campaign evidence overlaps targets")
    if unit_id not in manifests:
        lease.fail("unit was not explicitly reviewed in campaign")
    return manifests[unit_id]


@contextlib.contextmanager
def administrative_locks():
    """Same lock order as v1 maintenance; NB prevents updater/finalizer deadlocks."""
    p = lease.paths()
    for key in ("root", "leases"):
        lease.ensure_secure_directory(p[key], create=False)
    with contextlib.ExitStack() as stack:
        held = []
        for key in ("policy_lock", "lock", "registry_lock"):
            fd = lease._open_regular_file(p[key], os.O_RDWR)
            stack.callback(os.close, fd)
            try:
                lease.fcntl.flock(fd, lease.fcntl.LOCK_EX | lease.fcntl.LOCK_NB)
            except BlockingIOError:
                lease.fail("live writer, maintenance, or administrator holds a required lock")
            held.append((fd, p[key]))
        def check():
            for fd, path in held:
                lease.validate_fd_path(fd, path, private=True)
            # SUSPENDED is required, never interpreted as permission to delete.
            policy.read_bytes(p["suspend"], private=True)
        check()
        yield check
        check()


def registry_digest() -> str:
    values = []
    for record in lease.scan_records():
        path = lease.record_path(record["lease_id"])
        values.append({"path": str(path), "sha256": policy.digest(policy.read_bytes(path, private=True))})
    return policy.digest(policy.canonical(values))


def process_absent(pid: int) -> None:
    # A reused PID is ambiguous too. Never infer retirement from its new start.
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,lstart="], text=True, capture_output=True,
        timeout=30, check=False,
    )
    if result.returncode or result.stderr.strip() or not result.stdout.strip():
        lease.fail("cannot establish process identity census")
    seen = set()
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2 or not fields[0].isdigit():
            lease.fail("ambiguous process identity census")
        seen.add(int(fields[0]))
    if os.getpid() not in seen:
        lease.fail("incomplete process identity census")
    if pid in seen:
        lease.fail("original requester PID is present or reused; resolution refused")


def namespace_write_new(path: Path, data: bytes) -> None:
    """O_EXCL durable evidence publication inside an already locked namespace."""
    lease.ensure_secure_directory(path.parent, create=False)
    with cleanup.directory_fd(path.parent) as parent_fd:
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=parent_fd)
        try:
            cleanup.write_all(fd, data)
            os.fsync(fd)
            if lease.validate_fd_path(fd, path, private=True).st_nlink != 1:
                lease.fail("administrative evidence gained a hard link")
            os.fsync(parent_fd)
        finally:
            os.close(fd)


def resolve_record(request_path: Path, journal_path: Path, *,
                   clock: Callable = cleanup.now_utc, opened: Callable = cleanup.open_file_inventory) -> dict:
    preview, _ = cleanup.read_private_document(request_path)
    original = policy.document(policy.reference(preview["record"]))
    if cleanup.path_within(journal_path, missing_path(original["cwd"])):
        lease.fail("resolution journal must be outside the original owner's worktree")
    journal = cleanup.DurableJournal(journal_path, {"schema": 2, "operation": "resolve-record"})
    removed = False
    try:
        with cleanup.cancellation_signals(), administrative_locks() as lock_check:
            request, raw_request = cleanup.read_private_document(request_path)
            policy.exact(request, {
                "schema", "host", "record", "record_identity", "registry_sha256",
                "not_before", "expires_at", "owner_release", "approval",
            }, "exact record resolution")
            v2(request["schema"])
            now = clock()
            start, end = policy.timestamp(request["not_before"]), policy.timestamp(request["expires_at"])
            if not start <= now < end or not 0 < (end - start).total_seconds() <= policy.MAX_WINDOW_SECONDS:
                lease.fail("record resolution window is closed or too long")
            if request["host"] != policy.host_identity():
                lease.fail("record resolution host changed")
            raw = policy.reference(request["record"])
            record_path = Path(request["record"]["path"])
            record = lease._validate_record_shape(policy.document(raw), record_path)
            if record_path != lease.record_path(record["lease_id"]):
                lease.fail("record is outside the exact live registry")
            st = record_path.lstat()
            if st.st_nlink != 1:
                lease.fail("record has a hard link")
            record_identity = cleanup.validate_identity(request["record_identity"], "original record identity")
            if record_identity["path"] != str(record_path):
                lease.fail("original record identity names a different registry path")
            lock = lease.paths()["lock"].stat()
            if (record["lock_dev"], record["lock_ino"]) != (lock.st_dev, lock.st_ino):
                lease.fail("record belongs to a different coordination inode")
            release = policy.document(policy.reference(request["owner_release"]))
            policy.exact(release, {
                "schema", "record_sha256", "owner", "cwd", "request_pid", "request_start",
                "released_at", "active_queued", "disposition", "evidence",
            }, "affirmative record release")
            v2(release["schema"])
            if any(release[k] != record[k] for k in ("owner", "cwd", "request_pid", "request_start")):
                lease.fail("affirmative release does not identify original owner/process")
            if release["record_sha256"] != request["record"]["sha256"]:
                lease.fail("affirmative release does not bind original bytes")
            if release["active_queued"] != "none" or release["disposition"] != "owner-relinquished-entire-lane":
                lease.fail("active, queued, unknown or unreleased owner cannot be reconciled")
            released = policy.timestamp(release["released_at"])
            if not policy.timestamp(record["created_at"]) <= released <= now:
                lease.fail("invalid affirmative release time")
            refs(release["evidence"])
            approval = approved(
                {k: v for k, v in request.items() if k != "approval"}, request["approval"],
                purpose="resolve-exact-record", earliest=max(start, released), now=now,
            )
            deadline = time.monotonic() + (end - now).total_seconds()
            def check():
                lock_check()
                if not now <= clock() < end or time.monotonic() >= deadline:
                    lease.fail("record resolution expired or clock moved backwards")
                if registry_digest() != policy.sha(request["registry_sha256"]):
                    lease.fail("registry changed; exact resolution invalidated")
                if policy.read_bytes(request_path, private=True) != raw_request:
                    lease.fail("resolution request changed")
                if policy.reference(request["record"]) != raw or cleanup.identity_document(record_path) != record_identity:
                    lease.fail("original record changed")
                if record_path.lstat().st_nlink != 1:
                    lease.fail("record gained a hard link")
                policy.reference(request["owner_release"])
                policy.reference(request["approval"])
                refs(release["evidence"])
                refs(approval["evidence"])
                process_absent(record["request_pid"])
                cleanup.require_no_build_activity()
                if (record["proof_dev"], record["proof_ino"]) in opened()[1]:
                    lease.fail("original proof inode is still open")
                # External probes can be slow. Recheck bytes, identity, locks and
                # deadline after them, not only before them.
                lock_check()
                if registry_digest() != request["registry_sha256"] or policy.reference(request["record"]) != raw:
                    lease.fail("registry changed during process/open-use inspection")
                if cleanup.identity_document(record_path) != record_identity or record_path.lstat().st_nlink != 1:
                    lease.fail("original record identity changed during inspection")
                if policy.read_bytes(request_path, private=True) != raw_request:
                    lease.fail("resolution request changed during inspection")
                policy.reference(request["owner_release"])
                policy.reference(request["approval"])
                refs(release["evidence"])
                refs(approval["evidence"])
                if not now <= clock() < end or time.monotonic() >= deadline:
                    lease.fail("record resolution expired during inspection")
            check()
            archive_root = lease.paths()["root"] / "resolutions-v2"
            lease.ensure_secure_directory(archive_root, create=True)
            archive = archive_root / record["lease_id"]
            archive.mkdir(mode=0o700)
            lease.fsync_directory(archive_root)
            namespace_write_new(archive / "original.json", raw)
            namespace_write_new(archive / "request.json", raw_request)
            namespace_write_new(archive / "owner-release.json", policy.reference(request["owner_release"]))
            namespace_write_new(archive / "approval.json", policy.reference(request["approval"]))
            for index, evidence in enumerate([*release["evidence"], *approval["evidence"]]):
                namespace_write_new(archive / f"evidence-{index}", policy.reference(evidence))
            journal.append({"event": "resolution-intent", "archive": str(archive), "record": request["record"]})
            check()
            with cleanup.directory_fd(record_path.parent) as fd:
                if cleanup.identity_stat(os.fstat(fd)) != cleanup.identity_stat(record_path.parent.stat()):
                    lease.fail("registry directory changed")
                os.unlink(record_path.name, dir_fd=fd)
                removed = True
                os.fsync(fd)
            journal.append({"event": "resolved", "archive": str(archive), "removed": True})
            return {"resolved": record["lease_id"], "archive": str(archive), "suspension": "unchanged"}
    except BaseException as exc:
        journal.append({"event": "stopped", "removed": removed, "error": f"{type(exc).__name__}: {exc}"})
        raise
    finally:
        journal.close()


def validate_controls(controls: dict, package: dict, manifest: dict, *, now: dt.datetime) -> None:
    policy.exact(controls, {
        "schema", "window_sha256", "manifest_sha256", "protected_roots",
        "entrypoints", "coverage_evidence", "reviewed_at", "approval",
    }, "operational controls")
    v2(controls["schema"])
    if controls["window_sha256"] != policy.digest(policy.canonical(package)) or controls["manifest_sha256"] != policy.digest(policy.canonical(manifest)):
        lease.fail("operational controls do not bind the exact window and unit")
    reviewed = policy.timestamp(controls["reviewed_at"])
    approval = approved({k: v for k, v in controls.items() if k != "approval"}, controls["approval"],
                        purpose="operational-rollout", earliest=reviewed, now=now)
    target_index = cleanup.TargetIndex([Path(t["path"]) for t in manifest["targets"]])
    evidence_outside(controls, target_index)
    evidence_outside(approval, target_index)
    refs(controls["coverage_evidence"])
    protected = controls["protected_roots"]
    if not isinstance(protected, list) or not protected:
        lease.fail("explicit active/pending/unknown and linked resource protections required")
    target_paths = [Path(t["path"]) for t in manifest["targets"]]
    for root in protected:
        path = Path(cleanup.validate_identity(root, "protected resource")["path"])
        if any(cleanup.path_within(t, path) or cleanup.path_within(path, t) for t in target_paths):
            lease.fail("nominated target overlaps a protected scope")
    global_roots = next(c["roots"] for c in package["cohorts"] if c["name"] == "global-cleanup-entrypoints")
    fingerprinted = {r["path"]: r["sha256"] for root in global_roots for r in root["writers"]}
    bundle = Path(__file__).resolve().parents[2]
    for name in OPERATIONS_FILES:
        file = bundle / name
        data = policy.read_bytes(file, private=False)
        if fingerprinted.get(str(file)) != policy.digest(data):
            lease.fail("operational bundle is not completely fingerprinted")
        if name in policy.PROTOCOL_FILES and policy.digest(data) != policy.PROTOCOL_FILES[name]:
            lease.fail("frozen v1 client bytes changed")
    endpoints = controls["entrypoints"]
    if not isinstance(endpoints, list) or not endpoints:
        lease.fail("all current, legacy, scheduled and manual cleanup routes must be accounted for")
    seen = set()
    operational = str(bundle / "tools/apple-build-operations.py")
    for endpoint in endpoints:
        policy.exact(endpoint, {"path", "sha256", "enforcement"}, "cleanup entrypoint")
        path = endpoint["path"]
        if path in seen or fingerprinted.get(path) != endpoint["sha256"]:
            lease.fail("cleanup route absent from approved writer census or duplicated")
        seen.add(path)
        data = policy.read_bytes(Path(path), private=False)
        if policy.digest(data) != endpoint["sha256"]:
            lease.fail("cleanup entrypoint changed")
        if endpoint["enforcement"] == "operational-v2":
            if path != operational:
                lease.fail("only the fingerprinted operational entrypoint may execute cleanup")
        elif endpoint["enforcement"] == "disabled":
            if data != DISABLED_ENTRYPOINT:
                lease.fail("old cleanup reader must be replaced by the reviewed refusal stub")
        else:
            lease.fail("old/v1-only reader cannot participate in operational rollout")
    if operational not in seen:
        lease.fail("operational entrypoint is not in route census")
    dependencies = {str(bundle / name) for name in OPERATIONS_FILES} - {operational}
    if seen != set(fingerprinted) - dependencies:
        lease.fail("every non-library global cleanup route needs an explicit disposition")
    # No owner may claim a queued lane is over merely because the kernel is quiet.
    approval = policy.document(policy.reference(package["approval"]))
    for ref in approval["attestations"]:
        attestation = policy.document(policy.reference(ref))
        if attestation["active_queued"] != "none":
            lease.fail("activation preparation is prohibited during active or queued shipping")


def file_state(path: Path) -> str:
    try:
        path.lstat()
    except FileNotFoundError:
        return "absent"
    return policy.digest(policy.read_bytes(path, private=True))


def prepare_rollout(window_path: Path, manifest_path: Path, controls_path: Path,
                    output: Path, journal: cleanup.DurableJournal, *, now: dt.datetime) -> dict:
    with administrative_locks() as check:
        if lease.scan_records():
            lease.fail("unresolved lease records prevent rollout preparation")
        cleanup.require_no_build_activity()
        manifest, _, _ = validate_unit(manifest_path, now=now)
        for target in manifest["targets"]:
            for artifact in (output, journal.path):
                if cleanup.path_within(artifact, Path(target["path"])) or cleanup.path_within(
                    artifact, Path(target["worktree"]["path"])
                ):
                    lease.fail("rollout artifacts overlap a nominated owner or target")
        package, _ = cleanup.read_private_document(window_path)
        policy.validate_package(package, manifest_path)
        controls, _ = cleanup.read_private_document(controls_path)
        validate_controls(controls, package, manifest, now=now)
        p = lease.paths()
        result = {
            "schema": 2, "host": policy.host_identity(), "prepared_at": cleanup.utc(now),
            "window": cleanup.reference_for(window_path),
            "manifest": cleanup.reference_for(manifest_path),
            "controls": cleanup.reference_for(controls_path),
            "suspension": cleanup.reference_for(p["suspend"]),
            "expected": {name: file_state(p["root"] / name) for name in (
                lease.ROLLOUT_NAME, policy.POLICY_NAME, CONTROLS_NAME,
            )},
        }
        check()
        journal.append({"event": "prepare-intent", "stage": result, "output": str(output)})
        cleanup.write_private_new(output, policy.canonical(result) + b"\n")
        journal.append({"event": "prepared-inactive", "output": str(output)})
        return {"prepared": str(output), "state": "prepared-inactive", "activation": "not-authorized"}


def stage_rollout(window_path: Path, manifest_path: Path, controls_path: Path,
                  output: Path, journal_path: Path, *, now: dt.datetime) -> dict:
    manifest, _ = cleanup.read_private_document(manifest_path)
    controls, _ = cleanup.read_private_document(controls_path)
    artifact_outside(output, manifest, controls)
    artifact_outside(journal_path, manifest, controls)
    journal = cleanup.DurableJournal(journal_path, {"schema": 2, "operation": "stage-rollout"})
    try:
        with cleanup.cancellation_signals():
            return prepare_rollout(window_path, manifest_path, controls_path, output, journal, now=now)
    except BaseException as exc:
        journal.append({"event": "stopped", "error": f"{type(exc).__name__}: {exc}",
                        "output_may_be_partial": output.exists()})
        raise
    finally:
        journal.close()


def install_prepared(stage_path: Path, approval_ref: dict, journal_path: Path, *,
                     now: dt.datetime) -> dict:
    preview, _ = cleanup.read_private_document(stage_path)
    artifact_outside(journal_path, policy.document(policy.reference(preview["manifest"])),
                     policy.document(policy.reference(preview["controls"])))
    journal = cleanup.DurableJournal(journal_path, {"schema": 2, "operation": "install-suspended"})
    published = []
    try:
        with cleanup.cancellation_signals(), administrative_locks() as check:
            stage, raw = cleanup.read_private_document(stage_path)
            policy.exact(stage, {
                "schema", "host", "prepared_at", "window", "manifest", "controls", "suspension", "expected",
            }, "staged rollout")
            v2(stage["schema"])
            approved(stage, approval_ref, purpose="install-suspended-rollout",
                     earliest=policy.timestamp(stage["prepared_at"]), now=now)
            if stage["host"] != policy.host_identity() or lease.scan_records():
                lease.fail("host changed or retained lease blocks installation")
            p = lease.paths()
            if stage["suspension"]["path"] != str(p["suspend"]):
                lease.fail("staged suspension is not the canonical marker")
            policy.reference(stage["suspension"])
            package = policy.document(policy.reference(stage["window"]))
            manifest = policy.document(policy.reference(stage["manifest"]))
            controls = policy.document(policy.reference(stage["controls"]))
            manifest_path = Path(stage["manifest"]["path"])
            validate_unit(manifest_path, now=now)
            policy.validate_package(package, manifest_path)
            validate_controls(controls, package, manifest, now=now)
            cleanup.require_no_build_activity()
            replacements = {
                policy.POLICY_NAME: policy.reference(stage["window"]),
                CONTROLS_NAME: policy.reference(stage["controls"]),
                lease.ROLLOUT_NAME: ("\n".join(lease.REQUIRED_ROLLOUT) + "\n").encode(),
            }
            policy.exact(stage["expected"], set(replacements), "rollout compare-and-swap")
            for name in replacements:
                if file_state(p["root"] / name) != stage["expected"][name]:
                    lease.fail("rollout changed since preparation; compare-and-swap refused")
            # Originals and intent precede every publication. SUSPENDED remains
            # the commit barrier even after a crash between these three writes.
            journal.append({"event": "install-intent", "stage": stage,
                            "originals": {name: None if stage["expected"][name] == "absent"
                                          else policy.read_bytes(p["root"] / name, private=True).decode()
                                          for name in replacements}})
            for name, data in replacements.items():
                check()
                policy.reference(stage["suspension"])
                if cleanup.read_private_document(stage_path)[1] != raw:
                    lease.fail("staged rollout changed")
                policy.reference(stage["window"])
                policy.reference(stage["controls"])
                policy.reference(stage["manifest"])
                policy.reference(approval_ref)
                policy.validate_package(package, manifest_path)
                validate_controls(controls, package, manifest, now=cleanup.now_utc())
                if file_state(p["root"] / name) != stage["expected"][name]:
                    lease.fail("publication compare-and-swap failed")
                temporary = p["root"] / (".operations-" + name)
                namespace_write_new(temporary, data)
                check()
                policy.reference(stage["suspension"])
                policy.reference(stage["window"])
                policy.reference(stage["controls"])
                policy.reference(stage["manifest"])
                policy.reference(approval_ref)
                cleanup.require_no_build_activity()
                policy.validate_package(package, manifest_path)
                validate_controls(controls, package, manifest, now=cleanup.now_utc())
                if file_state(p["root"] / name) != stage["expected"][name]:
                    lease.fail("publication changed while syncing candidate")
                os.replace(temporary, p["root"] / name)
                published.append(name)
                lease.fsync_directory(p["root"])
                journal.append({"event": "published", "name": name, "sha256": policy.digest(data)})
            policy.reference(stage["suspension"])
            journal.append({"event": "installed-suspended", "published": published})
            return {"state": "installed-suspended", "activation": "not-authorized", "published": published}
    except BaseException as exc:
        journal.append({"event": "stopped", "published": published, "error": f"{type(exc).__name__}: {exc}"})
        raise
    finally:
        journal.close()


class OperationalGuard(cleanup.RuntimeGuard):
    def __init__(self, manifest: dict, pinned, window_id: str, clock, campaign_path: Path, unit_id: str):
        self.campaign_path, self.unit_id = campaign_path, unit_id
        self.campaign_reference = cleanup.reference_for(campaign_path)
        self.controls_reference = cleanup.reference_for(lease.paths()["root"] / CONTROLS_NAME)
        super().__init__(manifest, pinned, window_id, clock)
        target_index = cleanup.TargetIndex([Path(t["path"]) for t in manifest["targets"]])
        evidence_outside(self.controls_reference, target_index)
        evidence_outside(self.campaign_reference, target_index)
        self.absent_owners = set()
        for target in manifest["targets"]:
            if target.get("ownership") == "retired-v2":
                collect_references(target["release_record"], self.references)
                self.absent_owners.add(Path(target["worktree"]["path"]))

    def validate_scope(self, package: dict) -> None:
        # Reuse v1's bundle/evidence isolation without pretending missing owners
        # are registered writers. Their real repository anchors require coverage.
        roots = {root["identity"]["path"] for item in package["cohorts"]
                 if item["name"] not in {"global-cleanup-entrypoints", "manual-xcode-writers-disabled-or-wrapped"}
                 for root in item["roots"]}
        for target in self.manifest["targets"]:
            owner = target["worktree"]["path"]
            if target.get("ownership") == "retired-v2":
                _, history = retirement(target["release_record"], now=self.clock(), check_targets=False)
                owner = history["repository"]["path"]
            if owner not in roots:
                lease.fail("original owner/repository is outside the approved writer coverage")
        # Evidence must survive all targets, including nested attestation evidence.
        index = cleanup.TargetIndex([Path(t["path"]) for t in self.manifest["targets"]])
        evidence_outside(package, index)
        approval = policy.document(policy.reference(package["approval"]))
        evidence_outside(approval, index)
        for ref in approval["attestations"]:
            evidence_outside(policy.document(policy.reference(ref)), index)

    def validate_owner(self, target: dict) -> None:
        if target.get("ownership") != "retired-v2":
            super().validate_owner(target)
            return
        record, history = retirement(target["release_record"], now=self.clock(), check_targets=False)
        nominated = next(t for t in record["targets"] if t["identity"]["path"] == target["path"])
        retired_location(nominated, history)

    def check(self, target: dict | None = None) -> None:
        super().check(target)
        for owner in self.absent_owners:
            absent(owner)
        policy.reference(self.campaign_reference)
        if campaign(self.campaign_path, self.unit_id, now=self.clock()) != self.pinned.path:
            lease.fail("selected campaign unit changed")
        controls = policy.document(policy.reference(self.controls_reference))
        package = policy.document(policy.read_bytes(lease.paths()["root"] / policy.POLICY_NAME, private=True))
        validate_controls(controls, package, self.manifest, now=self.clock())
        self.deadline_check()


def apply_unit(campaign_path: Path, unit_id: str, window_id: str, journal_path: Path, *,
               clock: Callable = cleanup.now_utc, opened: Callable = cleanup.open_file_inventory) -> dict:
    selected = campaign(campaign_path, unit_id, now=clock())
    controls_path = lease.paths()["root"] / CONTROLS_NAME
    artifact_outside(journal_path, cleanup.read_private_document(selected)[0])
    # A missing prerequisite is still journaled below; if controls are present,
    # refuse a protected journal destination before creating any file there.
    if controls_path.exists() or controls_path.is_symlink():
        artifact_outside(journal_path, cleanup.read_private_document(selected)[0],
                         cleanup.read_private_document(controls_path)[0])
    journal = cleanup.DurableJournal(journal_path, {"schema": 2, "operation": "apply-unit", "unit_id": unit_id})
    removals = []
    try:
        with cleanup.cancellation_signals(), contextlib.ExitStack() as stack:
            path = campaign(campaign_path, unit_id, now=clock())
            manifest, data, entries = validate_unit(path, now=clock())
            if any(cleanup.path_within(journal_path, Path(t["path"])) or
                   cleanup.path_within(journal_path, Path(t["worktree"]["path"])) for t in manifest["targets"]):
                lease.fail("journal overlaps owner or deletion scope")
            pinned = cleanup.PinnedManifest(path, data)
            stack.callback(pinned.close)
            guard = OperationalGuard(manifest, pinned, window_id, clock, campaign_path, unit_id)
            guard.check()
            journal.append({"event": "authorized", "manifest": manifest,
                            "authorization": guard.authorization})
            for target in manifest["targets"]:
                guard.check(target)
                scanned, _ = cleanup.scan_tree(
                    Path(target["path"]), minimum_seconds=target["retention"]["minimum_seconds"],
                    current_time=clock(), maximum_entries=target["tree"]["entries"],
                )
                if any(scanned[k] != target[k] for k in ("tree", "root", "retention")):
                    lease.fail("unit target changed immediately before removal")
                removal = cleanup.TargetRemoval(target, entries[target["path"]], guard, journal, opened)
                removals.append(removal)
                removal.run()
            removed = sum(r.removed for r in removals)
            journal.append({"event": "completed", "removed": removed})
            return {"unit_id": unit_id, "removed": removed, "journal": str(journal_path)}
    except BaseException as exc:
        journal.append({"event": "stopped", "removed": sum(r.removed for r in removals),
                        "error": f"{type(exc).__name__}: {exc}"})
        raise
    finally:
        journal.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("inventory-unit")
    command.add_argument("--release-record", type=Path, action="append", default=[])
    command.add_argument("--retirement", type=Path, action="append", default=[])
    command.add_argument("--output", type=Path, required=True)
    command = commands.add_parser("validate-unit")
    command.add_argument("--manifest", type=Path, required=True)
    command = commands.add_parser("validate-campaign")
    command.add_argument("--campaign", type=Path, required=True)
    command.add_argument("--unit-id", required=True)
    command = commands.add_parser("resolve-record")
    command.add_argument("--request", type=Path, required=True)
    command.add_argument("--journal", type=Path, required=True)
    command = commands.add_parser("stage-rollout")
    for name in ("window", "manifest", "controls", "output", "journal"):
        command.add_argument("--" + name, type=Path, required=True)
    command = commands.add_parser("install-prepared")
    for name in ("stage", "approval", "journal"):
        command.add_argument("--" + name, type=Path, required=True)
    command = commands.add_parser("apply-unit")
    command.add_argument("--campaign", type=Path, required=True)
    command.add_argument("--unit-id", required=True)
    command.add_argument("--window-id", required=True)
    command.add_argument("--journal", type=Path, required=True)
    args = parser.parse_args()
    try:
        now = cleanup.now_utc()
        if args.command == "inventory-unit":
            document = inventory(args.release_record, args.retirement, now=now)
            if any(cleanup.path_within(args.output, Path(t["path"])) or
                   cleanup.path_within(args.output, Path(t["worktree"]["path"])) for t in document["targets"]):
                lease.fail("inventory output overlaps a nominated owner or target")
            cleanup.write_private_new(args.output, cleanup.encode_manifest(document))
            result = {"manifest": str(args.output), "targets": len(document["targets"])}
        elif args.command == "validate-unit":
            document, _, _ = validate_unit(args.manifest, now=now)
            result = {"targets": len(document["targets"]), "authorization": "not-checked"}
        elif args.command == "validate-campaign":
            path = campaign(args.campaign, args.unit_id, now=now)
            validate_unit(path, now=now)
            result = {"selected_manifest": str(path), "authorization": "not-checked"}
        elif args.command == "resolve-record":
            result = resolve_record(args.request, args.journal)
        elif args.command == "stage-rollout":
            result = stage_rollout(args.window, args.manifest, args.controls, args.output, args.journal, now=now)
        elif args.command == "install-prepared":
            result = install_prepared(args.stage, cleanup.reference_for(args.approval), args.journal, now=now)
        else:
            result = apply_unit(args.campaign, args.unit_id, args.window_id, args.journal)
        print(policy.canonical(result).decode())
        return 0
    except (lease.LeaseError, OSError, ValueError, TypeError, KeyError, OverflowError,
            subprocess.SubprocessError, plistlib.InvalidFileException) as exc:
        print(f"apple-build-operations: {exc}", file=sys.stderr)
        return 75


if __name__ == "__main__":
    sys.exit(main())
