#!/usr/bin/env python3
"""Regression coverage for canonical SwiftPM lock and writer-local storage."""

from __future__ import annotations

import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
REQUIRED_FLAGS = (
    "-clonedSourcePackagesDirPath",
    "-packageCachePath",
    "-onlyUsePackageVersionsFromResolvedFile",
    "-skipPackageUpdates",
)


class PackageStorageTests(unittest.TestCase):
    def source(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8")

    def test_shell_helper_emits_locked_writer_local_arguments(self) -> None:
        with tempfile.TemporaryDirectory(prefix="plozz-package-storage-") as temp:
            home = Path(temp) / "home"
            writer = Path(temp) / "writer"
            cache = Path(temp) / "cache"
            env = dict(os.environ, HOME=str(home), PLOZZ_PACKAGE_CACHE_PATH=str(cache))
            script = (
                "source tools/lib/swift-package-storage.sh; "
                f"configure_plozz_package_resolution {str(writer)!r}; "
                "printf '%s\\n' \"${PACKAGE_RESOLUTION_ARGS[@]}\""
            )
            result = subprocess.run(
                ["/bin/bash", "-c", script],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    "-clonedSourcePackagesDirPath",
                    str(writer),
                    "-packageCachePath",
                    str(cache),
                    "-onlyUsePackageVersionsFromResolvedFile",
                    "-skipPackageUpdates",
                ],
            )

    def test_generated_project_tracks_and_syncs_canonical_lock(self) -> None:
        source = self.source("tools/generate-project.sh")
        self.assertIn('shasum -a 256 project.yml Package.swift "$canonical_package_lock"', source)
        self.assertIn(
            'workspace_package_lock="${proj_dir}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"',
            source,
        )
        self.assertIn('cmp -s "$canonical_package_lock" "$workspace_package_lock"', source)

    def test_shell_writers_use_locked_private_package_storage(self) -> None:
        writers = {
            "tools/run-tests.sh": ".build/test-derived-data",
            "tools/deploy-tv.sh": ".build/package-workspaces/deploy-tv",
            "tools/deploy-ios.sh": ".build/package-workspaces/deploy-ios",
            "tools/capture-shots.sh": ".build/package-workspaces/capture-shots-",
        }
        for path, private_root in writers.items():
            with self.subTest(path=path):
                source = self.source(path)
                self.assertIn("configure_plozz_package_resolution", source)
                self.assertIn(private_root, source)
                self.assertIn('"${PACKAGE_RESOLUTION_ARGS[@]}"', source)

    def test_python_ci_and_release_writers_are_locked_and_isolated(self) -> None:
        l10n = self.source("tools/l10n-sync.py")
        self.assertIn(".build/package-workspaces/l10n", l10n)
        self.assertIn("tools/generate-project.sh", l10n)
        self.assertIn("pass_fds=lease_fds", l10n)
        for flag in REQUIRED_FLAGS:
            self.assertIn(flag, l10n)

        workflow = self.source(".github/workflows/ci.yml")
        self.assertNotIn("${{ runner.temp }}", workflow)
        self.assertIn('configure_plozz_package_resolution "$PLOZZ_CLONED_SOURCE_PACKAGES"', workflow)

        fastfile = self.source("fastlane/Fastfile")
        self.assertIn(".build\", \"package-workspaces\", \"fastlane", fastfile)
        for flag in REQUIRED_FLAGS:
            self.assertIn(flag, fastfile)

    def test_ci_package_storage_is_initialized_on_the_runner(self) -> None:
        workflow = self.source(".github/workflows/ci.yml")
        step = re.search(
            r"      - name: Configure package storage\n        run: \|\n((?:          .*\n)+)",
            workflow,
        )
        self.assertIsNotNone(step)
        script = "\n".join(line[10:] for line in step.group(1).splitlines())
        with tempfile.TemporaryDirectory(prefix="plozz ci storage ") as temp:
            runner_temp = Path(temp) / "runner temp"
            github_env = Path(temp) / "github env"
            result = subprocess.run(
                ["/bin/bash", "-e", "-c", script],
                cwd=ROOT,
                env=dict(os.environ, RUNNER_TEMP=str(runner_temp), GITHUB_ENV=str(github_env)),
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertEqual(result.stdout, "")
            self.assertEqual(
                github_env.read_text(),
                f"PLOZZ_CLONED_SOURCE_PACKAGES={runner_temp}/plozz-source-packages\n",
            )


if __name__ == "__main__":
    unittest.main()
