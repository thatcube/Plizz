#!/usr/bin/env python3
"""Approval, real frozen-wrapper, crash and rollback fixtures for activation."""

import json
import os
from pathlib import Path
import signal
import subprocess
import time
import unittest
from unittest import mock
import uuid

from tools.tests import test_apple_build_operations as fixtures
import apple_build_activation as activation

ops, cleanup, lease, policy = fixtures.ops, fixtures.cleanup, fixtures.lease, fixtures.policy


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.x = fixtures.OperationalTests()
        self.x.setUp()
        self.addCleanup(self.x.doCleanups)
        self.f = self.x.f
        self.x.install()
        self.request, self.approval, self.journal = self.x.activation_request()

    def run_activation(self, fault=""):
        result, _, _ = self.x.run_activation(
            self.request, self.approval, self.journal, fault=fault,
        )
        return result

    def reapprove(self, request):
        self.f.write_json(self.request, request)
        self.approval = self.x.approval(
            request, "activate-installed-window", "reapproved-activation.json",
        )

    def assert_refused(self, fault="", message=None, *, suspended=True):
        result = self.run_activation(fault)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        if message:
            self.assertIn(message, result.stderr)
        self.assertTrue(lease.scan_records(), "failed frozen wrapper must retain its real lane record")
        if suspended:
            self.assertTrue(self.x.marker.exists(), result.stderr)
        self.assertTrue((self.x.target / "one.o").exists())
        return result

    def test_actual_wrapper_upgrades_and_cleanly_finalizes_before_apply(self):
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.x.marker.exists())
        self.assertEqual(lease.scan_records(), [])
        receipt = activation.binding(lease.paths()["root"] / activation.RECEIPT_NAME)
        activation.validate_receipt(
            receipt, self.f.manifest, self.x.campaign_path, self.x.unit_id,
            self.f.package["window"]["id"], now=cleanup.now_utc(),
        )
        with self.x.exclusive():
            self.assertEqual(self.x.apply()["removed"], 3)
        self.assertTrue(self.x.keep.exists())

    def test_legacy_public_directory_with_private_marker_supports_guarded_lifecycle(self):
        self.x.marker.parent.chmod(0o755)
        self.test_actual_wrapper_upgrades_and_cleanly_finalizes_before_apply()
        self.assertEqual(self.x.marker.parent.stat().st_mode & 0o777, 0o755)

    def test_legacy_public_marker_refuses_activation_snapshot_without_normalization(self):
        original = self.x.use_legacy_marker_permissions()
        with self.assertRaisesRegex(lease.LeaseError, "SUSPENDED is group/world accessible"):
            self.x.activation_request()
        self.x.assert_legacy_marker_unchanged(original)
        self.assertEqual(lease.scan_records(), [])
        self.assertFalse((lease.paths()["root"] / activation.RECEIPT_NAME).exists())
        self.assertFalse((lease.paths()["root"] / activation.ARCHIVE_NAME).exists())

    def test_legacy_public_marker_refuses_real_activation_without_normalization(self):
        original = self.x.use_legacy_marker_permissions()
        self.assert_refused(message="SUSPENDED is group/world accessible")
        self.x.assert_legacy_marker_unchanged(original)
        self.assertFalse((lease.paths()["root"] / activation.RECEIPT_NAME).exists())
        self.assertFalse((lease.paths()["root"] / activation.ARCHIVE_NAME).exists())

    def test_missing_activation_approval(self):
        Path(self.approval["path"]).unlink()
        self.assert_refused(message="No such file")

    def test_forged_activation_approval(self):
        path = Path(self.approval["path"])
        value = policy.document(path.read_bytes())
        value["payload_sha256"] = "0" * 64
        self.f.write_json(path, value)
        self.assert_refused(message="approval does not bind")

    def test_stale_activation_approval(self):
        path = Path(self.approval["path"])
        value = policy.document(path.read_bytes())
        value["approved_at"] = cleanup.utc(self.x.old)
        self.f.write_json(path, value)
        self.assert_refused(message="approval predates")

    def test_wrong_host_even_with_new_approval(self):
        request = policy.document(self.request.read_bytes())
        request["host"]["uid"] += 1
        self.reapprove(request)
        self.assert_refused(message="host identity changed")

    def test_wrong_stage_bytes(self):
        self.x.stage_path.write_bytes(self.x.stage_path.read_bytes() + b"\n")
        self.assert_refused(message="changed evidence")

    def test_wrong_installed_bytes(self):
        path = lease.paths()["root"] / ops.CONTROLS_NAME
        path.write_bytes(path.read_bytes() + b"\n")
        self.assert_refused(message="changed evidence")

    def test_replaced_suspension_with_identical_bytes(self):
        self.x.marker.rename(self.f.home / "original-marker")
        self.x.marker.write_bytes(self.x.marker_bytes)
        self.x.marker.chmod(0o600)
        self.assert_refused(message="activation input identity changed")

    def test_expired_activation_deadline(self):
        request = policy.document(self.request.read_bytes())
        request["expires_at"] = cleanup.utc(self.x.old)
        self.reapprove(request)
        self.assert_refused(message="activation expired")

    def test_modified_legacy_cleanup_route(self):
        self.x.legacy.write_bytes(b"#!/bin/sh\nold cleanup path is enabled\n")
        self.assert_refused(message="writer changed")

    def test_owner_attestation_withdrawal_is_not_process_inactivity(self):
        owner = self.f.home / "plozz-current-writers.json"
        value = policy.document(owner.read_bytes())
        value["active_queued"] = "unknown"
        self.f.write_json(owner, value)
        self.assert_refused(message="changed evidence")

    def test_actual_active_queued_owner_state_refuses_fresh_snapshot(self):
        self.f.approve({"plozz-current-writers": {
            "disposition": "wrapped", "active_queued": "protected-by-full-lane-shared-leases",
        }})
        self.x.make_controls()
        stage = policy.document(self.x.stage_path.read_bytes())
        stage["window"], stage["controls"] = self.f.ref(self.f.request), self.f.ref(self.x.controls_path)
        self.f.write_json(self.x.stage_path, stage)
        self.f.write_json(lease.paths()["root"] / policy.POLICY_NAME, self.f.package)
        self.f.write_json(lease.paths()["root"] / ops.CONTROLS_NAME, self.x.controls)
        with self.assertRaisesRegex(lease.LeaseError, "active or queued"):
            self.x.activation_request()
        self.assertEqual(lease.scan_records(), [])
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)

    def test_suspension_replacement_during_slow_probe(self):
        self.assert_refused("probe-suspension", message="activation input identity changed")
        self.assertEqual(self.x.marker.read_bytes(), b"replacement suspension")

    def test_target_replacement_during_slow_probe(self):
        self.assert_refused("probe-target", message="changed since inventory")

    def test_new_record_during_slow_probe(self):
        self.assert_refused("probe-new-record", message="zero other active or retained records")
        self.assertEqual(len(lease.scan_records()), 2)

    def test_existing_retained_record_is_not_ignored_as_own_lane(self):
        original, _ = self.x.retained_record()
        original_bytes = original.read_bytes()
        self.assert_refused(message="zero other active or retained records")
        self.assertEqual(original.read_bytes(), original_bytes)

    def test_existing_inherited_policy_shared_holder_refuses_upgrade(self):
        self.assert_refused("inherited-policy-lock", message="conflicts with a writer")

    def test_external_policy_shared_holder_refuses_nonblocking(self):
        fd = os.open(lease.paths()["policy_lock"], os.O_RDONLY)
        try:
            lease.fcntl.flock(fd, lease.fcntl.LOCK_SH)
            self.assert_refused(message="conflicts with a writer")
        finally:
            os.close(fd)

    def test_held_registry_lock_refuses_after_actual_frozen_authentication(self):
        self.assert_refused("inherited-registry-lock", message="conflicts with a writer")

    def test_second_kernel_reader_refuses_nonblocking_coordination_upgrade(self):
        self.assert_refused("inherited-coordination-lock", message="conflicts with a writer")

    def test_shared_lane_with_unexpected_policy_capability_refuses(self):
        self.assert_refused("unexpected-policy-capability", message="cannot inherit maintenance")

    def test_distinct_activation_only_evidence_revocation_after_fsync(self):
        evidence = self.f.home / "activation-only-evidence.txt"
        evidence.write_bytes(b"new affirmative activation approval")
        evidence.chmod(0o600)
        path = Path(self.approval["path"])
        approval = policy.document(path.read_bytes())
        approval["evidence"] = [self.f.ref(evidence)]
        self.f.write_json(path, approval)
        self.assert_refused("approval-evidence", message="changed evidence")
        self.assertFalse((lease.paths()["root"] / activation.RECEIPT_NAME).exists())

    def distinct_evidence(self):
        evidence = self.f.home / "independent-activation-evidence.txt"
        evidence.write_bytes(b"explicit activation permission")
        evidence.chmod(0o600)
        path = Path(self.approval["path"])
        approval = policy.document(path.read_bytes())
        approval["evidence"] = [self.f.ref(evidence)]
        self.f.write_json(path, approval)

    def reinstall_reviewed_inputs(self):
        self.x.stage_path = self.f.home / ("restaged-" + str(uuid.uuid4()) + ".json")
        self.x.stage()
        stage = policy.document(self.x.stage_path.read_bytes())
        approval = self.x.approval(stage, "install-suspended-rollout", "reinstall-approval.json")
        ops.install_prepared(
            self.x.stage_path, approval, self.f.home / ("reinstall-" + str(uuid.uuid4()) + ".jsonl"),
            now=self.x.now,
        )
        self.request, self.approval, self.journal = self.x.activation_request()

    def nominated_activation_evidence(self, *, cross_unit):
        target = self.x.target
        if cross_unit:
            target = target.with_name("second-compiler")
            target.mkdir()
            (target / "one.o").write_bytes(b"independent activation permission")
            self.x.retirement["targets"].append(self.x.retired_target(target))
            self.x.approve_retirement()
        evidence = target / "one.o"
        evidence.chmod(0o600)
        full = ops.inventory([], [self.x.retirement_path], now=self.x.now)
        self.x.manifest = {**full, "targets": full["targets"][:1]}
        self.f.write_json(self.f.manifest, self.x.manifest)
        units = [{"id": self.x.unit_id, "manifest": self.f.ref(self.f.manifest)}]
        if cross_unit:
            second = self.f.home / "second-unit.json"
            self.f.write_json(second, {**full, "targets": full["targets"][1:]})
            units.append({"id": str(uuid.uuid4()), "manifest": self.f.ref(second)})
        campaign = {"schema": 2, "units": units, "reviewed_at": cleanup.utc(self.x.now)}
        campaign["approval"] = self.x.approval(campaign, "bounded-campaign", "campaign-approval.json")
        self.f.write_json(self.x.campaign_path, campaign)
        self.x.make_window()
        self.reinstall_reviewed_inputs()
        return evidence

    def assert_activation_evidence_overlap_refused(self, *, cross_unit):
        evidence = self.nominated_activation_evidence(cross_unit=cross_unit)
        path = Path(self.approval["path"])
        approval = policy.document(path.read_bytes())
        approval["evidence"] = [self.f.ref(evidence)]
        self.f.write_json(path, approval)
        self.assert_refused(message="activation authority overlaps a campaign target")
        self.assertTrue(evidence.exists())
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)
        self.assertFalse((lease.paths()["root"] / activation.RECEIPT_NAME).exists())
        self.assertFalse((lease.paths()["root"] / activation.ARCHIVE_NAME).exists())

    def test_selected_unit_activation_approval_evidence_cannot_be_deleted(self):
        self.assert_activation_evidence_overlap_refused(cross_unit=False)

    def test_cross_unit_activation_approval_evidence_cannot_be_deleted(self):
        self.assert_activation_evidence_overlap_refused(cross_unit=True)

    def assert_legacy_receipt_evidence_overlap_refused(self, *, cross_unit):
        evidence = self.nominated_activation_evidence(cross_unit=cross_unit)
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt_path = lease.paths()["root"] / activation.RECEIPT_NAME
        receipt = policy.document(receipt_path.read_bytes())
        approval_path = Path(self.approval["path"])
        approval = policy.document(approval_path.read_bytes())
        approval["evidence"] = [self.f.ref(evidence)]
        # Model an internally consistent receipt from the previously vulnerable
        # implementation. Its archived copy must not exempt the live authority.
        for key, path in (
            ("live_approval", approval_path),
            ("approval", Path(receipt["approval"]["identity"]["path"])),
        ):
            self.f.write_json(path, approval)
            receipt[key] = activation.binding(path)
        self.f.write_json(receipt_path, receipt)
        with self.assertRaisesRegex(lease.LeaseError, "activation authority overlaps a campaign target"):
            activation.validate_receipt(
                activation.binding(receipt_path), self.f.manifest, self.x.campaign_path,
                self.x.unit_id, self.f.package["window"]["id"], now=cleanup.now_utc(),
            )
        with self.x.exclusive():
            with self.assertRaisesRegex(lease.LeaseError, "activation authority overlaps a campaign target"):
                self.x.apply()
        self.assertEqual(self.x.events()[-1]["removed"], 0)
        self.assertTrue(evidence.exists())

    def test_selected_unit_legacy_receipt_cannot_exempt_live_activation_evidence(self):
        self.assert_legacy_receipt_evidence_overlap_refused(cross_unit=False)

    def test_cross_unit_legacy_receipt_cannot_exempt_live_activation_evidence(self):
        self.assert_legacy_receipt_evidence_overlap_refused(cross_unit=True)

    def assert_final_authority_census_refused(self, *, owner, completion):
        evidence = self.f.home / ("independent-owner.txt" if owner else "independent-window.txt")
        evidence.write_bytes(b"independent affirmative permission")
        evidence.chmod(0o600)
        if owner:
            self.f.approve({"plozz-current-writers": {"evidence": [self.f.ref(evidence)]}})
        else:
            path = Path(self.f.package["approval"]["path"])
            approval = policy.document(path.read_bytes())
            approval["evidence"] = self.f.ref(evidence)
            self.f.package["approval"] = self.f.write_json(path, approval)
            self.f.write_json(self.f.request, self.f.package)
        self.x.make_controls()
        self.reinstall_reviewed_inputs()
        kind, phase = ("owner" if owner else "window"), ("completion" if completion else "publication")
        self.assert_refused(f"{kind}-evidence-{phase}-census", message="changed evidence")
        self.assertIn(b"withdrawn in final census", evidence.read_bytes())
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)
        self.assertEqual(self.x.events(self.journal)[-1]["suspension"], "restored")
        receipt = policy.document((lease.paths()["root"] / activation.RECEIPT_NAME).read_bytes())
        self.assertEqual(receipt["state"], "active" if completion else "pending")
        self.assert_failed_receipt()

    def test_owner_evidence_withdrawn_in_final_publication_census_restores_suspension(self):
        self.assert_final_authority_census_refused(owner=True, completion=False)

    def test_owner_evidence_withdrawn_in_final_completion_census_restores_suspension(self):
        self.assert_final_authority_census_refused(owner=True, completion=True)

    def test_window_evidence_withdrawn_in_final_publication_census_restores_suspension(self):
        self.assert_final_authority_census_refused(owner=False, completion=False)

    def test_window_evidence_withdrawn_in_final_completion_census_restores_suspension(self):
        self.assert_final_authority_census_refused(owner=False, completion=True)

    def test_post_census_authority_recheck_uses_no_external_probes(self):
        request = policy.document(self.request.read_bytes())
        with mock.patch.object(ops, "git", side_effect=AssertionError("late Git probe")), \
             mock.patch.object(policy, "worktree_snapshot", side_effect=AssertionError("late registry probe")), \
             mock.patch.object(lease, "process_start", side_effect=AssertionError("late process census")), \
             mock.patch.object(cleanup, "require_no_build_activity", side_effect=AssertionError("late activity probe")), \
             mock.patch.object(cleanup, "open_file_inventory", side_effect=AssertionError("late lsof probe")):
            activation.validate_authority(
                request, activation.binding(self.request), activation.binding(Path(self.approval["path"])),
                self.journal, now=cleanup.now_utc(),
            )

    def test_activation_evidence_withdrawn_in_last_requester_census_prevents_transition(self):
        self.distinct_evidence()
        self.assert_refused("approval-after-requester-census", message="changed evidence")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)
        self.assertFalse(self.x.events(self.journal)[-1]["transition_attempted"])

    def test_activation_evidence_withdrawn_while_syncing_active_receipt_prevents_publication(self):
        self.distinct_evidence()
        self.assert_refused("active-approval-evidence", message="changed evidence")
        value = policy.document((lease.paths()["root"] / activation.RECEIPT_NAME).read_bytes())
        self.assertEqual(value["state"], "pending")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)

    def test_original_archive_write_failure_retains_marker_and_lease(self):
        self.assert_refused("archive-write", message="original preservation failed")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)

    def test_new_archive_parent_fsync_failure_prevents_transition(self):
        self.assert_refused("archive-parent-fsync", message="archive parent sync failed")
        self.assertFalse((lease.paths()["root"] / activation.RECEIPT_NAME).exists())
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)

    def test_direct_call_without_actual_activation_lane_is_journaled_and_refused(self):
        with self.assertRaisesRegex(lease.LeaseError, "dedicated inherited"):
            activation.activate(self.request, self.approval, self.journal, opened=self.x.opened)
        self.assertEqual(lease.scan_records(), [])
        self.assertEqual(self.x.events(self.journal)[-1]["event"], "activation-stopped")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)

    def test_short_writes_produce_exact_originals_and_completed_receipt(self):
        result = self.run_activation("short-write")
        self.assertEqual(result.returncode, 0, result.stderr)
        request = policy.document(self.request.read_bytes())
        archive = lease.paths()["root"] / activation.ARCHIVE_NAME / request["activation_id"]
        self.assertEqual((archive / "request.json").read_bytes(), self.request.read_bytes())
        self.assertEqual((archive / "suspension-original").read_bytes(), self.x.marker_bytes)
        self.assertEqual(lease.scan_records(), [])

    def test_zero_write_after_transition_restores_preallocated_suspension(self):
        self.assert_refused("zero-write-after-transition", message="short write")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)

    def test_marker_directory_fsync_failure_restores_suspension(self):
        self.assert_refused("transition-fsync", message="directory fsync failed")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)
        self.assertEqual(self.x.events(self.journal)[-1]["suspension"], "restored")

    def test_uncertain_receipt_publication_is_fenced_and_restored(self):
        self.assert_refused("receipt-fsync", message="receipt publication uncertain")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)
        self.assert_failed_receipt()

    def assert_failed_receipt(self):
        request = policy.document(self.request.read_bytes())
        archive = lease.paths()["root"] / activation.ARCHIVE_NAME / request["activation_id"]
        self.assertTrue((archive / "FAILED").exists())
        self.assertEqual((archive / "suspension-original").read_bytes(), self.x.marker_bytes)

    def test_rollback_never_overwrites_concurrent_suspension(self):
        self.assert_refused("concurrent-marker", message="post-transition failure")
        self.assertEqual(self.x.marker.read_bytes(), b"concurrent fixture suspension")
        self.assertEqual(self.x.events(self.journal)[-1]["suspension"], "concurrent-marker-preserved")

    def test_rollback_io_failure_keeps_receipt_and_real_lease_fences(self):
        self.assert_refused("restore-fails", message="post-transition failure", suspended=False)
        self.assertFalse(self.x.marker.exists())
        self.assert_failed_receipt()
        self.assert_exclusive_refused()
        self.assertIn("uncertain", self.x.events(self.journal)[-1]["suspension"])

    def assert_exclusive_refused(self):
        result = subprocess.run([
            "/bin/bash", str(self.f.repo / "tools/with-apple-build-lease.sh"),
            "--exclusive", "fixture/cleanup-probe", "--", "/usr/bin/true",
        ], env=self.f.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lease.scan_records())

    def test_cancel_before_marker_transition(self):
        self.assert_refused("cancel-intent")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)
        self.assert_failed_receipt()

    def test_cancel_after_marker_transition(self):
        self.assert_refused("cancel-transition")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)
        self.assert_failed_receipt()

    def test_cancel_after_receipt_publication(self):
        self.assert_refused("cancel-receipt")
        self.assertEqual(self.x.marker.read_bytes(), self.x.marker_bytes)
        self.assert_failed_receipt()

    def crash(self, phase, suspended):
        self.assert_refused("crash-" + phase, suspended=suspended)
        if not suspended:
            self.assertFalse(self.x.marker.exists())
            self.assert_exclusive_refused()

    def test_worker_crash_before_transition_retains_real_activation_record(self):
        self.crash("intent", True)

    def test_worker_crash_after_transition_retains_real_activation_record(self):
        self.crash("transition", False)

    def test_worker_crash_after_active_receipt_cannot_authorize_cleanup(self):
        self.crash("receipt", False)
        value = policy.document((lease.paths()["root"] / activation.RECEIPT_NAME).read_bytes())
        self.assertEqual(value["state"], "active")
        with self.assertRaisesRegex(lease.LeaseError, "not cleanly finalized"):
            activation.validate_receipt(
                activation.binding(lease.paths()["root"] / activation.RECEIPT_NAME),
                self.f.manifest, self.x.campaign_path, self.x.unit_id,
                self.f.package["window"]["id"], now=cleanup.now_utc(),
            )

    def test_retry_does_not_clear_or_reuse_failed_transaction(self):
        self.assert_refused("cancel-intent")
        records = {r["lease_id"]: lease.record_path(r["lease_id"]).read_bytes() for r in lease.scan_records()}
        command, _ = self.x.activation_command(
            self.request, self.approval, self.f.home / "retry.jsonl",
        )
        result = subprocess.run(command, env=self.f.env, capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("zero other active or retained records", result.stderr)
        for identity, raw in records.items():
            self.assertEqual(lease.record_path(identity).read_bytes(), raw)

    def test_reusing_successful_activation_id_does_not_modify_prior_archive(self):
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        original = policy.document(self.request.read_bytes())
        archive = lease.paths()["root"] / activation.ARCHIVE_NAME / original["activation_id"]
        preserved = {path.name: path.read_bytes() for path in archive.iterdir()}
        with policy.policy_update_lock():
            self.x.marker.write_bytes(self.x.marker_bytes)
            self.x.marker.chmod(0o600)
        request = activation.activation_inputs(
            self.x.stage_path, self.x.campaign_path, self.x.unit_id, str(uuid.uuid4()),
            opened=self.x.opened,
        )
        request["activation_id"] = original["activation_id"]
        path = self.f.home / "reused-id-request.json"
        self.f.write_json(path, request)
        approval = self.x.approval(request, "activate-installed-window", "reused-id-approval.json",
                                   at=cleanup.now_utc())
        result, _, _ = self.x.run_activation(path, approval, self.f.home / "reused-id.jsonl")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("File exists", result.stderr)
        self.assertEqual({path.name: path.read_bytes() for path in archive.iterdir()}, preserved)

    def test_receipt_mutation_is_checked_by_every_apply(self):
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = lease.paths()["root"] / activation.RECEIPT_NAME
        value = policy.document(receipt.read_bytes())
        value["state"] = "pending"
        self.f.write_json(receipt, value)
        with self.x.exclusive():
            with self.assertRaisesRegex(lease.LeaseError, "no completed receipt"):
                self.x.apply()
        self.assertTrue((self.x.target / "one.o").exists())

    def interrupt_parent(self, phase):
        command, status = self.x.activation_command(
            self.request, self.approval, self.journal, fault="pause-" + phase,
        )
        log = self.f.home / "interrupted-wrapper.log"
        worker = None
        with log.open("wb") as output:
            parent = subprocess.Popen(command, env=self.f.env, stdout=output, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 12
                while not status.with_suffix(".ready").exists():
                    if parent.poll() is not None or time.monotonic() >= deadline:
                        self.fail("activation worker did not reach bounded pause: " + log.read_text())
                    time.sleep(0.02)
                worker = json.loads(status.read_text())
                parent.send_signal(signal.SIGTERM)
                status.with_suffix(".continue").write_text("finish or roll back")
                self.assertNotEqual(parent.wait(timeout=10), 0)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        if lease.process_start(worker["pid"]) != worker["start"]:
                            break
                    except lease.LeaseError:
                        break
                    if self.journal.exists() and self.x.events(self.journal)[-1]["event"] == "activation-stopped":
                        break
                    time.sleep(0.02)
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait(timeout=5)
                if worker is not None:
                    try:
                        if lease.process_start(worker["pid"]) == worker["start"]:
                            os.kill(worker["pid"], signal.SIGKILL)
                    except (lease.LeaseError, ProcessLookupError):
                        pass
        self.assertTrue(lease.scan_records(), log.read_text())
        self.assertTrue((self.x.target / "one.o").exists())
        self.assert_exclusive_refused()

    def test_parent_wrapper_interruption_before_transition(self):
        self.interrupt_parent("intent")

    def test_parent_wrapper_interruption_after_transition(self):
        self.interrupt_parent("transition")

    def test_parent_wrapper_interruption_after_receipt_publication(self):
        self.interrupt_parent("receipt")


if __name__ == "__main__":
    unittest.main()
