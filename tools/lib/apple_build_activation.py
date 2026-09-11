#!/usr/bin/env python3
"""A separately approved, crash-fenced activation of an installed exact window.

The genuine frozen shared activation lease survives failures. It is upgraded
to exclusive for this transaction, never fabricated or retired by this module.
Only the frozen whole-lane owner's successful finalization clears that fence.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import os
from pathlib import Path
import time
from typing import Callable

import apple_build_cleanup as cleanup
import apple_build_lease as lease
import apple_maintenance_policy as policy
import apple_build_operations as ops

RECEIPT_NAME = "activation-receipt-v2.json"
ARCHIVE_NAME = "activations-v2"
ACTIVATION_OWNER = "maintenance/activate-installed-window-v2"
INSTALLED_NAMES = (lease.ROLLOUT_NAME, policy.POLICY_NAME, ops.CONTROLS_NAME)
LOCK_NAMES = ("lock", "policy_lock", "registry_lock")
REQUEST_KEYS = {
    "schema", "activation_id", "host", "locks", "observed_at", "expires_at",
    "window_id", "unit_id", "stage", "installed", "manifest", "campaign",
    "suspension", "expected_receipt",
}


def binding(path: Path) -> dict:
    identity = cleanup.identity_document(policy.physical_path(str(path)))
    data = policy.read_bytes(path, private=True)
    if cleanup.identity_document(path) != identity or path.lstat().st_nlink != 1:
        lease.fail("activation input was replaced or hard-linked")
    return {"identity": identity, "sha256": policy.digest(data)}


def bound_bytes(value: dict) -> bytes:
    policy.exact(value, {"identity", "sha256"}, "activation byte/inode binding")
    identity = cleanup.validate_identity(value["identity"], "activation input identity")
    path = Path(identity["path"])
    data = policy.reference({"path": str(path), "sha256": value["sha256"]})
    if cleanup.identity_document(path) != identity or path.lstat().st_nlink != 1:
        lease.fail("activation input changed or gained a hard link")
    return data


def state(path: Path):
    try:
        path.lstat()
    except FileNotFoundError:
        return "absent"
    return binding(path)


def same_state(path: Path, expected) -> None:
    if state(path) != expected:
        lease.fail(f"activation compare-and-swap refused: {path}")


def no_marker(path: Path) -> None:
    try:
        path.lstat()
    except FileNotFoundError:
        return
    lease.fail("suspension reappeared during activation")


def input_documents(request: dict, *, now: dt.datetime, suspended: bool,
                    verify_policy: bool = True) -> tuple[dict, dict]:
    policy.exact(request, REQUEST_KEYS, "activation request")
    ops.v2(request["schema"])
    for name in ("activation_id", "window_id", "unit_id"):
        lease.validate_uuid(policy.text(request[name], name), name)
    p = lease.paths()
    if request["host"] != policy.host_identity():
        lease.fail("activation host identity changed")
    policy.exact(request["locks"], set(LOCK_NAMES), "activation lock identities")
    for name in LOCK_NAMES:
        if cleanup.validate_identity(request["locks"][name], "approved activation lock")["path"] != str(p[name]):
            lease.fail("activation names a different coordination namespace")
    stage = policy.document(bound_bytes(request["stage"]))
    policy.exact(stage, {
        "schema", "host", "prepared_at", "window", "manifest", "controls", "suspension", "expected",
    }, "activation stage")
    ops.v2(stage["schema"])
    if stage["host"] != request["host"]:
        lease.fail("activation stage belongs to a different host")
    policy.exact(stage["expected"], set(INSTALLED_NAMES), "staged installed names")
    observed, end = policy.timestamp(request["observed_at"]), policy.timestamp(request["expires_at"])
    if not policy.timestamp(stage["prepared_at"]) <= observed <= now < end:
        lease.fail("activation observation/window is stale, future or expired")
    policy.exact(request["installed"], set(INSTALLED_NAMES), "installed activation inputs")
    data = {}
    for name, ref in request["installed"].items():
        if ref["identity"]["path"] != str(p["root"] / name):
            lease.fail("activation must bind the actually installed policy files")
        data[name] = bound_bytes(ref)
    if data[lease.ROLLOUT_NAME] != ("\n".join(lease.REQUIRED_ROLLOUT) + "\n").encode():
        lease.fail("installed rollout is not the exact frozen v1 policy")
    for key, name in (("window", policy.POLICY_NAME), ("controls", ops.CONTROLS_NAME)):
        if policy.reference(stage[key]) != data[name]:
            lease.fail("installed policies differ from the approved stage")
    manifest_data = bound_bytes(request["manifest"])
    manifest_path = Path(request["manifest"]["identity"]["path"])
    if stage["manifest"] != {"path": str(manifest_path), "sha256": policy.digest(manifest_data)}:
        lease.fail("activation manifest differs from the installed stage")
    bound_bytes(request["campaign"])
    campaign_path = Path(request["campaign"]["identity"]["path"])
    if verify_policy and ops.campaign(campaign_path, request["unit_id"], now=now) != manifest_path:
        lease.fail("activation campaign does not select the installed exact unit")
    package = policy.document(data[policy.POLICY_NAME])
    manifest = policy.document(manifest_data)
    controls = policy.document(data[ops.CONTROLS_NAME])
    if verify_policy:
        policy.validate_package(package, manifest_path)
    if request["window_id"] != package["window"]["id"] or request["expires_at"] != package["window"]["expires_at"]:
        lease.fail("activation window identity/deadline differs from installed policy")
    if observed < policy.timestamp(package["window"]["not_before"]):
        lease.fail("activation snapshot predates this exact window")
    if verify_policy:
        ops.validate_controls(controls, package, manifest, now=now)
        ops.validate_owner_coverage(package, manifest, now=now)
    suspension = request["suspension"]
    if suspension["identity"]["path"] != str(p["suspend"]) or stage["suspension"] != {
        "path": str(p["suspend"]), "sha256": suspension["sha256"],
    }:
        lease.fail("activation must bind the staged canonical suspension")
    if suspended:
        bound_bytes(suspension)
    else:
        no_marker(p["suspend"])
    index = cleanup.TargetIndex([Path(t["path"]) for t in manifest["targets"]])
    for ref in [request["stage"], request["manifest"], request["campaign"],
                *request["installed"].values()]:
        if index.contains(Path(ref["identity"]["path"])):
            lease.fail("activation authority overlaps a deletion target")
    return manifest, controls


def readiness(request: dict, *, clock: Callable, suspended: bool, opened: Callable) -> tuple[dict, dict]:
    manifest, controls = input_documents(request, now=clock(), suspended=suspended)
    path = Path(request["manifest"]["identity"]["path"])
    _, _, entries = ops.validate_unit(path, now=clock())
    cleanup.require_no_build_activity()
    inventory = opened()
    for target in manifest["targets"]:
        root = Path(target["path"])
        for entry in entries[str(root)]:
            if cleanup.entry_is_open(root / entry["relative"], entry, inventory):
                lease.fail("open target path/inode prevents activation")
    # Probe results are not approval. Recheck all mutable authorization and
    # target metadata after probes, including slow lsof/process/fsync windows.
    manifest, controls = input_documents(request, now=clock(), suspended=suspended)
    ops.validate_unit(path, now=clock())
    return manifest, controls


def validate_authority(request: dict, live_request: dict, live_approval: dict,
                       journal_path: Path, *, now: dt.datetime) -> None:
    """Recheck the complete file-reference closure without another external census."""
    campaign_path = Path(request["campaign"]["identity"]["path"])
    _, targets, private = ops.campaign_review(campaign_path, request["unit_id"], now=now)
    nonprivate = cleanup.ReferenceIndex()
    for ref in (live_request, live_approval, request["stage"], request["manifest"],
                request["campaign"], *request["installed"].values()):
        bound_bytes(ref)
        private.add({"path": ref["identity"]["path"], "sha256": ref["sha256"]}, "activation authority")
    stage = policy.document(bound_bytes(request["stage"]))
    for key in ("window", "manifest", "controls"):
        private.add(stage[key], "staged activation authority")
    ops.collect_references(
        {"path": live_approval["identity"]["path"], "sha256": live_approval["sha256"]},
        private, kind="approval",
    )
    controls = policy.document(bound_bytes(request["installed"][ops.CONTROLS_NAME]))
    ops.collect_references(controls["approval"], private, kind="approval")
    for ref in controls["coverage_evidence"]:
        private.add(ref, "operational coverage evidence")
    for entry in controls["entrypoints"]:
        nonprivate.add({"path": entry["path"], "sha256": entry["sha256"]}, "cleanup entrypoint")
    package = policy.document(bound_bytes(request["installed"][policy.POLICY_NAME]))
    private.add(package["approval"], "window approval")
    approval = policy.document(policy.reference(package["approval"]))
    private.add(approval["evidence"], "window approval evidence")
    attestations = {}
    for ref in approval["attestations"]:
        private.add(ref, "owner attestation")
        attestation = policy.document(policy.reference(ref))
        attestations[attestation["cohort"]] = attestation
        for evidence in attestation["evidence"]:
            private.add(evidence, "owner attestation evidence")
    for cohort in package["cohorts"]:
        for root in cohort["roots"]:
            for ref in root["writers"]:
                nonprivate.add(ref, "writer fingerprint")
            if attestations[cohort["name"]]["disposition"] == "wrapped":
                for name, digest in policy.PROTOCOL_FILES.items():
                    nonprivate.add({
                        "path": str(Path(root["identity"]["path"]) / name), "sha256": digest,
                    }, "frozen writer protocol")
    campaign = policy.document(bound_bytes(request["campaign"]))
    retired = set()
    for unit in campaign["units"]:
        manifest = policy.document(policy.reference(unit["manifest"]))
        for target in manifest["targets"]:
            ref = target["release_record"]
            if target.get("ownership") == "retired-v2" and ref["path"] not in retired:
                retired.add(ref["path"])
                retirement = policy.document(policy.reference(ref))
                for item in retirement["targets"]:
                    nonprivate.add({
                        "path": str(Path(item["store"]["path"]) / "info.plist"),
                        "sha256": item["info_sha256"],
                    }, "retired store attribution")
    for path in [journal_path, *(Path(ref["path"]) for ref in (
        *private.references.values(), *nonprivate.references.values(),
    ))]:
        if targets.contains(path):
            lease.fail("activation authority overlaps a campaign target")
    private.validate()
    for ref in nonprivate.references.values():
        if policy.digest(policy.read_bytes(Path(ref["path"]), private=False)) != ref["sha256"]:
            lease.fail("activation writer or attribution evidence changed")


def activation_inputs(stage_path: Path, campaign_path: Path, unit_id: str, activation_id: str, *,
                      clock: Callable = cleanup.now_utc,
                      opened: Callable = cleanup.open_file_inventory) -> dict:
    with ops.administrative_locks() as check:
        if lease.scan_records():
            lease.fail("retained or active records prevent an activation snapshot")
        p = lease.paths()
        lease.validate_uuid(activation_id, "activation id")
        archive = p["root"] / ARCHIVE_NAME / activation_id
        if archive.exists() or archive.is_symlink():
            lease.fail("activation id was already attempted; new review and id required")
        stage = policy.document(policy.read_bytes(stage_path, private=True))
        window = policy.document(policy.read_bytes(p["root"] / policy.POLICY_NAME, private=True))
        request = {
            "schema": 2, "activation_id": activation_id, "host": policy.host_identity(),
            "locks": {name: cleanup.identity_document(p[name]) for name in LOCK_NAMES},
            "observed_at": cleanup.utc(clock()), "expires_at": window["window"]["expires_at"],
            "window_id": window["window"]["id"], "unit_id": unit_id,
            "stage": binding(stage_path),
            "installed": {name: binding(p["root"] / name) for name in INSTALLED_NAMES},
            "manifest": binding(Path(stage["manifest"]["path"])),
            "campaign": binding(campaign_path), "suspension": binding(p["suspend"]),
            "expected_receipt": state(p["root"] / RECEIPT_NAME),
        }
        readiness(request, clock=clock, suspended=True, opened=opened)
        check()
        if lease.scan_records():
            lease.fail("registry changed during activation snapshot")
        same_state(p["root"] / RECEIPT_NAME, request["expected_receipt"])
        return request


def inherited_activation() -> tuple[argparse.Namespace, dict]:
    if os.environ.get("APPLE_BUILD_LEASE_PROTOCOL") != "1" or os.environ.get("APPLE_BUILD_LEASE_MODE") != "shared":
        lease.fail("activation requires its dedicated inherited frozen v1 shared lane")
    if os.environ.get("APPLE_BUILD_LEASE_POLICY_LOCK_FD") or os.environ.get("APPLE_BUILD_LEASE_ROLLOUT_FD"):
        lease.fail("shared activation cannot inherit maintenance policy-lock capabilities")
    values = {"mode": "shared", "policy_lock_fd": None, "rollout_fd": None}
    for field in ("owner", "lease_id", "token", "lock_fd", "proof_fd"):
        value = os.environ.get("APPLE_BUILD_LEASE_" + ("ID" if field == "lease_id" else field.upper()))
        if not value:
            lease.fail(f"missing activation lease capability: {field}")
        values[field] = int(value) if field.endswith("_fd") else value
    args = argparse.Namespace(**values)
    record, role = lease.validate_existing(args)
    if args.owner != ACTIVATION_OWNER or record["state"] != "active" or role != "owner":
        lease.fail("only the dedicated original activation lane may transition suspension")
    return args, record


@contextlib.contextmanager
def activation_locks():
    args, record = inherited_activation()
    p = lease.paths()
    original = binding(lease.record_path(args.lease_id))
    upgraded = False
    with contextlib.ExitStack() as stack:
        held = []
        try:
            for name in ("policy_lock", "lock", "registry_lock"):
                fd = args.lock_fd if name == "lock" else lease._open_regular_file(p[name], os.O_RDWR)
                if name != "lock":
                    stack.callback(os.close, fd)
                lease.validate_fd_path(fd, p[name], private=True)
                try:
                    lease.fcntl.flock(fd, lease.fcntl.LOCK_EX | lease.fcntl.LOCK_NB)
                except BlockingIOError:
                    lease.fail("activation conflicts with a writer, reader or administrator")
                if name == "lock":
                    upgraded = True
                held.append((fd, p[name]))
            def check(*, inspect_requester=True):
                for fd, path in held:
                    lease.validate_fd_path(fd, path, private=True)
                proof = lease.validate_proof_fd(args.proof_fd)
                if (proof.st_dev, proof.st_ino) != (record["proof_dev"], record["proof_ino"]):
                    lease.fail("activation proof identity changed")
                if policy.document(bound_bytes(original)) != record or lease.scan_records() != [record]:
                    lease.fail("activation requires zero other active or retained records")
                if inspect_requester and lease.process_start(record["request_pid"]) != record["request_start"]:
                    lease.fail("original activation wrapper identity changed")
                probe = lease._open_regular_file(p["lock"], os.O_RDONLY)
                try:
                    try:
                        lease.fcntl.flock(probe, lease.fcntl.LOCK_SH | lease.fcntl.LOCK_NB)
                    except BlockingIOError:
                        pass
                    else:
                        lease.fail("activation exclusive kernel lock is not held")
                finally:
                    os.close(probe)
            check()
            yield check, record
        finally:
            if upgraded:
                lease.validate_fd_path(args.lock_fd, p["lock"], private=True)
                lease.fcntl.flock(args.lock_fd, lease.fcntl.LOCK_SH)
            # The inherited descriptor/record belongs to the frozen wrapper.
            # Do not close it, fabricate release, or finalize failed activation.


def publish_receipt(archive: Path, phase: str, value: dict, expected, *,
                    before_publish: Callable) -> dict:
    path = lease.paths()["root"] / RECEIPT_NAME
    candidate = archive / f"candidate-{phase}.json"
    ops.namespace_write_new(candidate, policy.canonical(value) + b"\n")
    identity = binding(candidate)
    same_state(path, expected)
    before_publish()
    os.replace(candidate, path)
    lease.fsync_directory(path.parent)
    identity["identity"]["path"] = str(path)
    if binding(path) != identity:
        lease.fail("published activation receipt was replaced")
    return identity


def restore_suspension(candidate: Path, expected: dict) -> str:
    """Atomic no-clobber publication of a pre-fsynced rollback candidate."""
    marker = lease.paths()["suspend"]
    bound_bytes(expected)
    try:
        os.link(candidate, marker, follow_symlinks=False)
    except FileExistsError:
        # Even an uninspectable concurrent replacement remains a suspension.
        return "concurrent-marker-preserved"
    lease.fsync_directory(marker.parent)
    candidate.unlink()
    lease.fsync_directory(candidate.parent)
    return "restored"


def activate(request_path: Path, approval_ref: dict, journal_path: Path, *,
             clock: Callable = cleanup.now_utc,
             opened: Callable = cleanup.open_file_inventory) -> dict:
    request = policy.document(policy.read_bytes(request_path, private=True))
    manifest = policy.document(bound_bytes(request["manifest"]))
    controls = policy.document(bound_bytes(request["installed"][ops.CONTROLS_NAME]))
    _, campaign_targets, _ = ops.campaign_review(
        Path(request["campaign"]["identity"]["path"]), request["unit_id"], now=clock(),
    )
    for artifact in (request_path, Path(approval_ref["path"]), journal_path):
        ops.artifact_outside(artifact, manifest, controls)
        if campaign_targets.contains(artifact):
            lease.fail("activation authority overlaps a campaign target")
    journal = cleanup.DurableJournal(journal_path, {"schema": 2, "operation": "activate-installed-window"})
    stopped_attempted = False
    try:
        with cleanup.cancellation_signals(), activation_locks() as (lock_check, record), contextlib.ExitStack() as pinned_inputs:
            archive = None
            rollback_binding = None
            transition_attempted = False
            try:
                live_request = binding(request_path)
                if policy.document(bound_bytes(live_request)) != request:
                    lease.fail("activation request changed")
                live_approval = binding(Path(approval_ref["path"]))
                if live_approval["sha256"] != approval_ref["sha256"]:
                    lease.fail("activation approval changed")
                observed = policy.timestamp(request["observed_at"])
                expires = policy.timestamp(request["expires_at"])
                deadline = time.monotonic() + (expires - clock()).total_seconds()
                last_time = clock()
                def fresh(suspended, receipt):
                    nonlocal last_time
                    lock_check()
                    current = clock()
                    if current < last_time or current >= expires or time.monotonic() >= deadline:
                        lease.fail("activation expired or clock moved backwards")
                    last_time = current
                    bound_bytes(live_request)
                    bound_bytes(live_approval)
                    ops.approved(request, approval_ref, purpose="activate-installed-window",
                                 earliest=observed, now=current)
                    readiness(request, clock=clock, suspended=suspended, opened=opened)
                    bound_bytes(live_request)
                    bound_bytes(live_approval)
                    same_state(lease.paths()["root"] / RECEIPT_NAME, receipt)
                    lock_check()
                    ops.approved(request, approval_ref, purpose="activate-installed-window",
                                 earliest=observed, now=clock())
                    validate_authority(request, live_request, live_approval, journal_path, now=clock())
                    bound_bytes(live_request)
                    bound_bytes(live_approval)
                    input_documents(request, now=clock(), suspended=suspended, verify_policy=False)
                    same_state(lease.paths()["root"] / RECEIPT_NAME, receipt)
                    lock_check(inspect_requester=False)
                    current = clock()
                    if current < last_time or current >= expires or time.monotonic() >= deadline:
                        lease.fail("activation expired during validation")
                    last_time = current
                fresh(True, request["expected_receipt"])
                archive_root = lease.paths()["root"] / ARCHIVE_NAME
                lease.ensure_secure_directory(archive_root, create=True)
                lease.fsync_directory(lease.paths()["root"])
                candidate_archive = archive_root / request["activation_id"]
                candidate_archive.mkdir(mode=0o700)
                archive = candidate_archive
                lease.fsync_directory(archive_root)
                originals = {
                    "request.json": bound_bytes(live_request),
                    "approval.json": bound_bytes(live_approval),
                    "suspension-original": bound_bytes(request["suspension"]),
                    "restore-candidate": bound_bytes(request["suspension"]),
                    "activation-lease.json": policy.read_bytes(lease.record_path(record["lease_id"]), private=True),
                    "stage.json": bound_bytes(request["stage"]),
                    "manifest.json": bound_bytes(request["manifest"]),
                    "campaign.json": bound_bytes(request["campaign"]),
                    **{name: bound_bytes(ref) for name, ref in request["installed"].items()},
                }
                if request["expected_receipt"] != "absent":
                    originals["previous-receipt.json"] = bound_bytes(request["expected_receipt"])
                approval = policy.document(originals["approval.json"])
                for index, evidence in enumerate(approval["evidence"]):
                    originals[f"approval-evidence-{index}"] = policy.reference(evidence)
                for name, data in originals.items():
                    ops.namespace_write_new(archive / name, data)
                rollback_binding = binding(archive / "restore-candidate")
                suspension_pin = cleanup.PinnedManifest(
                    lease.paths()["suspend"], originals["suspension-original"],
                )
                pinned_inputs.callback(suspension_pin.close)
                pending = {
                    "schema": 2, "state": "pending", "activation_id": request["activation_id"],
                    "archive": cleanup.identity_document(archive), "lease_id": record["lease_id"],
                }
                receipt = publish_receipt(
                    archive, "pending", pending, request["expected_receipt"],
                    before_publish=lambda: fresh(True, request["expected_receipt"]),
                )
                journal.append({"event": "activation-intent", "request": request,
                                "archive": str(archive), "lease_id": record["lease_id"]})
                # The original shared lane is exclusively kernel-locked and
                # remains durable registry evidence throughout this transition.
                with cleanup.directory_fd(lease.paths()["suspend"].parent) as parent:
                    fresh(True, receipt)
                    suspension_pin.validate()
                    lock_check(inspect_requester=False)
                    if cleanup.identity_stat(os.fstat(parent)) != cleanup.identity_stat(lease.paths()["suspend"].parent.stat()):
                        lease.fail("suspension parent changed before transition")
                    transition_time = clock()
                    if transition_time < last_time or transition_time >= expires or time.monotonic() >= deadline:
                        lease.fail("activation expired immediately before transition")
                    transition_attempted = True
                    os.unlink(lease.paths()["suspend"].name, dir_fd=parent)
                    os.fsync(parent)
                fresh(False, receipt)
                journal.append({"event": "activation-commit", "activation_id": request["activation_id"],
                                "at": cleanup.utc(clock())})
                committed = {
                    **pending, "state": "active", "committed_at": cleanup.utc(clock()),
                    "request": binding(archive / "request.json"), "approval": binding(archive / "approval.json"),
                    "live_request": live_request, "live_approval": live_approval,
                    "original_suspension": binding(archive / "suspension-original"),
                    "activation_record": binding(archive / "activation-lease.json"),
                    "journal": binding(journal_path),
                }
                receipt = publish_receipt(
                    archive, "active", committed, receipt,
                    before_publish=lambda: fresh(False, receipt),
                )
                fresh(False, receipt)
                return {"state": "activated", "activation_id": request["activation_id"],
                        "expires_at": request["expires_at"], "receipt": receipt,
                        "lane_finalization": "required-before-cleanup"}
            except BaseException as exc:
                # Never overwrite the current receipt/marker during rollback.
                # Any FAILED entry (even partial) invalidates a receipt. If all
                # writes fail, the unreleased genuine v1 lane still blocks EX.
                failures = []
                if archive is not None:
                    try:
                        ops.namespace_write_new(archive / "FAILED", (f"{type(exc).__name__}: {exc}\n").encode())
                    except (OSError, lease.LeaseError) as failure:
                        failures.append(f"failure fence: {failure}")
                suspension = "unchanged"
                if transition_attempted and archive is not None and rollback_binding is not None:
                    try:
                        suspension = restore_suspension(archive / "restore-candidate", rollback_binding)
                    except (OSError, lease.LeaseError) as failure:
                        suspension = "uncertain; retained activation lease blocks cleanup"
                        failures.append(f"suspension restore: {failure}")
                stopped_attempted = True
                journal.append({
                    "event": "activation-stopped", "transition_attempted": transition_attempted,
                    "suspension": suspension, "rollback_errors": failures,
                    "error": f"{type(exc).__name__}: {exc}",
                })
                raise
    except BaseException as exc:
        if not stopped_attempted:
            journal.append({
                "event": "activation-stopped", "transition_attempted": False,
                "suspension": "unchanged", "rollback_errors": [],
                "error": f"{type(exc).__name__}: {exc}",
            })
        raise
    finally:
        journal.close()


def validate_receipt(reference: dict, manifest_path: Path, campaign_path: Path,
                     unit_id: str, window_id: str, *, now: dt.datetime) -> None:
    value = policy.document(bound_bytes(reference))
    policy.exact(value, {
        "schema", "state", "activation_id", "archive", "lease_id", "committed_at",
        "request", "approval", "live_request", "live_approval", "original_suspension",
        "activation_record", "journal",
    }, "completed activation receipt")
    ops.v2(value["schema"])
    if value["state"] != "active":
        lease.fail("activation has no completed receipt")
    archive = Path(cleanup.validate_identity(value["archive"], "activation archive")["path"])
    if archive != lease.paths()["root"] / ARCHIVE_NAME / value["activation_id"]:
        lease.fail("activation receipt names a different archive")
    try:
        (archive / "FAILED").lstat()
    except FileNotFoundError:
        pass
    else:
        lease.fail("failed or uncertain activation is fenced")
    for name, ref in (
        ("request.json", value["request"]), ("approval.json", value["approval"]),
        ("suspension-original", value["original_suspension"]),
        ("activation-lease.json", value["activation_record"]),
    ):
        if ref["identity"]["path"] != str(archive / name):
            lease.fail("activation receipt references a different transaction")
    request_data, approval_data = bound_bytes(value["request"]), bound_bytes(value["approval"])
    if bound_bytes(value["live_request"]) != request_data or bound_bytes(value["live_approval"]) != approval_data:
        lease.fail("activation approval/request was revoked or changed")
    request = policy.document(request_data)
    if (request["activation_id"], request["unit_id"], request["window_id"]) != (
        value["activation_id"], unit_id, window_id,
    ):
        lease.fail("activation receipt belongs to another unit/window")
    if request["manifest"]["identity"]["path"] != str(manifest_path) or request["campaign"]["identity"]["path"] != str(campaign_path):
        lease.fail("activation receipt belongs to another manifest/campaign")
    if not policy.timestamp(request["observed_at"]) <= policy.timestamp(value["committed_at"]) <= now < policy.timestamp(request["expires_at"]):
        lease.fail("activation receipt expired or has invalid commit time")
    approval_ref = {"path": value["live_approval"]["identity"]["path"], "sha256": value["live_approval"]["sha256"]}
    ops.approved(request, approval_ref, purpose="activate-installed-window",
                 earliest=policy.timestamp(request["observed_at"]), now=now)
    if policy.digest(bound_bytes(value["original_suspension"])) != request["suspension"]["sha256"]:
        lease.fail("activation original suspension evidence changed")
    record = policy.document(bound_bytes(value["activation_record"]))
    if record["lease_id"] != value["lease_id"] or record["owner"] != ACTIVATION_OWNER:
        lease.fail("activation lease evidence mismatch")
    if any(r["lease_id"] == value["lease_id"] for r in lease.scan_records()):
        lease.fail("activation owner has not cleanly finalized its whole lane")
    events = [policy.document(line) for line in bound_bytes(value["journal"]).splitlines()]
    if not events or events[-1].get("event") != "activation-commit" or events[-1].get("activation_id") != value["activation_id"]:
        lease.fail("activation journal is incomplete or stopped")
    # Do not rescan removed targets: runtime already validates the current
    # target per unlink. Immutable input identities and approvals remain live.
    input_documents(request, now=now, suspended=False, verify_policy=False)
    validate_authority(
        request, value["live_request"], value["live_approval"],
        Path(value["journal"]["identity"]["path"]), now=now,
    )
