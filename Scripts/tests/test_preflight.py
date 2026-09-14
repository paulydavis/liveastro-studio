"""Run the actual gate against small Swift packages, not the app's 45-minute suite.

Run: python3 Scripts/tests/test_preflight.py
Requires Swift and bash. Each case uses fresh build output.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


GATE = Path(__file__).resolve().parents[1] / "preflight.sh"
SWIFT = shutil.which("swift")


class PreflightTests(unittest.TestCase):
    def run_gate(self, *, compiler_warning=False, tool_warning=False, test_failure=False):
        self.assertIsNotNone(SWIFT, "Swift is required for real compiler enforcement tests")
        with tempfile.TemporaryDirectory(prefix="preflight-contract-") as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            shutil.copy2(GATE, root / "Scripts/preflight.sh")
            (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GateFixture", targets: [
    .target(name: "Fixture"),
    .testTarget(name: "FixtureTests", dependencies: ["Fixture"])
])
''')
            source = root / "Sources/Fixture"
            source.mkdir(parents=True)
            (source / "Fixture.swift").write_text("public let answer = 42\n")
            tests = root / "Tests/FixtureTests"
            tests.mkdir(parents=True)
            warning = '#warning("intentional-test-target-warning")\n' if compiler_warning else ""
            expected = 0 if test_failure else 42
            (tests / "FixtureTests.swift").write_text(warning + f'''import XCTest
import Fixture
final class FixtureTests: XCTestCase {{
    func testAnswer() {{
        print("GATE_FIXTURE_TEST_BODY_EXECUTED")
        XCTAssertEqual(answer, {expected})
    }}
}}
''')
            # Capture the real test command's output independently of the gate's
            # reporting, so a missing report cannot hide whether tests executed.
            # Only the optional external diagnostic is simulated.
            env = os.environ.copy()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            wrapper = bin_dir / "swift"
            wrapper.write_text('''#!/bin/bash
if [ "$1" = test ]; then
    if [ "$PREFLIGHT_TOOL_WARNING" = 1 ]; then
        echo 'warning: simulated external-tool diagnostic'
    fi
    "$PREFLIGHT_REAL_SWIFT" "$@" > "$PREFLIGHT_CAPTURE" 2>&1
    result=$?
    cat "$PREFLIGHT_CAPTURE"
    exit "$result"
fi
exec "$PREFLIGHT_REAL_SWIFT" "$@"
''')
            wrapper.chmod(0o755)
            env["PREFLIGHT_REAL_SWIFT"] = SWIFT
            env["PREFLIGHT_TOOL_WARNING"] = "1" if tool_warning else "0"
            env["PREFLIGHT_CAPTURE"] = str(root / "test-output.log")
            env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
            result = subprocess.run(
                ["bash", "Scripts/preflight.sh"], cwd=root, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240,
            )
            capture = root / "test-output.log"
            test_log = capture.read_text() if capture.exists() else ""
            paths = [line.removeprefix("   test log: ") for line in result.stdout.splitlines()
                     if line.startswith("   test log: ")]
            self.assertEqual(len(paths), 1, result.stdout)
            self.assertTrue(Path(paths[0]).is_file(), "reported test log must be readable even on failure")
            log_dir = os.environ.get("PREFLIGHT_TEST_LOG_DIR")
            if log_dir:
                destination = Path(log_dir)
                destination.mkdir(parents=True, exist_ok=True)
                (destination / (self._testMethodName + ".log")).write_text(result.stdout + "\n" + test_log)
            return result, test_log

    def test_test_target_warning_fails_before_test_execution(self):
        # Removing compiler enforcement must turn this into an erroneous green gate.
        result, log = self.run_gate(compiler_warning=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("error:", result.stdout)
        self.assertIn("intentional-test-target-warning", result.stdout)
        self.assertNotIn("GATE_FIXTURE_TEST_BODY_EXECUTED", log)

    def test_clean_package_passes_and_runs_tests(self):
        result, log = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PREFLIGHT PASSED", result.stdout)
        self.assertIn("GATE_FIXTURE_TEST_BODY_EXECUTED", log)

    def test_external_test_step_warning_is_visible_and_nonfatal(self):
        # Omitting test-log reporting hides this diagnostic; treating all log
        # warnings as fatal incorrectly blocks the otherwise passing package.
        result, log = self.run_gate(tool_warning=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("warning: simulated external-tool diagnostic", result.stdout)
        self.assertIn("GATE_FIXTURE_TEST_BODY_EXECUTED", log)

    def test_failed_test_still_fails_gate(self):
        result, log = self.run_gate(test_failure=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("PREFLIGHT FAILED", result.stdout)
        self.assertIn("GATE_FIXTURE_TEST_BODY_EXECUTED", log)

    def test_informational_warning_does_not_mask_test_failure(self):
        result, log = self.run_gate(tool_warning=True, test_failure=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("warning: simulated external-tool diagnostic", result.stdout)
        self.assertIn("PREFLIGHT FAILED", result.stdout)
        self.assertIn("GATE_FIXTURE_TEST_BODY_EXECUTED", log)


if __name__ == "__main__":
    unittest.main(verbosity=2)
