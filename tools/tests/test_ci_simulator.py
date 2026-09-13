import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "ci_simulator", Path(__file__).resolve().parents[1] / "select-ci-tvos-simulator.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CISimulatorTests(unittest.TestCase):
    def device(self, identifier, name="Apple TV 4K", available=True):
        return {"udid": identifier, "name": name, "isAvailable": available}

    def test_selects_sdk_runtime_not_first_or_booted_older_runtime(self):
        devices = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.tvOS-18-5": [
                self.device("old") | {"state": "Booted"}
            ],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-2": [self.device("matching")],
        }}
        self.assertEqual(MODULE.select_device(devices, "26.2")[0], "matching")

    def test_prefers_available_1080p_4k_device(self):
        devices = {"devices": {"com.apple.CoreSimulator.SimRuntime.tvOS-26-2": [
            self.device("unavailable", "Apple TV 4K (at 1080p)", False),
            self.device("regular"),
            self.device("preferred", "Apple TV 4K (at 1080p)"),
        ]}}
        self.assertEqual(MODULE.select_device(devices, "26.2")[0], "preferred")

    def test_missing_runtime_fails_instead_of_falling_back(self):
        with self.assertRaisesRegex(ValueError, "tvOS-26-2"):
            MODULE.select_device({"devices": {
                "com.apple.CoreSimulator.SimRuntime.tvOS-18-5": [self.device("old")]
            }}, "26.2")

    def test_unavailable_or_non_tv_devices_are_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.select_device({"devices": {
                "com.apple.CoreSimulator.SimRuntime.tvOS-26-2": [
                    self.device("off", available=False),
                    self.device("phone", "iPhone"),
                ]
            }}, "26.2")


if __name__ == "__main__":
    unittest.main()
