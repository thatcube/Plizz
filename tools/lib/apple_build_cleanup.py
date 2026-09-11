#!/usr/bin/env python3
"""Exact-manifest inventory and deletion for owner-released Apple build outputs.

Inventory is the default safety posture. Destructive application is a separate
command and requires the existing authenticated v1 exclusive lease plus the
installed attested maintenance-window companion. This module never creates
owner release records, owner attestations, approvals, rollout policy, or
maintenance windows.
"""

from __future__ import annotations

import argparse
from bisect import bisect_right
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import stat
import subprocess
import sys
import time
from typing import Any, Callable

import apple_build_lease as lease
import apple_maintenance_policy as policy


SCHEMA = 1
SCOPE = policy.SCOPE
MINIMUM_RETENTION_SECONDS = 72 * 60 * 60
MAX_TARGETS = 256
MAX_TREE_ENTRIES = 4096
OPERATIONAL_CONTROLS_NAME = "operational-controls-v2.json"
TARGET_KINDS = {"worktree-apple-build", "xcode-derived-data"}
# Mixed build roots are deliberately ineligible. Nominate narrower compiler
# outputs instead of guessing which dependencies, sources or evidence to keep.
GENERATED_SUFFIXES = {
    ".o", ".pcm", ".swiftmodule", ".swiftdoc", ".swiftsourceinfo",
    ".swiftdeps", ".swiftconstvalues", ".dia", ".hmap",
}
PROTECTED_SUFFIXES = (
    ".ipa",
    ".xcarchive",
    ".dsym",
    ".dsym.zip",
    ".xcresult",
    ".p8",
    ".mobileprovision",
    ".provisionprofile",
    ".xcactivitylog",
    ".trace",
    ".log",
    ".jsonl",
    ".swift",
    ".c",
    ".h",
    ".cpp",
    ".cc",
    ".m",
    ".mm",
    ".rs",
    ".py",
    ".sh",
    ".md",
    ".vmdk",
    ".qcow2",
    ".vdi",
)
PROTECTED_COMPONENTS = {
    ".git",
    ".trash",
    "archives",
    "coresimulator",
    "evidence",
    "logs",
    "release-evidence",
    "virtual machines",
    "vms",
    "sourcepackages",
    "checkouts",
    "repositories",
    "artifacts",
    "package-cache",
    "node_modules",
    ".swiftpm",
    ".cargo",
    ".npm",
    ".config",
    ".copilot",
    "org.swift.swiftpm",
    "packages",
    "package-root",
    "sdks",
    "toolchains",
    "devices",
}
RELEASE_KEYS = {
    "schema",
    "scope",
    "owner",
    "session_id",
    "released_at",
    "worktree",
    "evidence",
    "targets",
}
TARGET_KEYS = {
    "kind",
    "path",
    "owner",
    "session_id",
    "worktree",
    "released_at",
    "release_record",
    "release_evidence",
    "observed_at",
    "retention",
    "root",
    "tree",
}
TREE_KEYS = {"sha256", "entries", "allocated_bytes", "apparent_bytes"}
RETENTION_KEYS = {"minimum_seconds", "youngest_entry_at"}
IDENTITY_KEYS = {"path", "device", "inode"}


def fail(message: str) -> None:
    lease.fail(message)


