#!/usr/bin/env python3
"""Regressions for the independent review of the original operational layer."""

import copy
import json
import os
from pathlib import Path
import shutil
import unittest
from unittest import mock
import uuid

from tools.tests import test_apple_build_operations as fixtures

ops, cleanup, lease, policy = fixtures.ops, fixtures.cleanup, fixtures.lease, fixtures.policy


class OperationalReviewTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.OperationalTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.f = self.fixture.f

    def second_unit(self, evidence: Path, *, retired=False):
        f, x = self.f, self.fixture
        if retired:
            target = x.target.with_name("second-compiler")
            target.mkdir()
            (target / "second.o").write_bytes(b"second")
            history = copy.deepcopy(x.history)
            history["evidence"] = [f.ref(evidence)]
            history_path = f.home / "second-history.json"
            f.write_json(history_path, history)
            release = copy.deepcopy(x.retirement)
            release.pop("approval")
            release["historical_owner"] = f.ref(history_path)
            release["targets"] = [x.retired_target(target)]
            release["approval"] = x.approval(
                release, "retire-missing-owner", "second-retirement-approval.json", x.retired_at,
            )
            release_path = f.home / "second-retirement.json"
            f.write_json(release_path, release)
            manifest = ops.inventory([], [release_path], now=x.now)
        else:
            target = f.repo / ".build/second"
            target.mkdir(parents=True)
            (target / "second.o").write_bytes(b"second")
            release = {
                "schema": 1, "scope": cleanup.SCOPE, "owner": "fixture/second",
                "session_id": str(uuid.uuid4()), "released_at": cleanup.utc(x.retired_at),
                "worktree": cleanup.identity_document(f.repo), "evidence": [f.ref(evidence)],
                "targets": [{"kind": "worktree-apple-build", "identity": cleanup.identity_document(target)}],
            }
            release_path = f.home / "second-release.json"
            f.write_json(release_path, release)
            manifest = ops.inventory([release_path], [], now=x.now)
        path = f.home / "second-unit.json"
        f.write_json(path, manifest)
        campaign = {
            "schema": 2, "reviewed_at": cleanup.utc(x.now), "units": [
                {"id": x.unit_id, "manifest": f.ref(f.manifest)},
                {"id": str(uuid.uuid4()), "manifest": f.ref(path)},
            ],
        }
        campaign["approval"] = x.approval(campaign, "bounded-campaign", "campaign-approval.json")
        f.write_json(x.campaign_path, campaign)
        return path, campaign["units"][1]["id"]

    def test_cross_unit_existing_release_evidence_cannot_be_deleted(self):
        x = self.fixture
        evidence = x.target / "one.o"
        evidence.chmod(0o600)
        x.make_unit()
        self.second_unit(evidence)
        with self.assertRaisesRegex(lease.LeaseError, "campaign evidence overlaps"):
            ops.campaign(x.campaign_path, x.unit_id, now=x.now)
        self.assertTrue(evidence.exists())

    def test_cross_unit_nested_historical_evidence_cannot_be_deleted(self):
        x = self.fixture
        evidence = x.target / "one.o"
        evidence.chmod(0o600)
        x.make_unit()
        self.second_unit(evidence, retired=True)
        with self.assertRaisesRegex(lease.LeaseError, "campaign evidence overlaps"):
            ops.campaign(x.campaign_path, x.unit_id, now=x.now)
        self.assertTrue(evidence.exists())

    def test_nonselected_reference_mutation_stops_current_unit_before_unlink(self):
        x, f = self.fixture, self.f
        evidence = f.home / "second-only-evidence.txt"
        evidence.write_bytes(b"independently bound owner evidence")
        evidence.chmod(0o600)
        self.second_unit(evidence)
        x.install()
        calls = 0
        def opened(ignored=frozenset()):
            nonlocal calls
            calls += 1
            if calls == 2:
                evidence.write_bytes(b"owner withdrew this evidence")
            return x.opened(ignored)
        with x.exclusive():
            with self.assertRaisesRegex(lease.LeaseError, "changed evidence"):
                x.apply(opened)
        self.assertTrue((x.target / "one.o").exists())
        self.assertEqual(x.events()[-1]["removed"], 0)

    def test_completed_unit_targets_need_not_exist_to_validate_next_unit(self):
        x, f = self.fixture, self.f
        path, unit_id = self.second_unit(f.evidence, retired=True)
        shutil.rmtree(x.target)  # This fixture's exact two compiler files only.
        self.assertEqual(ops.campaign(x.campaign_path, unit_id, now=x.now), path)
        ops.validate_unit(path, now=x.now)

    def test_first_resolution_fsyncs_archive_parent_before_live_record_unlink(self):
        x = self.fixture
        record_path, record = x.retained_record()
        request = x.resolution_request(record_path, record)
        order = []
        sync, unlink = lease.fsync_directory, os.unlink
        def synced(path):
            order.append(("sync", Path(path)))
            return sync(path)
        def removed(path, **kwargs):
            if path == record_path.name:
                order.append(("remove", record_path))
            return unlink(path, **kwargs)
        with mock.patch.object(lease, "fsync_directory", synced), mock.patch.object(os, "unlink", removed):
            x.resolve(request)
        parent_sync = order.index(("sync", lease.paths()["root"]))
        removal = order.index(("remove", record_path))
        self.assertLess(parent_sync, removal)
        self.assertTrue((lease.paths()["root"] / "resolutions-v2" / record["lease_id"] / "original.json").exists())

    def test_archive_parent_fsync_failure_preserves_live_record(self):
        x = self.fixture
        record_path, record = x.retained_record()
        original = record_path.read_bytes()
        request = x.resolution_request(record_path, record)
        sync = lease.fsync_directory
        def failed(path):
            if Path(path) == lease.paths()["root"]:
                raise OSError("fixture new archive root was not synced")
            return sync(path)
        with mock.patch.object(lease, "fsync_directory", failed):
            with self.assertRaisesRegex(OSError, "archive root"):
                x.resolve(request)
        self.assertEqual(record_path.read_bytes(), original)
        events = x.events(self.f.home / "resolution.jsonl")
        self.assertEqual(events[-1]["event"], "stopped")
        self.assertFalse(events[-1]["removed"])

    def test_installation_only_evidence_revocation_stops_publication(self):
        x, f = self.fixture, self.f
        x.stage()
        stage = policy.document(x.stage_path.read_bytes())
        ref = x.approval(stage, "install-suspended-rollout", "install-approval.json")
        evidence = f.home / "installation-only-evidence.txt"
        evidence.write_bytes(b"affirmative installation permission")
        evidence.chmod(0o600)
        approval = policy.document(Path(ref["path"]).read_bytes())
        approval["evidence"] = [f.ref(evidence)]
        ref = f.write_json(Path(ref["path"]), approval)
        publish = ops.namespace_write_new
        def revoked(path, data):
            publish(path, data)
            if path.name == ".operations-" + policy.POLICY_NAME:
                evidence.write_bytes(b"installation permission withdrawn")
        with mock.patch.object(ops, "namespace_write_new", revoked):
            with self.assertRaisesRegex(lease.LeaseError, "changed evidence"):
                ops.install_prepared(x.stage_path, ref, f.home / "revoked-install.jsonl", now=x.now)
        self.assertFalse((lease.paths()["root"] / policy.POLICY_NAME).exists())
        self.assertFalse(lease.paths()["rollout"].exists())
        self.assertEqual(x.marker.read_bytes(), x.marker_bytes)
        self.assertEqual(x.events(f.home / "revoked-install.jsonl")[-1]["event"], "stopped")


if __name__ == "__main__":
    unittest.main()
