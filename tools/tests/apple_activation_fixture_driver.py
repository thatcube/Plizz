#!/usr/bin/env python3
"""Bounded subprocess worker for real frozen-wrapper activation fixtures."""

import argparse
import contextlib
import json
import os
from pathlib import Path
import signal
import sys
import time
from unittest import mock


def main():
    parser = argparse.ArgumentParser()
    for name in ("bundle", "request", "approval", "journal", "status"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--fault", default="")
    args = parser.parse_args()
    if os.environ.get("APPLE_BUILD_INTERLOCK_TESTING") != "1":
        raise RuntimeError("fixture driver cannot operate outside isolated test HOME")
    sys.path.insert(0, str(args.bundle / "tools/lib"))
    import apple_build_cleanup as cleanup
    import apple_build_lease as lease
    import apple_build_operations as ops
    import apple_build_activation as activation
    home = lease.paths()["home"]
    for path in (args.bundle, args.request, args.approval, args.journal, args.status):
        if home not in path.parents:
            raise RuntimeError("fixture driver input escapes test HOME")
    args.status.write_text(json.dumps({"pid": os.getpid(), "start": lease.process_start(os.getpid())}))
    args.status.chmod(0o600)
    original_entry = cleanup.entry_record
    original_append = cleanup.DurableJournal.append
    original_unlink = os.unlink
    original_publish = activation.publish_receipt
    original_write = ops.namespace_write_new
    original_fsync = os.fsync
    original_replace = os.replace
    original_inherited = activation.inherited_activation
    original_os_write = os.write
    original_process_start = lease.process_start
    original_sync_directory = lease.fsync_directory
    injected = False
    after_intent = False
    requester_checks = 0

    def aged(*values):
        record = original_entry(*values)
        for key in ("mtime_ns", "ctime_ns", "birthtime_ns"):
            record[key] -= 5 * 86400 * 1_000_000_000
        return record

    def phase(name):
        nonlocal injected
        if args.fault == "crash-" + name:
            os._exit(91)
        if args.fault == "cancel-" + name:
            raise KeyboardInterrupt("fixture cancellation")
        if args.fault == "pause-" + name:
            ready = args.status.with_suffix(".ready")
            ready.write_text(name)
            ready.chmod(0o600)
            deadline = time.monotonic() + 15
            while not args.status.with_suffix(".continue").exists():
                if time.monotonic() >= deadline:
                    raise RuntimeError("bounded fixture pause timed out")
                time.sleep(0.02)
        if name == "transition" and args.fault in {"restore-fails", "concurrent-marker"}:
            if args.fault == "concurrent-marker":
                lease.paths()["suspend"].write_bytes(b"concurrent fixture suspension")
                lease.paths()["suspend"].chmod(0o600)
            raise OSError("fixture post-transition failure")

    def appended(journal, event):
        nonlocal after_intent
        original_append(journal, event)
        if event["event"] == "activation-intent":
            after_intent = True
            phase("intent")

    def unlinked(path, **kwargs):
        result = original_unlink(path, **kwargs)
        if path == lease.SUSPEND_NAME:
            phase("transition")
        return result

    def published(archive, name, value, expected, **kwargs):
        result = original_publish(archive, name, value, expected, **kwargs)
        if name == "active":
            phase("receipt")
        return result

    def written(path, data):
        nonlocal injected
        if args.fault == "archive-write" and path.name == "suspension-original":
            raise OSError("fixture original preservation failed")
        original_write(path, data)
        if ((args.fault == "approval-evidence" and path.name == "candidate-pending.json") or
            (args.fault == "active-approval-evidence" and path.name == "candidate-active.json")) and not injected:
            injected = True
            approval = json.loads(args.approval.read_bytes())
            Path(approval["evidence"][0]["path"]).write_bytes(b"activation-only evidence withdrawn")

    def requester_start(pid):
        nonlocal requester_checks, injected
        result = original_process_start(pid)
        if after_intent and pid == os.getppid():
            requester_checks += 1
            if args.fault == "approval-after-requester-census" and requester_checks == 2 and not injected:
                injected = True
                approval = json.loads(args.approval.read_bytes())
                Path(approval["evidence"][0]["path"]).write_bytes(b"withdrawn during final requester census")
        return result

    def synced(fd):
        nonlocal injected
        if args.fault == "transition-fsync" and not lease.paths()["suspend"].exists() and not injected:
            if cleanup.identity_stat(os.fstat(fd)) == cleanup.identity_stat(lease.paths()["policy_home"].stat()):
                injected = True
                raise OSError("fixture suspension directory fsync failed")
        return original_fsync(fd)

    def synced_directory(path):
        if args.fault == "archive-parent-fsync" and Path(path) == lease.paths()["root"]:
            raise OSError("fixture activation archive parent sync failed")
        return original_sync_directory(path)

    def replaced(source, destination):
        result = original_replace(source, destination)
        if args.fault == "receipt-fsync" and Path(source).name == "candidate-active.json":
            raise OSError("fixture receipt publication uncertain")
        return result

    def opened():
        nonlocal injected
        if args.fault in {"probe-suspension", "probe-new-record", "probe-target"} and not injected:
            injected = True
            if args.fault == "probe-suspension":
                marker = lease.paths()["suspend"]
                marker.rename(home / "original-suspension-at-probe")
                marker.write_bytes(b"replacement suspension")
                marker.chmod(0o600)
            elif args.fault == "probe-new-record":
                record = lease.read_record(lease.record_path(os.environ["APPLE_BUILD_LEASE_ID"]))
                record["lease_id"] = "00000000-0000-0000-0000-000000000999"
                lease.write_new_record(record)
            else:
                request = json.loads(args.request.read_bytes())
                manifest = json.loads(Path(request["manifest"]["identity"]["path"]).read_bytes())
                target = Path(manifest["targets"][0]["path"])
                next(target.glob("*.o")).write_bytes(b"changed during open-use probe")
        return (("/unrelated/fixture",), frozenset())

    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch.object(cleanup, "entry_record", aged))
        stack.enter_context(mock.patch.object(cleanup, "require_no_build_activity"))
        stack.enter_context(mock.patch.object(cleanup.DurableJournal, "append", appended))
        stack.enter_context(mock.patch.object(os, "unlink", unlinked))
        stack.enter_context(mock.patch.object(activation, "publish_receipt", published))
        stack.enter_context(mock.patch.object(ops, "namespace_write_new", written))
        stack.enter_context(mock.patch.object(os, "fsync", synced))
        stack.enter_context(mock.patch.object(os, "replace", replaced))
        stack.enter_context(mock.patch.object(lease, "process_start", requester_start))
        stack.enter_context(mock.patch.object(lease, "fsync_directory", synced_directory))
        if args.fault in {"short-write", "zero-write-after-transition"}:
            def partial_write(fd, data):
                if args.fault == "zero-write-after-transition" and not lease.paths()["suspend"].exists():
                    return 0
                return original_os_write(fd, data[:max(1, len(data) // 2)])
            stack.enter_context(mock.patch.object(os, "write", partial_write))
        if args.fault == "restore-fails":
            stack.enter_context(mock.patch.object(os, "link", side_effect=OSError("fixture rollback I/O failure")))
        if args.fault == "inherited-policy-lock":
            fd = os.open(lease.paths()["policy_lock"], os.O_RDONLY)
            stack.callback(os.close, fd)
            lease.fcntl.flock(fd, lease.fcntl.LOCK_SH)
            # A real shared holder conflicts with the exclusive nonblocking
            # policy update. No successful-lock mock is involved.
        if args.fault in {"inherited-registry-lock", "inherited-coordination-lock"}:
            def authenticated_then_contended():
                result = original_inherited()
                key = "registry_lock" if args.fault == "inherited-registry-lock" else "lock"
                fd = os.open(lease.paths()[key], os.O_RDONLY)
                stack.callback(os.close, fd)
                lease.fcntl.flock(fd, lease.fcntl.LOCK_SH)
                return result
            stack.enter_context(mock.patch.object(activation, "inherited_activation", authenticated_then_contended))
        if args.fault == "unexpected-policy-capability":
            stack.enter_context(mock.patch.dict(os.environ, {"APPLE_BUILD_LEASE_POLICY_LOCK_FD": "8"}))
        result = activation.activate(
            args.request, cleanup.reference_for(args.approval), args.journal,
            opened=opened,
        )
    print(json.dumps(result))


if __name__ == "__main__":
    main()