def utc(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds")


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def integer(value: Any, label: str, *, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        fail(f"{label}: integer >= {minimum} required")
    return value


def identity_document(path: Path) -> dict[str, Any]:
    st = path.lstat()
    lease._check_owned(st, str(path))
    if stat.S_ISLNK(st.st_mode):
        fail(f"symlink cannot be a cleanup root: {path}")
    return {"path": str(path), "device": st.st_dev, "inode": st.st_ino}


def validate_identity(value: Any, label: str) -> dict[str, Any]:
    item = policy.exact(value, IDENTITY_KEYS, label)
    path = policy.physical_path(item["path"])
    expected = {
        "path": str(path),
        "device": integer(item["device"], f"{label} device"),
        "inode": integer(item["inode"], f"{label} inode"),
    }
    if identity_document(path) != expected:
        fail(f"{label} changed: {path}")
    return expected


def secure_parent(path: Path) -> Path:
    if not path.is_absolute() or path != path.parent.resolve(strict=True) / path.name:
        fail(f"output path must be absolute: {path}")
    parent = path.parent.resolve(strict=True)
    if path_within(path, lease.paths()["root"].parent):
        fail("cleanup output cannot modify maintenance policy or lease state")
    protected_output_parts = PROTECTED_COMPONENTS - {
        ".config", ".copilot", "evidence", "logs", "release-evidence",
    }
    if any(part.lower() in protected_output_parts for part in path.parts):
        fail(f"cleanup output cannot be inside a protected resource: {path}")
    if os.environ.get("APPLE_BUILD_INTERLOCK_TESTING") == "1":
        home = lease.paths()["home"]
        if parent != home and home not in parent.parents:
            fail(f"test output escapes fixture HOME: {path}")
    st = parent.lstat()
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
        fail(f"output parent is not a real directory: {parent}")
    lease._check_owned(st, str(parent))
    lease._check_private_mode(st, str(parent))
    return parent


def write_all(fd: int, payload: bytes) -> None:
    remaining = memoryview(payload)
    while remaining:
        written = os.write(fd, remaining)
        if written <= 0:
            fail("short write while recording cleanup evidence")
        remaining = remaining[written:]


def write_private_new(path: Path, payload: bytes) -> None:
    parent = secure_parent(path)
    with directory_fd(parent) as parent_fd:
        fd = os.open(
            path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600, dir_fd=parent_fd,
        )
        try:
            write_all(fd, payload)
            os.fsync(fd)
            lease.validate_fd_path(fd, path, private=True)
            os.fsync(parent_fd)
        finally:
            os.close(fd)


def read_private_document(path: Path) -> tuple[dict[str, Any], bytes]:
    data = policy.read_bytes(path, private=True)
    return policy.document(data), data


def reference_for(path: Path, data: bytes | None = None) -> dict[str, str]:
    if data is None:
        data = policy.read_bytes(path, private=True)
    return {"path": str(path), "sha256": policy.digest(data)}


class ReferenceIndex:
    """Deduplicate identities, never cache a successful mutable-file check."""

    def __init__(self):
        self.references: dict[str, dict[str, str]] = {}

    def add(self, value: Any, label: str) -> dict[str, str]:
        policy.exact(value, {"path", "sha256"}, label)
        reference = {
            "path": str(policy.physical_path(value["path"])),
            "sha256": policy.sha(value["sha256"]),
        }
        previous = self.references.get(reference["path"])
        if previous is not None and previous != reference:
            fail(f"conflicting evidence digests: {reference['path']}")
        self.references[reference["path"]] = reference
        return reference

    def validate(self) -> None:
        for reference in self.references.values():
            policy.reference(reference)


class TargetIndex:
    def __init__(self, roots: list[Path]):
        self.parts = sorted(root.parts for root in roots)
        for previous, current in zip(self.parts, self.parts[1:]):
            if current[:len(previous)] == previous:
                fail("overlapping cleanup targets are not permitted")

    def contains(self, path: Path) -> bool:
        parts = path.parts
        index = bisect_right(self.parts, parts) - 1
        return index >= 0 and parts[:len(self.parts[index])] == self.parts[index]


def require_target_limit(count: int) -> None:
    if count > MAX_TARGETS:
        fail(f"supported target limit is {MAX_TARGETS}; narrow the reviewed inventory")


def encode_manifest(manifest: dict) -> bytes:
    encoded = bytearray()
    encoder = json.JSONEncoder(sort_keys=True, indent=2, allow_nan=False)
    for chunk in encoder.iterencode(manifest):
        data = chunk.encode("utf-8")
        if len(encoded) + len(data) + 1 > policy.MAX_DOCUMENT_BYTES:
            fail("manifest exceeds the 4 MiB document limit; no output or automatic splitting")
        encoded.extend(data)
    encoded.extend(b"\n")
    return bytes(encoded)


def path_within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def derived_data_root() -> Path:
    override = os.environ.get("APPLE_BUILD_CLEANUP_DERIVED_DATA_ROOT")
    if override:
        if os.environ.get("APPLE_BUILD_INTERLOCK_TESTING") != "1":
            fail("DerivedData root override is test-only")
        return policy.physical_path(override)
    return policy.physical_path(
        str(lease.paths()["home"] / "Library/Developer/Xcode/DerivedData")
    )


def validate_target_location(kind: str, path: Path, worktree: Path) -> None:
    if kind not in TARGET_KINDS:
        fail(f"unsupported cleanup target kind: {kind}")
    if path == worktree or path_within(worktree, path):
        fail(f"cleanup target would remove its owner worktree: {path}")
    validate_entry_name(path)
    result = subprocess.run(
        ["git", "-C", str(worktree), "rev-parse", "--show-toplevel"],
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        text=True, capture_output=True, timeout=30, check=False,
    )
    if result.returncode or Path(result.stdout.strip()).resolve() != worktree:
        fail(f"owner must be an existing Git worktree root: {worktree}")
    if kind == "worktree-apple-build":
        if not path_within(path, worktree / ".build"):
            fail(f"worktree build target must be inside the owner's .build directory: {path}")
        tracked = subprocess.run(
            ["git", "-C", str(worktree), "ls-files", "-z", "--",
             ":(literal)" + str(path.relative_to(worktree))],
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
            capture_output=True, timeout=30, check=False,
        )
        if tracked.returncode or tracked.stdout:
            fail(f"tracked files or uninspectable Git state inside cleanup target: {path}")
    else:
        root = derived_data_root()
        if root not in path.parents:
            fail(f"DerivedData target must be inside an app root under {root}: {path}")
        app_root = root / path.relative_to(root).parts[0]
        if app_root.name.endswith(".noindex"):
            fail(f"shared DerivedData cache is not eligible: {path}")
        info = app_root / "info.plist"
        if not info.is_file() or info.is_symlink():
            fail(f"DerivedData target lacks a regular info.plist: {path}")
        try:
            document = plistlib.loads(policy.read_bytes(info, private=False))
        except (OSError, plistlib.InvalidFileException) as exc:
            fail(f"cannot read DerivedData workspace identity {info}: {exc}")
        if not isinstance(document, dict):
            fail(f"DerivedData workspace identity must be a dictionary: {info}")
        workspace = document.get("WorkspacePath")
        if not isinstance(workspace, str) or not workspace:
            fail(f"DerivedData target has no WorkspacePath: {path}")
        workspace_path = Path(workspace).resolve(strict=False)
        if not Path(workspace).is_absolute() or Path(workspace) != workspace_path:
            fail(f"DerivedData WorkspacePath must be absolute and physical: {info}")
        if not path_within(workspace_path, worktree):
            fail(
                f"DerivedData workspace is outside its released owner worktree: "
                f"{workspace_path}"
            )


def validate_entry_name(relative: Path) -> None:
    parts = tuple(relative.parts)
    lower_parts = tuple(part.lower() for part in parts)
    for part in lower_parts:
        if part in PROTECTED_COMPONENTS:
            fail(f"protected artifact is inside cleanup target: {relative}")
        if any(part.endswith(suffix) for suffix in PROTECTED_SUFFIXES):
            fail(f"protected release artifact is inside cleanup target: {relative}")


def entry_record(root: Path, path: Path, st: os.stat_result) -> dict[str, Any]:
    relative = Path(".") if path == root else path.relative_to(root)
    validate_entry_name(relative)
    if stat.S_ISDIR(st.st_mode):
        kind = "directory"
    elif stat.S_ISREG(st.st_mode):
        kind = "file"
    else:
        fail(f"symlink or special filesystem entry is not eligible: {path}")
    lease._check_owned(st, str(path))
    if stat.S_IMODE(st.st_mode) & 0o022:
        fail(f"group/world writable entry is not eligible: {path}")
    if kind == "file" and st.st_nlink != 1:
        fail(f"hard-linked file is not eligible: {path}")
    if kind == "file" and path.suffix.lower() not in GENERATED_SUFFIXES:
        fail(f"file is not a recognized disposable compiler output: {path}")
    birth_ns = int(getattr(st, "st_birthtime", st.st_mtime) * 1_000_000_000)
    record = {
        "relative": relative.as_posix(),
        "kind": kind,
        "mode": stat.S_IMODE(st.st_mode),
        "device": st.st_dev,
        "inode": st.st_ino,
        "links": st.st_nlink,
        "uid": st.st_uid,
        "size": st.st_size,
        "blocks": getattr(st, "st_blocks", 0),
        "mtime_ns": st.st_mtime_ns,
        "ctime_ns": st.st_ctime_ns,
        "birthtime_ns": birth_ns,
    }
    return record


@contextlib.contextmanager
def directory_fd(path: Path):
    """Open every ancestor without following links, including the target."""
    if not path.is_absolute() or ".." in path.parts:
        fail(f"directory must be an absolute physical path: {path}")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def bounded_names(fd: int, limit: int, error: str) -> list[str]:
    names = []
    with os.scandir(fd) as children:
        for child in children:
            if len(names) >= limit:
                fail(error)
            names.append(child.name)
    return sorted(names)


def scan_tree(
    root: Path,
    *,
    minimum_seconds: int,
    current_time: dt.datetime | None = None,
    maximum_entries: int = MAX_TREE_ENTRIES,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    minimum_seconds = integer(
        minimum_seconds, "minimum retention seconds", minimum=MINIMUM_RETENTION_SECONDS
    )
    root = policy.physical_path(str(root))
    records: list[dict[str, Any]] = []
    maximum_entries = min(maximum_entries, MAX_TREE_ENTRIES)

    def append(record: dict) -> None:
        if len(records) >= maximum_entries:
            fail(f"supported aggregate entry limit is {MAX_TREE_ENTRIES}; narrow the inventory")
        records.append(record)

    def walk(path: Path, fd: int) -> None:
        before = entry_record(root, path, os.fstat(fd))
        append(before)
        names = bounded_names(
            fd, maximum_entries - len(records),
            f"supported aggregate entry limit is {MAX_TREE_ENTRIES}; narrow the inventory",
        )
        for name in names:
            child = path / name
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if st.st_dev != records[0]["device"]:
                fail(f"nested filesystem is not eligible: {child}")
            record = entry_record(root, child, st)
            if record["kind"] == "directory":
                child_fd = os.open(
                    name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
                )
                try:
                    if entry_record(root, child, os.fstat(child_fd)) != record:
                        fail(f"directory changed during inventory: {child}")
                    walk(child, child_fd)
                finally:
                    os.close(child_fd)
            else:
                append(record)
        if entry_record(root, path, os.fstat(fd)) != before:
            fail(f"cleanup target changed during inventory: {path}")

    with directory_fd(root.parent) as parent_fd:
        root_st = os.stat(root.name, dir_fd=parent_fd, follow_symlinks=False)
        first = entry_record(root, root, root_st)
        if first["kind"] == "file":
            append(first)
        else:
            fd = os.open(
                root.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd,
            )
            try:
                if entry_record(root, root, os.fstat(fd)) != first:
                    fail(f"cleanup target changed during inventory: {root}")
                walk(root, fd)
            finally:
                os.close(fd)
        if entry_record(
            root, root, os.stat(root.name, dir_fd=parent_fd, follow_symlinks=False)
        ) != first:
            fail(f"cleanup target changed during inventory: {root}")

    youngest_ns = max(
        max(item["birthtime_ns"], item["mtime_ns"], item["ctime_ns"])
        for item in records
    )
    current_time = current_time or now_utc()
    cutoff_ns = int(current_time.timestamp() * 1_000_000_000) - (
        minimum_seconds * 1_000_000_000
    )
    if youngest_ns > cutoff_ns:
        youngest = dt.datetime.fromtimestamp(
            youngest_ns / 1_000_000_000, tz=dt.timezone.utc
        )
        fail(
            f"cleanup target has entries newer than the {minimum_seconds // 3600}h "
            f"whole-tree retention: {root} (youngest {utc(youngest)})"
        )

    encoded = policy.canonical(records)
    tree = {
        "sha256": hashlib.sha256(encoded).hexdigest(),
        "entries": len(records),
        "allocated_bytes": sum(item["blocks"] * 512 for item in records),
        "apparent_bytes": sum(item["size"] for item in records),
    }
    youngest = dt.datetime.fromtimestamp(
        youngest_ns / 1_000_000_000, tz=dt.timezone.utc
    )
    return {
        "root": {"device": root_st.st_dev, "inode": root_st.st_ino},
        "retention": {
            "minimum_seconds": minimum_seconds,
            "youngest_entry_at": utc(youngest),
        },
        "tree": tree,
    }, records


def parse_release_record(
    path: Path,
    *,
    minimum_seconds: int,
    current_time: dt.datetime | None = None,
    references: ReferenceIndex | None = None,
) -> tuple[dict[str, Any], bytes]:
    record, data = read_private_document(path)
    policy.exact(record, RELEASE_KEYS, "owner release record")
    if type(record["schema"]) is not int or record["schema"] != SCHEMA:
        fail("unsupported owner release record schema")
    if record["scope"] != SCOPE:
        fail("owner release record has the wrong scope")
    owner = policy.text(record["owner"], "owner")
    session_id = lease.validate_uuid(record["session_id"], "owner session id")
    released_at = policy.timestamp(record["released_at"])
    current_time = current_time or now_utc()
    if released_at > current_time - dt.timedelta(seconds=minimum_seconds):
        fail("owner release record has not completed the minimum retention period")
    worktree = validate_identity(record["worktree"], "owner worktree identity")
    if not stat.S_ISDIR(Path(worktree["path"]).lstat().st_mode):
        fail("owner worktree identity is not a directory")

    evidence = record["evidence"]
    if not isinstance(evidence, list) or not evidence:
        fail("owner release record requires durable evidence")
    own_references = references is None
    references = references if references is not None else ReferenceIndex()
    checked_evidence = [references.add(item, "release evidence") for item in evidence]

    targets = record["targets"]
    if not isinstance(targets, list) or not targets:
        fail("owner release record requires at least one exact target")
    require_target_limit(len(targets))
    checked_targets: list[dict[str, Any]] = []
    seen = set()
    for target in targets:
        policy.exact(target, {"identity", "kind"}, "released target")
        kind = policy.text(target["kind"], "released target kind")
        target_identity = validate_identity(target["identity"], "released root identity")
        target_path = Path(target_identity["path"])
        if str(target_path) in seen:
            fail(f"duplicate released target: {target_path}")
        seen.add(str(target_path))
        validate_target_location(kind, target_path, Path(worktree["path"]))
        checked_targets.append({"identity": target_identity, "kind": kind})
    target_index = TargetIndex([Path(target["identity"]["path"]) for target in checked_targets])
    for evidence_path in {Path(item["path"]) for item in checked_evidence} | {path}:
        if target_index.contains(evidence_path):
            fail(f"release evidence is inside the deletion target: {evidence_path}")
    if own_references:
        references.validate()
    return {
        "schema": SCHEMA,
        "scope": SCOPE,
        "owner": owner,
        "session_id": session_id,
        "released_at": utc(released_at),
        "worktree": worktree,
        "evidence": checked_evidence,
        "targets": checked_targets,
    }, data


class ReleaseIndex:
    """One parse per release per inspection, followed by fresh digest validation."""

    def __init__(self, current_time: dt.datetime):
        self.current_time = current_time
        self.references = ReferenceIndex()
        self.records: dict[Path, tuple[dict, dict[str, dict], dict[str, str]]] = {}

    def get(self, path: Path, minimum_seconds: int, expected: dict | None = None):
        path = policy.physical_path(str(path))
        if path not in self.records:
            record, data = parse_release_record(
                path, minimum_seconds=MINIMUM_RETENTION_SECONDS,
                current_time=self.current_time, references=self.references,
            )
            reference = self.references.add(reference_for(path, data), "owner release record")
            by_path = {target["identity"]["path"]: target for target in record["targets"]}
            self.records[path] = record, by_path, reference
        record, by_path, reference = self.records[path]
        if expected is not None and reference != expected:
            fail(f"missing or changed evidence: {path}")
        if policy.timestamp(record["released_at"]) > self.current_time - dt.timedelta(seconds=minimum_seconds):
            fail("owner release record has not completed the minimum retention period")
        return record, by_path, reference


def inventory(
    release_records: list[Path],
    *,
    minimum_seconds: int = MINIMUM_RETENTION_SECONDS,
    current_time: dt.datetime | None = None,
) -> dict[str, Any]:
    if not release_records:
        fail("inventory requires at least one owner release record")
    require_target_limit(len(release_records))
    minimum_seconds = integer(
        minimum_seconds, "minimum retention seconds", minimum=MINIMUM_RETENTION_SECONDS
    )
    current_time = current_time or now_utc()
    targets: list[dict[str, Any]] = []
    seen = set()
    releases = ReleaseIndex(current_time)
    for release_path in release_records:
        release, _, reference = releases.get(release_path, minimum_seconds)
        require_target_limit(len(targets) + len(release["targets"]))
        for released in release["targets"]:
            target_path = Path(released["identity"]["path"])
            if str(target_path) in seen:
                fail(f"target appears in more than one release record: {target_path}")
            seen.add(str(target_path))
            targets.append(
                {
                    "kind": released["kind"],
                    "path": str(target_path),
                    "owner": release["owner"],
                    "session_id": release["session_id"],
                    "worktree": release["worktree"],
                    "released_at": release["released_at"],
                    "release_record": reference,
                    "release_evidence": release["evidence"],
                    "observed_at": utc(current_time),
                }
            )
    validate_disjoint_targets(targets)
    remaining = MAX_TREE_ENTRIES
    for target in targets:
        scanned, _ = scan_tree(
            Path(target["path"]), minimum_seconds=minimum_seconds,
            current_time=current_time, maximum_entries=remaining,
        )
        remaining -= scanned["tree"]["entries"]
        target.update(scanned)
    releases.references.validate()
    manifest = {"schema": SCHEMA, "scope": SCOPE, "targets": targets}
    encode_manifest(manifest)
    return manifest


def validate_manifest_target(
    value: Any,
    *,
    manifest_path: Path,
    current_time: dt.datetime,
    releases: ReleaseIndex | None = None,
    maximum_entries: int = MAX_TREE_ENTRIES,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    target = policy.exact(value, TARGET_KEYS, "cleanup manifest target")
    kind = policy.text(target["kind"], "target kind")
    target_path = policy.physical_path(target["path"])
    owner = policy.text(target["owner"], "target owner")
    session_id = lease.validate_uuid(target["session_id"], "target owner session id")
    worktree = validate_identity(target["worktree"], "target worktree identity")
    released_at = policy.timestamp(target["released_at"])
    observed_at = policy.timestamp(target["observed_at"])
    if observed_at > current_time or observed_at < released_at:
        fail("manifest observation time must be after owner release and not in the future")
    own_releases = releases is None
    releases = releases if releases is not None else ReleaseIndex(current_time)
    release_record = releases.references.add(target["release_record"], "owner release record")
    evidence = target["release_evidence"]
    if not isinstance(evidence, list) or not evidence:
        fail("manifest target requires release evidence")
    checked_evidence = [
        releases.references.add(item, "manifest release evidence") for item in evidence
    ]
    retention = policy.exact(target["retention"], RETENTION_KEYS, "target retention")
    minimum_seconds = integer(
        retention["minimum_seconds"],
        "target minimum retention",
        minimum=MINIMUM_RETENTION_SECONDS,
    )
    policy.timestamp(retention["youngest_entry_at"])
    root = policy.exact(target["root"], {"device", "inode"}, "target root identity")
    checked_root = {
        "device": integer(root["device"], "target root device"),
        "inode": integer(root["inode"], "target root inode"),
    }
    tree = policy.exact(target["tree"], TREE_KEYS, "target tree")
    checked_tree = {
        "sha256": policy.sha(tree["sha256"]),
        "entries": integer(tree["entries"], "target entry count", minimum=1),
        "allocated_bytes": integer(tree["allocated_bytes"], "target allocated bytes"),
        "apparent_bytes": integer(tree["apparent_bytes"], "target apparent bytes"),
    }

    release, released_targets, _ = releases.get(
        Path(release_record["path"]), minimum_seconds, expected=release_record,
    )
    expected_release_target = {
        "identity": {"path": str(target_path), **checked_root}, "kind": kind
    }
    if released_targets.get(str(target_path)) != expected_release_target:
        fail(f"manifest target is not owner-released: {target_path}")
    if (
        owner != release["owner"]
        or session_id != release["session_id"]
        or worktree != release["worktree"]
        or utc(released_at) != release["released_at"]
        or checked_evidence != release["evidence"]
    ):
        fail(f"manifest target differs from its owner release record: {target_path}")
    validate_target_location(kind, target_path, Path(worktree["path"]))
    if path_within(manifest_path, target_path):
        fail(f"cleanup manifest is inside its deletion target: {manifest_path}")

    scanned, entries = scan_tree(
        target_path,
        minimum_seconds=minimum_seconds,
        current_time=current_time,
        maximum_entries=maximum_entries,
    )
    if (
        scanned["root"] != checked_root
        or scanned["retention"] != retention
        or scanned["tree"] != checked_tree
    ):
        fail(f"cleanup target changed since inventory: {target_path}")
    if own_releases:
        releases.references.validate()
    return {
        "kind": kind,
        "path": str(target_path),
        "owner": owner,
        "session_id": session_id,
        "worktree": worktree,
        "released_at": utc(released_at),
        "release_record": release_record,
        "release_evidence": checked_evidence,
        "observed_at": target["observed_at"],
        "retention": retention,
        "root": checked_root,
        "tree": checked_tree,
    }, entries


def validate_manifest(
    manifest_path: Path,
    *,
    current_time: dt.datetime | None = None,
) -> tuple[dict[str, Any], bytes, dict[str, list[dict[str, Any]]]]:
    manifest_path = policy.physical_path(str(manifest_path))
    manifest, data = read_private_document(manifest_path)
    policy.exact(manifest, {"schema", "scope", "targets"}, "cleanup manifest")
    if type(manifest["schema"]) is not int or manifest["schema"] != SCHEMA:
        fail("unsupported cleanup manifest schema")
    if manifest["scope"] != SCOPE:
        fail("cleanup manifest has the wrong scope")
    targets = manifest["targets"]
    if not isinstance(targets, list) or not targets:
        fail("cleanup manifest requires at least one exact target")
    require_target_limit(len(targets))
    declared_entries = 0
    for target in targets:
        policy.exact(target, TARGET_KEYS, "cleanup manifest target")
        tree = policy.exact(target["tree"], TREE_KEYS, "target tree")
        declared_entries += integer(tree["entries"], "target entry count", minimum=1)
        if declared_entries > MAX_TREE_ENTRIES:
            fail(f"supported aggregate entry limit is {MAX_TREE_ENTRIES}; narrow the manifest")
    current_time = current_time or now_utc()
    releases = ReleaseIndex(current_time)
    checked_targets = []
    entries_by_path: dict[str, list[dict[str, Any]]] = {}
    seen = set()
    remaining = MAX_TREE_ENTRIES
    for item in targets:
        checked, entries = validate_manifest_target(
            item, manifest_path=manifest_path, current_time=current_time,
            releases=releases, maximum_entries=remaining,
        )
        remaining -= len(entries)
        if checked["path"] in seen:
            fail(f"duplicate cleanup manifest target: {checked['path']}")
        seen.add(checked["path"])
        checked_targets.append(checked)
        entries_by_path[checked["path"]] = entries
    validate_disjoint_targets(checked_targets)
    releases.references.validate()
    return manifest, data, entries_by_path


def validate_disjoint_targets(targets: list[dict[str, Any]]) -> None:
    index = TargetIndex([Path(target["path"]) for target in targets])
    references = {
        Path(ref["path"]) for target in targets
        for ref in [target["release_record"], *target["release_evidence"]]
    }
    for path in references:
        if index.contains(path):
            fail("release evidence cannot be inside any cleanup target")


class PinnedManifest:
    def __init__(self, path: Path, expected_data: bytes):
        self.path = path
        with directory_fd(path.parent) as parent_fd:
            self.fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            self.baseline = lease.validate_fd_path(self.fd, path, private=True)
            if policy.read_bytes(path, private=True) != expected_data:
                fail("cleanup manifest changed before it could be pinned")
            self.validate()
        except BaseException:
            self.close()
            raise

    def validate(self) -> None:
        policy.physical_path(str(self.path))
        current = lease.validate_fd_path(self.fd, self.path, private=True)
        if (
            current.st_size,
            current.st_mtime_ns,
            current.st_ctime_ns,
        ) != (
            self.baseline.st_size,
            self.baseline.st_mtime_ns,
            self.baseline.st_ctime_ns,
        ):
            fail("cleanup manifest changed during deletion")

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1


class DurableJournal:
    def __init__(self, path: Path, header: dict[str, Any]):
        self.path = path
        parent = secure_parent(path)
        self.parent_context = directory_fd(parent)
        self.parent_fd = self.parent_context.__enter__()
        self.fd = -1
        try:
            self.fd = os.open(
                path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600, dir_fd=self.parent_fd,
            )
            os.fsync(self.parent_fd)
            self.append({"event": "started", **header})
        except BaseException:
            self.close()
            raise

    def append(self, value: dict[str, Any]) -> None:
        policy.physical_path(str(self.path))
        if identity_stat(self.path.parent.stat()) != identity_stat(os.fstat(self.parent_fd)):
            fail("deletion journal parent changed")
        if lease.validate_fd_path(self.fd, self.path, private=True).st_nlink != 1:
            fail("deletion journal gained a hard link")
        encoded = (json.dumps(value, sort_keys=True) + "\n").encode("utf-8")
        write_all(self.fd, encoded)
        os.fsync(self.fd)
        if sys.platform == "darwin":
            lease.fcntl.fcntl(self.fd, lease.fcntl.F_FULLFSYNC)

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1
        self.parent_context.__exit__(None, None, None)


def open_file_inventory(
    ignored_fds: frozenset[int] = frozenset(),
) -> tuple[tuple[str, ...], frozenset[tuple[int, int]]]:
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-F0pftDin"],
        text=True,
        capture_output=True,
        timeout=120,
        check=False,
    )
    if result.returncode != 0 or result.stderr.strip():
        fail(
            f"open-file inventory failed: exit={result.returncode} "
            f"stderr={result.stderr.strip()!r}"
        )
    if "\0" not in result.stdout:
        fail("open-file inventory returned no usable process records")
    paths: list[str] = []
    identities: set[tuple[int, int]] = set()
    device: int | None = None
    inode: int | None = None
    file_type = ""
    pid = None
    ignored = False
    in_file = False
    def finish_record():
        if in_file and not ignored and not file_type:
            fail("open-file inventory has an incomplete file type")
        if not ignored and file_type in {"REG", "DIR", "VREG", "VDIR"}:
            if device is None or inode is None:
                fail("open-file inventory has incomplete regular-file inode data")
            identities.add((device, inode))
    for field in result.stdout.split("\0"):
        line = field.lstrip("\n")
        if not line:
            continue
        if line.startswith("p"):
            finish_record()
            if not line[1:].isdigit():
                fail("open-file inventory has an invalid PID")
            pid = int(line[1:])
            device = None
            inode = None
            file_type = ""
            in_file = False
            ignored = False
        elif line.startswith("f"):
            finish_record()
            if pid is None:
                fail("open-file inventory has an orphan file record")
            device = None
            inode = None
            file_type = ""
            in_file = True
            ignored = (
                pid == os.getpid() and line[1:].isdigit()
                and int(line[1:]) in ignored_fds
            )
        elif line.startswith("t"):
            file_type = line[1:]
        elif not ignored and line.startswith("D"):
            try:
                device = int(line[1:], 16)
            except ValueError:
                fail(f"open-file inventory has an invalid device field: {line}")
        elif not ignored and line.startswith("i"):
            try:
                inode = int(line[1:])
            except ValueError:
                fail(f"open-file inventory has an invalid inode field: {line}")
        elif not ignored and line.startswith("n/"):
            paths.append(line[1:])
    finish_record()
    if not paths or not identities:
        fail("open-file inventory returned no usable paths or inode identities")
    return tuple(paths), frozenset(identities)


def entry_is_open(
    path: Path,
    entry: dict[str, Any],
    opened: tuple[tuple[str, ...], frozenset[tuple[int, int]]],
) -> bool:
    paths, identities = opened
    text = str(path)
    prefix = text + "/"
    if any(name == text or (entry["kind"] == "directory" and name.startswith(prefix)) for name in paths):
        return True
    return (entry["device"], entry["inode"]) in identities


def require_no_build_activity() -> None:
    guard = Path(__file__).with_name("apple-build-guard.sh")
    result = subprocess.run(
        ["/bin/bash", "-c", 'source "$1" && apple_build_activity', "_", str(guard)],
        text=True, capture_output=True, timeout=30, check=False,
    )
    if result.returncode or result.stderr.strip() or result.stdout.strip():
        fail("active Apple build process or failed process inspection prevents cleanup")


def validate_runtime_scope(package: dict, manifest: dict) -> None:
    target_index = TargetIndex([Path(target["path"]) for target in manifest["targets"]])
    cohorts = {item["name"]: item["roots"] for item in package["cohorts"]}
    app_roots = {
        root["identity"]["path"]
        for name, roots in cohorts.items()
        if name not in {"global-cleanup-entrypoints", "manual-xcode-writers-disabled-or-wrapped"}
        for root in roots
    }
    if any(target["worktree"]["path"] not in app_roots for target in manifest["targets"]):
        fail("target owner worktree is outside the approved writer coverage")
    bundle = Path(__file__).resolve().parents[2]
    required = {
        str(bundle / path) for path in (
            *policy.PROTOCOL_FILES, "tools/apple-build-cleanup.py",
            "tools/lib/apple_build_cleanup.py", "tools/lib/apple_maintenance_policy.py",
            "tools/lib/apple-build-guard.sh",
        )
    }
    covered = {
        ref["path"] for root in cohorts["global-cleanup-entrypoints"]
        for ref in root["writers"]
    }
    if not required <= covered:
        fail("executing cleanup bundle is not fully fingerprinted in the approved entrypoints")
    for name, sha in policy.PROTOCOL_FILES.items():
        if policy.digest(policy.read_bytes(bundle / name, private=False)) != sha:
            fail("cleanup bundle does not use the frozen v1 lease protocol")
    # Approval/attestation files and all nested evidence must survive deletion.
    def inspect(value):
        if isinstance(value, dict):
            if set(value) == {"path", "sha256"}:
                path = Path(value["path"])
                if target_index.contains(path):
                    fail("approved evidence or writer source is inside a cleanup target")
            for child in value.values():
                inspect(child)
        elif isinstance(value, list):
            for child in value:
                inspect(child)
    inspect(package)
    approval = policy.document(policy.reference(package["approval"]))
    inspect(approval)
    for ref in approval["attestations"]:
        inspect(policy.document(policy.reference(ref)))


class RuntimeGuard:
    def __init__(self, manifest: dict, pinned: PinnedManifest, window_id: str, clock):
        self.manifest = manifest
        self.pinned = pinned
        self.window_id = window_id
        self.clock = clock
        self.authorization = policy.check(pinned.path, window_id)
        self.expires_at = policy.timestamp(self.authorization["expires_at"])
        self.deadline = time.monotonic() + (self.expires_at - clock()).total_seconds()
        self.last_time = clock()
        self.scope_validated = False
        self.references = ReferenceIndex()
        for target in manifest["targets"]:
            for reference in [target["release_record"], *target["release_evidence"]]:
                self.references.add(reference, "owner release evidence")

    def deadline_check(self) -> None:
        now = self.clock()
        if now < self.last_time or now >= self.expires_at or time.monotonic() >= self.deadline:
            fail("approved maintenance window expired or clock moved backwards")
        self.last_time = now

    def validate_scope(self, package: dict) -> None:
        validate_runtime_scope(package, self.manifest)

    def validate_owner(self, target: dict) -> None:
        validate_identity(target["worktree"], "owner worktree identity")
        validate_target_location(
            target["kind"], Path(target["path"]), Path(target["worktree"]["path"])
        )

    def check(self, target: dict | None = None) -> None:
        self.deadline_check()
        self.pinned.validate()
        if policy.check(self.pinned.path, self.window_id) != self.authorization:
            fail("maintenance-window authorization changed during deletion")
        exclusive = policy.inherited_exclusive()
        records = lease.scan_records()
        if len(records) != 1 or records[0]["lease_id"] != exclusive.lease_id:
            fail("additional unresolved lease record prevents cleanup")
        # validate_existing authenticates descriptors; independently ensure the
        # coordination file still has an exclusive kernel lock, not just a record.
        probe = os.open(lease.paths()["lock"], os.O_RDONLY | os.O_NOFOLLOW)
        try:
            try:
                lease.fcntl.flock(probe, lease.fcntl.LOCK_SH | lease.fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                fail("exclusive kernel lock is not held")
        finally:
            os.close(probe)
        companion = lease.paths()["root"] / policy.POLICY_NAME
        data = policy.read_bytes(companion, private=True)
        if policy.digest(data) != self.authorization["policy_sha256"]:
            fail("maintenance-window companion changed during deletion")
        # Only structural relationships are reused. Both documents remain pinned
        # to the original authorization, and policy.check rereads all mutable
        # policy/attestation/writer/registry inputs on EVERY call.
        if not self.scope_validated:
            self.validate_scope(policy.document(data))
            self.scope_validated = True
        self.references.validate()
        if target is not None:
            self.validate_owner(target)
        require_no_build_activity()
        self.pinned.validate()
        self.deadline_check()


class TargetRemoval:
    def __init__(self, target: dict, entries: list[dict], guard, journal, opened):
        self.target = target
        self.root = Path(target["path"])
        self.guard, self.journal, self.opened = guard, journal, opened
        self.expected = {item["relative"]: dict(item) for item in entries}
        self.children: dict[Path, list[str]] = {}
        for relative in self.expected:
            if relative != ".":
                path = self.root / relative
                self.children.setdefault(path.parent, []).append(path.name)
        for children in self.children.values():
            children.sort()
        self.directories: dict[Path, int] = {}
        self.removed = 0

    def compare(self, path: Path, parent_fd: int) -> dict:
        actual = entry_record(
            self.root, path, os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        )
        if actual != self.expected[str(path.relative_to(self.root))]:
            fail(f"cleanup target entry changed before removal: {path}")
        return actual

    def check_ancestors(self) -> None:
        for path, fd in self.directories.items():
            with directory_fd(path) as current:
                if identity_stat(os.fstat(current)) != identity_stat(os.fstat(fd)):
                    fail(f"cleanup ancestor identity changed: {path}")
            if path_within(path, self.root):
                actual = entry_record(self.root, path, os.fstat(fd))
                if actual != self.expected[str(path.relative_to(self.root))]:
                    fail(f"cleanup directory changed before removal: {path}")

    def remove(self, path: Path, parent_fd: int) -> None:
        expected = self.compare(path, parent_fd)
        if expected["kind"] == "directory":
            fd = os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
            self.directories[path] = fd
            try:
                self.check_ancestors()
                intended = self.children.get(path, [])
                names = bounded_names(
                    fd, len(intended), f"cleanup directory entries changed: {path}",
                )
                if names != intended:
                    fail(f"cleanup directory entries changed: {path}")
                for name in names:
                    self.remove(path / name, fd)
                with os.scandir(fd) as remaining:
                    if next(remaining, None) is not None:
                        fail(f"cleanup directory gained entries: {path}")
            finally:
                del self.directories[path]
                os.close(fd)

        self.guard.check(self.target)
        self.check_ancestors()
        expected = self.compare(path, parent_fd)
        opened = self.opened(frozenset(self.directories.values()))
        if entry_is_open(path, expected, opened):
            fail(f"open path or inode prevents cleanup: {path}")
        event = {
            "path": str(path), "kind": expected["kind"],
            "device": expected["device"], "inode": expected["inode"],
        }
        self.journal.append({"event": "remove-intent", **event, "at": utc(self.guard.clock())})
        # Recheck authorization after the potentially slow open-file scan/fsync.
        self.check_ancestors()
        self.compare(path, parent_fd)
        if entry_is_open(path, expected, self.opened(frozenset(self.directories.values()))):
            fail(f"open path or inode prevents cleanup: {path}")
        self.guard.check(self.target)
        self.check_ancestors()
        self.compare(path, parent_fd)
        self.guard.deadline_check()
        if expected["kind"] == "directory":
            os.rmdir(path.name, dir_fd=parent_fd)
        else:
            os.unlink(path.name, dir_fd=parent_fd)
        self.removed += 1
        os.fsync(parent_fd)
        self.journal.append({"event": "removed", **event, "at": utc(self.guard.clock())})
        if path.parent != self.root.parent:
            self.expected[str(path.parent.relative_to(self.root))] = entry_record(
                self.root, path.parent, os.fstat(parent_fd)
            )

    def run(self) -> None:
        with directory_fd(self.root.parent) as fd:
            self.directories[self.root.parent] = fd
            try:
                self.remove(self.root, fd)
            finally:
                self.directories.clear()


def identity_stat(st) -> tuple[int, int]:
    return st.st_dev, st.st_ino


@contextlib.contextmanager
def cancellation_signals():
    def cancelled(number, _frame):
        fail(f"cleanup interrupted by signal {number}")
    previous = {}
    try:
        for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            previous[number] = signal.signal(number, cancelled)
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def apply_manifest(
    manifest_path: Path,
    *,
    window_id: str,
    journal_path: Path,
    current_time: dt.datetime | None = None,
    clock: Callable[[], dt.datetime] = now_utc,
    open_inventory: Callable = open_file_inventory,
) -> dict[str, Any]:
    controls = lease.paths()["root"] / OPERATIONAL_CONTROLS_NAME
    if controls.exists() or controls.is_symlink():
        fail("operational controls are installed; use an explicitly approved v2 campaign unit")
    current_time = current_time or now_utc()
    manifest, manifest_data, entries_by_path = validate_manifest(
        manifest_path, current_time=current_time
    )
    secure_parent(journal_path)
    for target in manifest["targets"]:
        if path_within(journal_path, Path(target["path"])) or path_within(
            journal_path, Path(target["worktree"]["path"])
        ):
            fail("deletion journal must be outside cleanup targets and owner worktrees")

    with contextlib.ExitStack() as stack:
        pinned = PinnedManifest(manifest_path, manifest_data)
        stack.callback(pinned.close)
        guard = RuntimeGuard(manifest, pinned, window_id, clock)
        guard.check()
        manifest_sha = policy.digest(policy.canonical(manifest))
        journal = DurableJournal(
            journal_path,
            {
                "schema": SCHEMA, "scope": SCOPE, "window_id": window_id,
                "manifest_sha256": manifest_sha,
                "policy_sha256": guard.authorization["policy_sha256"],
                "started_at": utc(clock()), "manifest": manifest,
            },
        )
        stack.callback(journal.close)
        stack.enter_context(cancellation_signals())
        removals = []
        try:
            for target in manifest["targets"]:
                root = Path(target["path"])
                # Revalidate the complete tree immediately before touching it.
                scanned, _ = scan_tree(
                    root, minimum_seconds=target["retention"]["minimum_seconds"],
                    current_time=clock(),
                    maximum_entries=target["tree"]["entries"],
                )
                if any(scanned[key] != target[key] for key in ("root", "retention", "tree")):
                    fail(f"cleanup target changed since inventory: {root}")
                opened = open_inventory()
                for entry in entries_by_path[str(root)]:
                    if entry_is_open(root / entry["relative"], entry, opened):
                        fail(f"open path or inode prevents cleanup: {root}")
                removal = TargetRemoval(
                    target, entries_by_path[str(root)], guard, journal, open_inventory
                )
                removals.append(removal)
                removal.run()
            removed = sum(item.removed for item in removals)
            journal.append({"event": "completed", "at": utc(clock()), "removed": removed})
            return {
                "window_id": window_id, "manifest_sha256": manifest_sha,
                "journal": str(journal_path), "removed": removed,
            }
        except BaseException as exc:
            try:
                journal.append(
                    {
                        "event": "stopped", "at": utc(clock()),
                        "removed": sum(item.removed for item in removals),
                        "error": f"{type(exc).__name__}: {exc}",
                    }
                )
            except (OSError, lease.LeaseError) as journal_error:
                raise journal_error from exc
            raise


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)

    inventory_parser = commands.add_parser(
        "inventory", help="Create an exact manifest from owner release records."
    )
    inventory_parser.add_argument(
        "--release-record", type=Path, action="append", required=True
    )
    inventory_parser.add_argument("--output", type=Path)
    inventory_parser.add_argument(
        "--minimum-age-hours", type=int, default=MINIMUM_RETENTION_SECONDS // 3600
    )

    validate_parser = commands.add_parser(
        "validate", help="Revalidate an exact manifest without deleting."
    )
    validate_parser.add_argument("--manifest", type=Path, required=True)

    apply_parser = commands.add_parser(
        "apply", help="Delete only an authorized exact manifest."
    )
    apply_parser.add_argument("--manifest", type=Path, required=True)
    apply_parser.add_argument("--window-id", required=True)
    apply_parser.add_argument("--journal", type=Path, required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "inventory":
            manifest = inventory(
                args.release_record,
                minimum_seconds=args.minimum_age_hours * 3600,
            )
            encoded = encode_manifest(manifest)
            if args.output:
                if any(
                    path_within(args.output, Path(t["path"]))
                    or path_within(args.output, Path(t["worktree"]["path"]))
                    for t in manifest["targets"]
                ):
                    fail("inventory output must be outside cleanup targets and owner worktrees")
                write_private_new(args.output, encoded)
                result: Any = {
                    "manifest": str(args.output),
                    "targets": len(manifest["targets"]),
                    "allocated_bytes": sum(
                        item["tree"]["allocated_bytes"] for item in manifest["targets"]
                    ),
                }
            else:
                sys.stdout.write(encoded.decode("utf-8"))
                return 0
        elif args.command == "validate":
            manifest, data, _ = validate_manifest(args.manifest)
            result = {
                "manifest_sha256": policy.digest(policy.canonical(manifest)),
                "targets": len(manifest["targets"]),
                "allocated_bytes": sum(
                    item["tree"]["allocated_bytes"] for item in manifest["targets"]
                ),
            }
        else:
            result = apply_manifest(
                args.manifest,
                window_id=args.window_id,
                journal_path=args.journal,
            )
        print(json.dumps(result, sort_keys=True, indent=2))
        return 0
    except (
        lease.LeaseError, OSError, ValueError, TypeError, KeyError,
        OverflowError, subprocess.SubprocessError,
    ) as exc:
        print(f"apple-build-cleanup: {exc}", file=sys.stderr)
        return 75


if __name__ == "__main__":
    sys.exit(main())
