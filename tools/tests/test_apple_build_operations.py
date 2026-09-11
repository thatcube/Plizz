#!/usr/bin/env python3
"""Synthetic operational lifecycle; no production paths, processes or approvals.

Only filesystem age, host-wide process activity and the unrelated-host lsof
census are simulated. Git registries, documents, approvals, kernel locks, frozen
lease authentication, publication, per-unlink guards and deletion are real.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools/lib"))
import apple_build_operations as ops
import apple_build_cleanup as cleanup
import apple_build_lease as lease
import apple_maintenance_policy as policy
from tools.tests import test_apple_maintenance_policy as policy_tests


class OperationalTests(unittest.TestCase):
    def setUp(self):
        self.f = policy_tests.MaintenancePolicyTests()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        f = self.f
        self.now = cleanup.now_utc().replace(microsecond=0)
        self.old = self.now - dt.timedelta(days=5)
        self.retired_at = self.now - dt.timedelta(days=4)
        self.session_id = str(uuid.uuid4())
        self.unit_id = str(uuid.uuid4())
        self.marker = lease.paths()["suspend"]
        self.marker.write_bytes(b"Fixture suspension must survive preparation.\n")
        self.marker.chmod(0o600)
        self.marker_bytes = self.marker.read_bytes()
        self.original_entry = cleanup.entry_record
        def aged(*args):
            record = self.original_entry(*args)
            for key in ("mtime_ns", "ctime_ns", "birthtime_ns"):
                record[key] -= 5 * 86400 * 1_000_000_000
            return record
        self.age = mock.patch.object(cleanup, "entry_record", side_effect=aged)
        self.age.start()
        self.addCleanup(self.age.stop)
        self.activity = mock.patch.object(cleanup, "require_no_build_activity")
        self.activity.start()
        self.addCleanup(self.activity.stop)
        # A complete private bundle, not a claim that the source checkout is
        # installed. Fingerprint and validate actual copied bytes in the fixture.
        for name in ops.OPERATIONS_FILES:
            path = f.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)
        patch = mock.patch.object(ops, "__file__", str(f.repo / "tools/lib/apple_build_operations.py"))
        patch.start()
        self.addCleanup(patch.stop)
        self.legacy = f.repo / "old-cleanup.sh"
        self.legacy.write_bytes(ops.DISABLED_ENTRYPOINT)
        self.protected = f.home / "protected"
        self.protected.mkdir()
        (self.protected / "keep.swift").write_text("fixture source")
        self.git("add", "writer.sh")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--quiet", "-m", "Synthetic history")
        self.gone = f.home / "cautious-robot"
        self.git("worktree", "add", "--quiet", "--detach", str(self.gone))
        self.original_identity = cleanup.identity_document(self.gone)
        historic_registry = self.git("worktree", "list", "--porcelain", "-z")
        self.registry_file = f.home / "historical-registry"
        self.registry_file.write_bytes(historic_registry)
        self.registry_file.chmod(0o600)
        self.history_path = f.home / "history.json"
        self.history = {
            "schema": 2, "owner": "fixture/old-lane", "session_id": self.session_id,
            "worktree": self.original_identity,
            "repository": cleanup.identity_document(f.repo),
            "common_git": cleanup.identity_document(f.repo / ".git"),
            "head": self.git("rev-parse", "HEAD").decode().strip(),
            "workspace": str(self.gone / "Plozz.xcodeproj/project.xcworkspace"),
            "recorded_at": cleanup.utc(self.old), "registry": f.ref(self.registry_file),
            "evidence": [f.ref(f.evidence)],
        }
        f.write_json(self.history_path, self.history)
        self.git("worktree", "remove", str(self.gone))
        self.derived = f.home / "Library/Developer/Xcode/DerivedData"
        self.derived.mkdir(parents=True)
        self.store = self.derived / "Plozz-retired"
        self.store.mkdir()
        self.info = self.store / "info.plist"
        self.info.write_bytes(plistlib.dumps({"WorkspacePath": self.history["workspace"]}))
        self.target = self.store / "Build/Intermediates.noindex/compiler"
        self.target.mkdir(parents=True)
        (self.target / "one.o").write_bytes(b"one")
        (self.target / "two.swiftmodule").write_bytes(b"two")
        self.keep = self.store / "SourcePackages/checkouts/pkg/source.swift"
        self.keep.parent.mkdir(parents=True)
        self.keep.write_text("not disposable")
        self.logs = self.store / "Logs/result.xcresult"
        self.logs.parent.mkdir()
        self.logs.write_bytes(b"required evidence")
        self.retirement_path = f.home / "retirement.json"
        self.retirement = {
            "schema": 2, "scope": cleanup.SCOPE, "historical_owner": f.ref(self.history_path),
            "retired_at": cleanup.utc(self.retired_at),
            "targets": [self.retired_target(self.target)],
            "evidence": [f.ref(f.evidence)],
        }
        self.approve_retirement()
        self.controls_path = f.home / "controls.json"
        self.stage_path = f.home / "stage.json"
        self.campaign_path = f.home / "campaign.json"
        self.journal = f.home / "deletion.jsonl"
        self.make_unit()

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.f.repo), *args], check=True,
                                capture_output=True, env=self.f.env)
        return result.stdout

    def opened(self, _ignored=frozenset()):
        return (("/unrelated/fixture",), frozenset({(999999, 999999)}))

    def approval(self, payload, purpose, name, at=None):
        return self.f.write_json(self.f.home / name, {
            "schema": 2, "purpose": purpose, "payload_sha256": policy.digest(policy.canonical(payload)),
            "approved_by": "synthetic-human", "approved_at": cleanup.utc(at or self.now),
            "evidence": [self.f.ref(self.f.evidence)],
        })

    def retired_target(self, path):
        return {
            "kind": "xcode-derived-data", "identity": cleanup.identity_document(path),
            "store": cleanup.identity_document(path.parents[2]),
            "info_sha256": policy.digest((path.parents[2] / "info.plist").read_bytes()),
        }

    def approve_retirement(self):
        self.retirement.pop("approval", None)
        self.retirement["approval"] = self.approval(
            self.retirement, "retire-missing-owner", "retirement-approval.json", self.retired_at,
        )
        self.f.write_json(self.retirement_path, self.retirement)

    def make_unit(self):
        f = self.f
        self.manifest = ops.inventory([], [self.retirement_path], now=self.now)
        f.write_json(f.manifest, self.manifest)
        campaign = {
            "schema": 2, "units": [{"id": self.unit_id, "manifest": f.ref(f.manifest)}],
            "reviewed_at": cleanup.utc(self.now),
        }
        campaign["approval"] = self.approval(campaign, "bounded-campaign", "campaign-approval.json")
        f.write_json(self.campaign_path, campaign)
        self.make_window()

    def make_window(self):
        f = self.f
        for item in f.package["cohorts"]:
            if item["name"] == "global-cleanup-entrypoints":
                item["roots"][0]["writers"] = [
                    f.ref(f.repo / name) for name in ops.OPERATIONS_FILES
                ] + [f.ref(self.legacy)]
        f.package["registries"][0]["sha256"] = policy.worktree_snapshot(f.repo)[0]
        f.package["window"]["manifest_sha256"] = policy.digest(policy.canonical(self.manifest))
        f.approve()
        self.make_controls()

    def make_controls(self):
        f = self.f
        self.controls = {
            "schema": 2, "window_sha256": policy.digest(policy.canonical(f.package)),
            "manifest_sha256": policy.digest(policy.canonical(self.manifest)),
            "protected_roots": [cleanup.identity_document(self.protected)],
            "entrypoints": [
                {**f.ref(f.repo / "tools/apple-build-operations.py"), "enforcement": "operational-v2"},
                {**f.ref(self.legacy), "enforcement": "disabled"},
            ],
            "coverage_evidence": [f.ref(f.evidence)],
            "reviewed_at": cleanup.utc(self.now),
        }
        self.approve_controls()

    def approve_controls(self):
        self.controls.pop("approval", None)
        self.controls["approval"] = self.approval(self.controls, "operational-rollout", "controls-approval.json")
        self.f.write_json(self.controls_path, self.controls)

    def stage(self):
        return ops.stage_rollout(self.f.request, self.f.manifest, self.controls_path,
                                 self.stage_path,
                                 self.f.home / ("stage-journal-" + str(uuid.uuid4()) + ".jsonl"),
                                 now=self.now)

    def use_legacy_marker_permissions(self):
        self.marker.parent.chmod(0o755)
        self.marker.chmod(0o644)
        return self.marker.stat()

    def assert_legacy_marker_unchanged(self, original):
        current = self.marker.stat()
        for field in ("st_dev", "st_ino", "st_uid", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns"):
            self.assertEqual(getattr(current, field), getattr(original, field), field)
        self.assertEqual(self.marker.read_bytes(), self.marker_bytes)
        self.assertEqual(self.marker.parent.stat().st_mode & 0o777, 0o755)
        self.assertEqual(lease.paths()["root"].stat().st_mode & 0o777, 0o700)
        for name in ("policy_lock", "lock", "registry_lock"):
            self.assertEqual(lease.paths()[name].stat().st_mode & 0o777, 0o600)

    def install(self):
        self.stage()
        stage = policy.document(self.stage_path.read_bytes())
        approval = self.approval(stage, "install-suspended-rollout", "install-approval.json")
        return ops.install_prepared(self.stage_path, approval, self.f.home / "install.jsonl", now=self.now)

    def activation_request(self):
        import apple_build_activation as activation
        identity = str(uuid.uuid4())
        request = activation.activation_inputs(
            self.stage_path, self.campaign_path, self.unit_id, identity,
            clock=lambda: self.now, opened=self.opened,
        )
        path = self.f.home / f"activation-{identity}.json"
        self.f.write_json(path, request)
        approval = self.approval(request, "activate-installed-window", f"activation-approval-{identity}.json")
        journal = self.f.home / f"activation-{identity}.jsonl"
        return path, approval, journal

    def activation_command(self, request, approval, journal, *, fault=""):
        import apple_build_activation as activation
        driver = self.f.home / "activation-fixture-driver.py"
        if not driver.exists():
            shutil.copyfile(ROOT / "tools/tests/apple_activation_fixture_driver.py", driver)
        status = journal.with_suffix(".worker")
        return [
            "/bin/bash", str(self.f.repo / "tools/with-apple-build-lease.sh"),
            activation.ACTIVATION_OWNER, "--", sys.executable, "-B", str(driver),
            "--bundle", str(self.f.repo), "--request", str(request),
            "--approval", approval["path"], "--journal", str(journal),
            "--status", str(status), "--fault", fault,
        ], status

    def run_activation(self, request=None, approval=None, journal=None, *, fault=""):
        if request is None:
            request, approval, journal = self.activation_request()
        command, status = self.activation_command(request, approval, journal, fault=fault)
        result = subprocess.run(command, env=self.f.env, text=True, capture_output=True, timeout=40)
        if result.returncode == 0:
            deadline = time.monotonic() + 5
            while lease.scan_records() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertEqual(lease.scan_records(), [], "frozen activation finalizer did not finish")
        return result, journal, status

    @contextlib.contextmanager
    def exclusive(self):
        # Exercise the approved operation and actual frozen activation wrapper;
        # only the test's inactive teardown below reinstates its fixture marker.
        if self.marker.exists():
            activated, _, _ = self.run_activation()
            self.assertEqual(activated.returncode, 0, activated.stderr)
        with contextlib.ExitStack() as stack:
            p = lease.paths()
            fds = {}
            for field, path in (
                ("lock_fd", p["lock"]), ("policy_lock_fd", p["policy_lock"]),
                ("rollout_fd", p["rollout"]),
            ):
                fds[field] = os.open(path, os.O_RDONLY)
                stack.callback(os.close, fds[field])
            proof = self.f.home / ("proof-" + str(uuid.uuid4()))
            proof.touch(mode=0o600)
            fds["proof_fd"] = os.open(proof, os.O_RDONLY)
            stack.callback(os.close, fds["proof_fd"])
            proof.unlink()
            args = argparse.Namespace(
                mode="exclusive", owner="fixture/maintenance",
                lease_id=str(uuid.uuid4()), token=str(uuid.uuid4()), **fds,
            )
            lease.acquire(args)
            variables = {"APPLE_BUILD_LEASE_PROTOCOL": "1", "APPLE_BUILD_LEASE_MODE": "exclusive"}
            for key in ("owner", "lease_id", "token", *fds):
                name = "ID" if key == "lease_id" else key.upper()
                variables["APPLE_BUILD_LEASE_" + name] = str(getattr(args, key))
            with mock.patch.dict(os.environ, variables):
                yield args
        # Fixture teardown, not the production resolver. Close the entire lane
        # before removing its synthetic record and reinstating suspension.
        lease.record_path(args.lease_id).unlink()
        self.marker.write_bytes(self.marker_bytes)
        self.marker.chmod(0o600)

    def apply(self, opened=None):
        return ops.apply_unit(
            self.campaign_path, self.unit_id, self.f.package["window"]["id"], self.journal,
            opened=opened or self.opened,
        )

    def events(self, path=None):
        return [json.loads(line) for line in (path or self.journal).read_text().splitlines()]

    def test_full_retirement_preparation_install_and_authenticated_deletion(self):
        self.assertFalse(self.gone.exists())
        installed = self.install()
        self.assertEqual(installed["state"], "installed-suspended")
        self.assertEqual(self.marker.read_bytes(), self.marker_bytes)
        fd = os.open(lease.paths()["rollout"], os.O_RDONLY)
        try:
            lease.read_rollout_policy(fd)  # A genuine frozen old reader accepts it.
        finally:
            os.close(fd)
        with self.assertRaisesRegex(lease.LeaseError, "suspended"):
            self.apply()
        self.assertTrue(self.target.exists())
        self.assertEqual(self.events()[-1]["event"], "stopped")
        self.journal = self.f.home / "authorized-deletion.jsonl"
        with self.exclusive():
            result = self.apply()
        self.assertEqual(result["removed"], 3)
        self.assertFalse(self.target.exists())
        self.assertFalse(self.gone.exists())
        self.assertTrue(self.keep.exists())
        self.assertTrue(self.logs.exists())
        self.assertTrue(self.history_path.exists())
        self.assertTrue(self.retirement_path.exists())
        self.assertEqual(self.events()[-1]["event"], "completed")

    def test_existing_owner_still_uses_real_v1_release(self):
        f = self.f
        target = f.repo / ".build/compiled.o"
        target.parent.mkdir()
        target.write_bytes(b"existing")
        release = f.home / "existing-release.json"
        f.write_json(release, {
            "schema": 1, "scope": cleanup.SCOPE, "owner": "fixture/current",
            "session_id": str(uuid.uuid4()), "released_at": cleanup.utc(self.retired_at),
            "worktree": cleanup.identity_document(f.repo), "evidence": [f.ref(f.evidence)],
            "targets": [{"kind": "worktree-apple-build", "identity": cleanup.identity_document(target)}],
        })
        mixed = ops.inventory([release], [self.retirement_path], now=self.now)
        self.assertNotIn("ownership", mixed["targets"][0])
        f.write_json(f.manifest, mixed)
        ops.validate_unit(f.manifest, now=self.now)
        record = policy.document(release.read_bytes())
        record["worktree"]["inode"] += 1
        f.write_json(release, record)
        with self.assertRaises(lease.LeaseError):
            ops.validate_unit(f.manifest, now=self.now)

    def test_v1_adapter_cannot_bypass_installed_operational_controls(self):
        self.install()
        with self.assertRaisesRegex(lease.LeaseError, "explicitly approved v2"):
            cleanup.apply_manifest(
                self.f.manifest, window_id=self.f.package["window"]["id"],
                journal_path=self.journal,
            )
        self.assertTrue(self.target.exists())

    def test_no_fake_owner_adoption_and_registered_missing_owner_refuses(self):
        self.gone.mkdir()
        with self.assertRaisesRegex(lease.LeaseError, "exists again"):
            ops.retirement(self.f.ref(self.retirement_path), now=self.now)
        self.gone.rmdir()
        self.git("worktree", "add", "--quiet", "--detach", str(self.gone))
        shutil.rmtree(self.gone)  # Only this test's owned synthetic Git worktree.
        with self.assertRaisesRegex(lease.LeaseError, "still registered"):
            ops.retirement(self.f.ref(self.retirement_path), now=self.now)

    def test_same_slug_other_repository_and_historical_head_refuse(self):
        self.history["worktree"]["path"] = str(self.f.home / "other-repo/cautious-robot")
        self.f.write_json(self.history_path, self.history)
        self.retirement["historical_owner"] = self.f.ref(self.history_path)
        self.approve_retirement()
        with self.assertRaisesRegex(lease.LeaseError, "exact original owner"):
            ops.retirement(self.f.ref(self.retirement_path), now=self.now)
        self.history["worktree"] = self.original_identity
        self.history["head"] = "0" * 40
        self.f.write_json(self.history_path, self.history)
        self.retirement["historical_owner"] = self.f.ref(self.history_path)
        self.approve_retirement()
        with self.assertRaisesRegex(lease.LeaseError, "Git evidence"):
            ops.retirement(self.f.ref(self.retirement_path), now=self.now)

    def test_same_path_other_repository_common_identity_refuses(self):
        self.history["common_git"] = cleanup.identity_document(self.protected)
        self.f.write_json(self.history_path, self.history)
        self.retirement["historical_owner"] = self.f.ref(self.history_path)
        self.approve_retirement()
        with self.assertRaisesRegex(lease.LeaseError, "different repository"):
            ops.retirement(self.f.ref(self.retirement_path), now=self.now)

    def test_recent_retirement_and_fresh_files_refuse(self):
        self.retirement["retired_at"] = cleanup.utc(self.now)
        self.approve_retirement()
        with self.assertRaisesRegex(lease.LeaseError, "72h retention"):
            ops.inventory([], [self.retirement_path], now=self.now)
        self.retirement["retired_at"] = cleanup.utc(self.retired_at)
        self.approve_retirement()
        with mock.patch.object(cleanup, "entry_record", self.original_entry):
            with self.assertRaisesRegex(lease.LeaseError, "whole-tree retention"):
                ops.inventory([], [self.retirement_path], now=self.now)

    def test_missing_or_mutated_approval_and_history_never_become_release(self):
        approval = Path(self.retirement["approval"]["path"])
        approval.write_bytes(approval.read_bytes() + b"\n")
        with self.assertRaisesRegex(lease.LeaseError, "changed evidence"):
            ops.inventory([], [self.retirement_path], now=self.now)
        self.approve_retirement()
        self.history_path.write_bytes(self.history_path.read_bytes() + b"\n")
        with self.assertRaisesRegex(lease.LeaseError, "changed evidence"):
            ops.inventory([], [self.retirement_path], now=self.now)
        self.history_path.unlink()
        with self.assertRaises(OSError):
            ops.inventory([], [self.retirement_path], now=self.now)

    def test_protected_types_unknown_contents_links_and_replacement_refuse(self):
        for name in ("private.p8", "SourcePackages", "trace.log", "result.xcresult", "source.swift", "unknown.bin"):
            with self.subTest(name=name):
                path = self.target / name
                path.write_bytes(b"keep")
                with self.assertRaises(lease.LeaseError):
                    ops.inventory([], [self.retirement_path], now=self.now)
                path.unlink()
        link = self.target / "linked.o"
        os.link(self.target / "one.o", link)
        with self.assertRaisesRegex(lease.LeaseError, "hard-linked"):
            ops.inventory([], [self.retirement_path], now=self.now)
        link.unlink()
        link.symlink_to(self.target / "one.o")
        with self.assertRaisesRegex(lease.LeaseError, "symlink"):
            ops.inventory([], [self.retirement_path], now=self.now)
        link.unlink()
        old = self.target.with_name("old")
        self.target.rename(old)
        self.target.mkdir()
        with self.assertRaisesRegex(lease.LeaseError, "identity changed"):
            ops.inventory([], [self.retirement_path], now=self.now)

    def test_info_attribution_mutation_and_protected_scope_overlap(self):
        self.info.write_bytes(plistlib.dumps({"WorkspacePath": "/wrong/repo/Plozz.xcodeproj"}))
        with self.assertRaisesRegex(lease.LeaseError, "attribution changed"):
            ops.validate_unit(self.f.manifest, now=self.now)
        self.info.write_bytes(plistlib.dumps({"WorkspacePath": self.history["workspace"]}))
        self.controls["protected_roots"] = [cleanup.identity_document(self.store)]
        self.approve_controls()
        with self.assertRaisesRegex(lease.LeaseError, "protected scope"):
            self.stage()
        self.assertFalse(self.stage_path.exists())
        self.assertEqual(self.marker.read_bytes(), self.marker_bytes)

    def test_control_evidence_and_journal_cannot_be_nominated_compiler_files(self):
        evidence = self.target / "one.o"
        evidence.chmod(0o600)
        self.target.chmod(0o700)
        self.make_unit()
        self.controls["coverage_evidence"] = [self.f.ref(evidence)]
        self.approve_controls()
        with self.assertRaisesRegex(lease.LeaseError, "evidence or writer"):
            self.stage()
        forbidden = self.target / "new-journal.jsonl"
        with self.assertRaisesRegex(lease.LeaseError, "artifact overlaps"):
            ops.apply_unit(self.campaign_path, self.unit_id, self.f.package["window"]["id"], forbidden)
        self.assertFalse(forbidden.exists())

    def test_campaign_requires_explicit_units_and_refuses_cross_unit_overlap(self):
        value = policy.document(self.campaign_path.read_bytes())
        value["units"].append({"id": str(uuid.uuid4()), "manifest": self.f.ref(self.f.manifest)})
        value.pop("approval")
        value["approval"] = self.approval(value, "bounded-campaign", "campaign-approval.json")
        self.f.write_json(self.campaign_path, value)
        with self.assertRaisesRegex(lease.LeaseError, "overlapping"):
            ops.campaign(self.campaign_path, self.unit_id, now=self.now)
        value["units"] = value["units"][:1]
        value.pop("approval")
        value["approval"] = self.approval(value, "bounded-campaign", "campaign-approval.json")
        self.f.write_json(self.campaign_path, value)
        with self.assertRaisesRegex(lease.LeaseError, "not explicitly reviewed"):
            ops.campaign(self.campaign_path, str(uuid.uuid4()), now=self.now)

    def test_large_landscape_is_not_a_single_unbounded_execution(self):
        for changed in ("entries", "targets"):
            value = copy.deepcopy(self.manifest)
            if changed == "entries":
                value["targets"][0]["tree"]["entries"] = 155017
            else:
                value["targets"] *= 257
            self.f.write_json(self.f.manifest, value)
            with mock.patch.object(cleanup, "scan_tree") as scan:
                with self.assertRaisesRegex(lease.LeaseError, "limit"):
                    ops.validate_unit(self.f.manifest, now=self.now)
                scan.assert_not_called()

    def test_missing_controls_missing_window_and_old_reader_refuse_staging(self):
        self.controls_path.unlink()
        with self.assertRaises(OSError):
            self.stage()
        self.make_controls()
        self.f.request.unlink()
        with self.assertRaises(OSError):
            self.stage()
        self.f.approve()
        self.legacy.write_bytes(b"#!/bin/sh\nold-v1-only-cleaner\n")
        self.make_window()
        with self.assertRaisesRegex(lease.LeaseError, "refusal stub"):
            self.stage()
        self.assertFalse(lease.paths()["rollout"].exists())

    def test_old_reader_cannot_hide_in_unclassified_global_files(self):
        rogue = self.f.repo / "unclassified.sh"
        rogue.write_bytes(b"old-reader")
        for cohort in self.f.package["cohorts"]:
            if cohort["name"] == "global-cleanup-entrypoints":
                cohort["roots"][0]["writers"].append(self.f.ref(rogue))
        self.f.approve()
        self.make_controls()
        with self.assertRaisesRegex(lease.LeaseError, "every non-library"):
            self.stage()

    def test_active_queued_attestation_and_retained_records_block_staging(self):
        self.f.approve({"plozz-current-writers": {
            "disposition": "wrapped", "active_queued": "protected-by-full-lane-shared-leases",
        }})
        self.make_controls()
        with self.assertRaisesRegex(lease.LeaseError, "active or queued"):
            self.stage()
        self.f.approve()
        self.make_controls()
        self.retained_record()
        with self.assertRaisesRegex(lease.LeaseError, "unresolved"):
            self.stage()

    def test_administrative_locks_and_suspension_are_real_gates(self):
        for key in ("lock", "registry_lock", "policy_lock"):
            fd = os.open(lease.paths()[key], os.O_RDONLY)
            try:
                lease.fcntl.flock(fd, lease.fcntl.LOCK_SH)
                with self.assertRaisesRegex(lease.LeaseError, "required lock"):
                    self.stage()
            finally:
                os.close(fd)
        self.marker.unlink()
        with self.assertRaises(OSError):
            self.stage()

    def test_legacy_public_marker_refuses_staging_without_normalization(self):
        original = self.use_legacy_marker_permissions()
        with self.assertRaisesRegex(lease.LeaseError, "SUSPENDED is group/world accessible"):
            self.stage()
        self.assert_legacy_marker_unchanged(original)
        self.assertFalse(self.stage_path.exists())
        for name in (lease.ROLLOUT_NAME, policy.POLICY_NAME, ops.CONTROLS_NAME):
            self.assertFalse((lease.paths()["root"] / name).exists())
        journal, = self.f.home.glob("stage-journal-*.jsonl")
        self.assertEqual(self.events(journal)[-1]["event"], "stopped")

    def test_legacy_public_marker_refuses_installation_without_normalization(self):
        self.stage()
        stage = policy.document(self.stage_path.read_bytes())
        approval = self.approval(stage, "install-suspended-rollout", "install-approval.json")
        original = self.use_legacy_marker_permissions()
        journal = self.f.home / "legacy-install.jsonl"
        with self.assertRaisesRegex(lease.LeaseError, "SUSPENDED is group/world accessible"):
            ops.install_prepared(self.stage_path, approval, journal, now=self.now)
        self.assert_legacy_marker_unchanged(original)
        for name in (lease.ROLLOUT_NAME, policy.POLICY_NAME, ops.CONTROLS_NAME):
            self.assertFalse((lease.paths()["root"] / name).exists())
        self.assertEqual(self.events(journal)[-1]["event"], "stopped")
        self.assertEqual(self.events(journal)[-1]["published"], [])

    def test_install_compare_and_swap_and_fsync_partial_publication(self):
        self.stage()
        stage = policy.document(self.stage_path.read_bytes())
        approval = self.approval(stage, "install-suspended-rollout", "install-approval.json")
        destination = lease.paths()["root"] / policy.POLICY_NAME
        destination.write_text("unexpected existing state")
        destination.chmod(0o600)
        with self.assertRaisesRegex(lease.LeaseError, "compare-and-swap"):
            ops.install_prepared(self.stage_path, approval, self.f.home / "cas.jsonl", now=self.now)
        self.assertEqual(destination.read_text(), "unexpected existing state")
        destination.unlink()
        with mock.patch.object(lease, "fsync_directory", side_effect=OSError("fixture sync failed")):
            with self.assertRaisesRegex(OSError, "fixture sync failed"):
                ops.install_prepared(self.stage_path, approval, self.f.home / "partial.jsonl", now=self.now)
        self.assertTrue(destination.exists())
        self.assertFalse(lease.paths()["rollout"].exists())
        self.assertEqual(self.marker.read_bytes(), self.marker_bytes)
        stopped = self.events(self.f.home / "partial.jsonl")[-1]
        self.assertEqual(stopped["published"], [policy.POLICY_NAME])
        self.assertEqual(stopped["event"], "stopped")

    def test_per_unlink_control_mutation_new_lease_and_reappearing_owner(self):
        self.install()
        for fault in ("controls", "record", "owner", "evidence"):
            with self.subTest(fault=fault):
                self.journal = self.f.home / (fault + ".jsonl")
                calls = 0
                def opened(ignored=frozenset()):
                    nonlocal calls
                    calls += 1
                    if calls == 2:
                        if fault == "controls":
                            path = lease.paths()["root"] / ops.CONTROLS_NAME
                            path.write_bytes(path.read_bytes() + b"\n")
                        elif fault == "record":
                            (lease.paths()["leases"] / "new-unknown.json").write_text("{}")
                        elif fault == "owner":
                            self.gone.mkdir()
                        else:
                            self.registry_file.write_bytes(self.registry_file.read_bytes() + b"\0")
                    return self.opened(ignored)
                with self.exclusive():
                    with self.assertRaises(lease.LeaseError):
                        self.apply(opened)
                self.assertTrue((self.target / "one.o").exists())
                self.assertEqual(self.events()[-1]["event"], "stopped")
                if fault == "controls":
                    (lease.paths()["root"] / ops.CONTROLS_NAME).write_bytes(self.controls_path.read_bytes())
                elif fault == "record":
                    (lease.paths()["leases"] / "new-unknown.json").unlink()
                elif fault == "owner":
                    self.gone.rmdir()
                else:
                    self.registry_file.write_bytes(self.registry_file.read_bytes()[:-1])

    def test_expiry_after_intent_cancellation_and_unlink_sync_failure(self):
        self.install()
        original_append = cleanup.DurableJournal.append
        expired = False
        def append(journal, event):
            nonlocal expired
            original_append(journal, event)
            if event["event"] == "remove-intent":
                expired = True
        with self.exclusive(), mock.patch.object(cleanup.DurableJournal, "append", append):
            with self.assertRaisesRegex(lease.LeaseError, "expired"):
                ops.apply_unit(
                    self.campaign_path, self.unit_id, self.f.package["window"]["id"], self.journal,
                    clock=lambda: cleanup.now_utc() + (dt.timedelta(hours=3) if expired else dt.timedelta()),
                    opened=self.opened,
                )
        self.assertTrue((self.target / "one.o").exists())
        self.assertEqual(self.events()[-1]["removed"], 0)
        self.journal = self.f.home / "cancelled.jsonl"
        unlink = os.unlink
        calls = 0
        def cancel_after_first(path, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise KeyboardInterrupt()
            return unlink(path, **kwargs)
        with self.exclusive():
            with mock.patch.object(os, "unlink", side_effect=cancel_after_first):
                with self.assertRaises(KeyboardInterrupt):
                    self.apply()
        self.assertEqual(self.events()[-1]["removed"], 1)
        self.assertEqual(self.events()[-1]["event"], "stopped")
        self.assertTrue(self.keep.exists())

    def test_open_inode_or_lost_exclusive_kernel_lock_refuses(self):
        self.install()
        with self.exclusive() as args:
            st = (self.target / "one.o").stat()
            with self.assertRaisesRegex(lease.LeaseError, "open path or inode"):
                self.apply(lambda _ignored=frozenset(): ((), frozenset({(st.st_dev, st.st_ino)})))
            self.journal = self.f.home / "unlocked.jsonl"
            lease.fcntl.flock(args.lock_fd, lease.fcntl.LOCK_UN)
            with self.assertRaisesRegex(lease.LeaseError, "exclusive kernel lock"):
                self.apply()
        self.assertTrue(self.target.exists())

    def retained_record(self):
        identity = str(uuid.uuid4())
        record = {
            "protocol": 1, "lease_id": identity, "token": str(uuid.uuid4()),
            "mode": "shared", "state": "active", "owner": "fixture/failed-lane",
            "request_pid": 2147483647, "request_start": "Synthetic former process start",
            "created_at": cleanup.utc(self.old), "cwd": str(self.gone),
            "lock_dev": lease.paths()["lock"].stat().st_dev,
            "lock_ino": lease.paths()["lock"].stat().st_ino,
            "proof_dev": 999999, "proof_ino": 999999,
            "policy_lock_dev": None, "policy_lock_ino": None, "rollout_dev": None,
            "rollout_ino": None, "rollout_sha256": None,
        }
        path = lease.record_path(identity)
        self.f.write_json(path, record)
        return path, record

    def resolution_request(self, path, record):
        f = self.f
        release = {
            "schema": 2, "record_sha256": f.ref(path)["sha256"],
            **{k: record[k] for k in ("owner", "cwd", "request_pid", "request_start")},
            "released_at": cleanup.utc(self.now), "active_queued": "none",
            "disposition": "owner-relinquished-entire-lane", "evidence": [f.ref(f.evidence)],
        }
        release_ref = f.write_json(f.home / "affirmative-release.json", release)
        request = {
            "schema": 2, "host": policy.host_identity(), "record": f.ref(path),
            "record_identity": cleanup.identity_document(path),
            "registry_sha256": ops.registry_digest(), "not_before": cleanup.utc(self.now),
            "expires_at": cleanup.utc(self.now + dt.timedelta(minutes=10)),
            "owner_release": release_ref,
        }
        request["approval"] = self.approval(request, "resolve-exact-record", "resolution-approval.json")
        request_path = f.home / "resolution.json"
        f.write_json(request_path, request)
        return request_path

    def resolve(self, path, journal=None, opened=None):
        return ops.resolve_record(path, journal or self.f.home / "resolution.jsonl",
                                  opened=opened or (lambda: ((), frozenset())))

    def test_exact_resolution_archives_original_bytes_and_preserves_other_records(self):
        path, record = self.retained_record()
        other, _ = self.retained_record()
        raw, other_raw = path.read_bytes(), other.read_bytes()
        request = self.resolution_request(path, record)
        result = self.resolve(request)
        self.assertFalse(path.exists())
        self.assertEqual((Path(result["archive"]) / "original.json").read_bytes(), raw)
        self.assertEqual(other.read_bytes(), other_raw)
        self.assertEqual(len(lease.scan_records()), 1)  # No ignore-list or schema change.
        self.assertEqual(self.marker.read_bytes(), self.marker_bytes)
        self.assertEqual(self.events(self.f.home / "resolution.jsonl")[-1]["event"], "resolved")

    def test_legacy_public_marker_refuses_resolution_without_normalization(self):
        path, record = self.retained_record()
        request = self.resolution_request(path, record)
        raw = path.read_bytes()
        original = self.use_legacy_marker_permissions()
        with self.assertRaisesRegex(lease.LeaseError, "SUSPENDED is group/world accessible"):
            self.resolve(request)
        self.assert_legacy_marker_unchanged(original)
        self.assertEqual(path.read_bytes(), raw)
        self.assertFalse((lease.paths()["root"] / "resolutions-v2").exists())
        self.assertEqual(self.events(self.f.home / "resolution.jsonl")[-1]["event"], "stopped")

    def test_resolution_then_rollout_then_unit_full_lifecycle(self):
        path, record = self.retained_record()
        with self.assertRaisesRegex(lease.LeaseError, "unresolved"):
            self.stage()
        self.resolve(self.resolution_request(path, record))
        self.assertEqual(lease.scan_records(), [])
        self.install()
        with self.exclusive():
            self.assertEqual(self.apply()["removed"], 3)
        self.assertTrue(self.keep.exists())

    def test_resolution_active_pending_owner_and_pid_reuse_refuse(self):
        path, record = self.retained_record()
        record["request_pid"] = os.getpid()
        record["request_start"] = "different start proves PID reuse, not safe retirement"
        self.f.write_json(path, record)
        request = self.resolution_request(path, record)
        with self.assertRaisesRegex(lease.LeaseError, "present or reused"):
            self.resolve(request)
        self.assertTrue(path.exists())
        record["request_pid"] = 2147483647
        self.f.write_json(path, record)
        for state in ("active", "pending", "unknown"):
            request = self.resolution_request(path, record)
            release_path = self.f.home / "affirmative-release.json"
            release = policy.document(release_path.read_bytes())
            release["active_queued"] = state
            self.f.write_json(release_path, release)
            document = policy.document(request.read_bytes())
            document["owner_release"] = self.f.ref(release_path)
            document.pop("approval")
            document["approval"] = self.approval(document, "resolve-exact-record", "resolution-approval.json")
            self.f.write_json(request, document)
            with self.assertRaisesRegex(lease.LeaseError, "active, queued, unknown"):
                self.resolve(request, self.f.home / (state + ".jsonl"))

    def test_resolution_record_mutation_new_record_and_proof_open_refuse(self):
        path, record = self.retained_record()
        request = self.resolution_request(path, record)
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(lease.LeaseError, "changed evidence"):
            self.resolve(request)
        request = self.resolution_request(path, record)
        extra, _ = self.retained_record()
        with self.assertRaisesRegex(lease.LeaseError, "registry changed"):
            self.resolve(request, self.f.home / "new-record.jsonl")
        extra.unlink()
        request = self.resolution_request(path, record)
        with self.assertRaisesRegex(lease.LeaseError, "proof inode"):
            self.resolve(request, self.f.home / "proof-open.jsonl",
                         lambda: ((), frozenset({(record["proof_dev"], record["proof_ino"])})))
        self.assertTrue(path.exists())

    def test_identical_record_bytes_on_replacement_inode_invalidate_approval(self):
        path, record = self.retained_record()
        request = self.resolution_request(path, record)
        raw = path.read_bytes()
        path.rename(self.f.home / "original-retained-record")
        path.write_bytes(raw)
        path.chmod(0o600)
        with self.assertRaisesRegex(lease.LeaseError, "original record identity changed"):
            self.resolve(request)
        self.assertEqual(path.read_bytes(), raw)

    def test_resolution_race_after_external_probe_and_held_locks_refuse(self):
        path, record = self.retained_record()
        request = self.resolution_request(path, record)
        def race():
            path.write_bytes(path.read_bytes() + b"\n")
            return ((), frozenset())
        with self.assertRaisesRegex(lease.LeaseError, "registry changed"):
            self.resolve(request, opened=race)
        request = self.resolution_request(path, record)
        for key in ("lock", "registry_lock", "policy_lock"):
            fd = os.open(lease.paths()[key], os.O_RDONLY)
            try:
                lease.fcntl.flock(fd, lease.fcntl.LOCK_SH)
                with self.assertRaisesRegex(lease.LeaseError, "required lock"):
                    self.resolve(request, self.f.home / (key + ".jsonl"))
            finally:
                os.close(fd)
        self.assertTrue(path.exists())

    def test_resolution_evidence_revoked_during_probe_refuses(self):
        path, record = self.retained_record()
        request = self.resolution_request(path, record)
        def revoked():
            self.f.evidence.write_text("affirmative release withdrawn")
            return ((), frozenset())
        with self.assertRaisesRegex(lease.LeaseError, "changed evidence"):
            self.resolve(request, opened=revoked)
        self.assertTrue(path.exists())

    def test_resolution_cancellation_preserves_archive_and_disallows_automatic_retry(self):
        path, record = self.retained_record()
        original = path.read_bytes()
        request = self.resolution_request(path, record)
        append = cleanup.DurableJournal.append
        def cancel(journal, event):
            append(journal, event)
            if event["event"] == "resolution-intent":
                raise KeyboardInterrupt()
        with mock.patch.object(cleanup.DurableJournal, "append", cancel):
            with self.assertRaises(KeyboardInterrupt):
                self.resolve(request)
        archive = lease.paths()["root"] / "resolutions-v2" / record["lease_id"]
        self.assertEqual((archive / "original.json").read_bytes(), original)
        self.assertEqual(path.read_bytes(), original)
        with self.assertRaises(FileExistsError):
            self.resolve(request, self.f.home / "no-automatic-retry.jsonl")
        self.assertEqual(self.events(self.f.home / "resolution.jsonl")[-1]["event"], "stopped")

    def test_stage_partial_write_failure_journals_inactive_outcome(self):
        with mock.patch.object(cleanup, "write_private_new", side_effect=OSError("fixture stage fsync")):
            with self.assertRaisesRegex(OSError, "stage fsync"):
                self.stage()
        journals = list(self.f.home.glob("stage-journal-*.jsonl"))
        self.assertEqual(len(journals), 1)
        self.assertEqual(self.events(journals[0])[-1]["event"], "stopped")
        self.assertFalse(lease.paths()["rollout"].exists())
        self.assertEqual(self.marker.read_bytes(), self.marker_bytes)

    def test_unit_unlink_fsync_failure_leaves_intent_and_actual_partial_count(self):
        self.install()
        fsync = os.fsync
        first = self.target / "one.o"
        def fail_parent(fd):
            if not first.exists() and cleanup.identity_stat(os.fstat(fd)) == cleanup.identity_stat(self.target.stat()):
                raise OSError("fixture deleted-file parent sync")
            return fsync(fd)
        with self.exclusive(), mock.patch.object(os, "fsync", fail_parent):
            with self.assertRaisesRegex(OSError, "deleted-file parent sync"):
                self.apply()
        self.assertFalse(first.exists())
        self.assertEqual(self.events()[-1]["removed"], 1)
        self.assertIn("remove-intent", [e["event"] for e in self.events()])
        self.assertTrue(self.keep.exists())

    def test_resolution_hardlink_and_archive_write_failure_keep_record(self):
        path, record = self.retained_record()
        request = self.resolution_request(path, record)
        link = self.f.home / "record-hardlink"
        os.link(path, link)
        with self.assertRaisesRegex(lease.LeaseError, "hard link"):
            self.resolve(request)
        link.unlink()
        with mock.patch.object(ops, "namespace_write_new", side_effect=OSError("fixture disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.resolve(request, self.f.home / "write-failure.jsonl")
        self.assertTrue(path.exists())
        self.assertEqual(self.marker.read_bytes(), self.marker_bytes)
        self.assertFalse(self.events(self.f.home / "write-failure.jsonl")[-1]["removed"])

    def test_resolution_partial_write_loops_and_post_unlink_fsync_is_journaled(self):
        path, record = self.retained_record()
        original = path.read_bytes()
        request = self.resolution_request(path, record)
        write = os.write
        def short(fd, data):
            return write(fd, data[:max(1, len(data) // 2)])
        with mock.patch.object(os, "write", short):
            result = self.resolve(request)
        self.assertEqual((Path(result["archive"]) / "original.json").read_bytes(), original)
        path, record = self.retained_record()
        request = self.resolution_request(path, record)
        fsync = os.fsync
        def failure(fd):
            if not path.exists() and cleanup.identity_stat(os.fstat(fd)) == cleanup.identity_stat(lease.paths()["leases"].stat()):
                raise OSError("fixture registry sync failed")
            return fsync(fd)
        with mock.patch.object(os, "fsync", failure):
            with self.assertRaisesRegex(OSError, "registry sync"):
                self.resolve(request, self.f.home / "post-unlink.jsonl")
        self.assertFalse(path.exists())
        self.assertTrue(self.events(self.f.home / "post-unlink.jsonl")[-1]["removed"])
        self.assertEqual(self.marker.read_bytes(), self.marker_bytes)

    def test_cli_has_no_activation_force_or_test_age_switch(self):
        result = subprocess.run(
            [sys.executable, "-B", str(ROOT / "tools/apple-build-operations.py"), "--help"],
            text=True, capture_output=True, env=self.f.env, check=True,
        )
        self.assertIn("install-prepared", result.stdout)
        self.assertNotIn("--force", result.stdout)
        self.assertNotIn("resume", result.stdout)
        self.assertEqual(self.marker.read_bytes(), self.marker_bytes)
        for name, expected in policy.PROTOCOL_FILES.items():
            self.assertEqual(policy.digest((ROOT / name).read_bytes()), expected)

    def test_41_store_three_explicit_units_real_per_unlink_lifecycle(self):
        """328 tiny compiler files, 41 roots, 3 separately approved windows.

        This is not a production throughput estimate: host ps/lsof are fixture
        observations and timestamps are aged in memory. All safety validators,
        Git calls, real locks, fsyncs and exact deletions run for every entry.
        """
        f = self.f
        units, roots = [], []
        for index in range(41):
            store = self.derived / f"Plozz-scale-{index:02}"
            store.mkdir()
            (store / "info.plist").write_bytes(self.info.read_bytes())
            target = store / "Build/Intermediates.noindex/compiler"
            target.mkdir(parents=True)
            for item in range(8):
                (target / f"{item}.o").write_bytes(b"x")
            (store / "Logs").mkdir()
            (store / "Logs/retain.log").write_bytes(b"retained")
            roots.append(target)
        for index, selected in enumerate((roots[:16], roots[16:32], roots[32:])):
            record = copy.deepcopy(self.retirement)
            record.pop("approval")
            record["targets"] = [self.retired_target(path) for path in selected]
            record["approval"] = self.approval(
                record, "retire-missing-owner", f"scale-retirement-approval-{index}.json", self.retired_at,
            )
            path = f.home / f"scale-retirement-{index}.json"
            f.write_json(path, record)
            manifest = ops.inventory([], [path], now=self.now)
            unit_path = f.home / f"scale-unit-{index}.json"
            f.write_json(unit_path, manifest)
            units.append({"id": str(uuid.uuid4()), "manifest": f.ref(unit_path)})
        campaign = {"schema": 2, "units": units, "reviewed_at": cleanup.utc(self.now)}
        campaign["approval"] = self.approval(campaign, "bounded-campaign", "scale-approval.json")
        f.write_json(self.campaign_path, campaign)
        started = time.monotonic()
        count = 0
        policy_checks = 0
        with mock.patch.object(policy, "check", wraps=policy.check) as checks:
            for index, unit in enumerate(units):
                f.manifest = Path(unit["manifest"]["path"])
                self.manifest = policy.document(f.manifest.read_bytes())
                self.unit_id = unit["id"]
                self.make_window()
                self.stage_path = f.home / f"scale-stage-{index}.json"
                self.stage()
                stage = policy.document(self.stage_path.read_bytes())
                ref = self.approval(stage, "install-suspended-rollout", f"scale-install-{index}.json")
                ops.install_prepared(self.stage_path, ref, f.home / f"scale-install-{index}.jsonl", now=self.now)
                self.journal = f.home / f"scale-delete-{index}.jsonl"
                with self.exclusive():
                    count += self.apply()["removed"]
            policy_checks = checks.call_count
        self.assertEqual(count, 41 * 9)
        self.assertGreaterEqual(policy_checks, 2 * count)
        self.assertTrue(all(not path.exists() for path in roots))
        self.assertTrue(all((path.parents[2] / "Logs/retain.log").exists() for path in roots))
        self.assertTrue(self.target.exists())  # Not silently swept into this campaign.
        print(json.dumps({
            "fixture": "41-store-explicit-campaign", "units": 3, "compiler_files": 328,
            "removed_entries": count, "policy_checks": policy_checks,
            "elapsed_seconds": round(time.monotonic() - started, 3),
        }), flush=True)


if __name__ == "__main__":
    unittest.main()
