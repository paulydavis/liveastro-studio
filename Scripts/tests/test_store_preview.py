"""Behavior tests for the isolated Store Preview packager.

Run: python3 Scripts/tests/test_store_preview.py

The real packaging script is invoked in a temporary project. Only the external
Swift and codesign boundaries are stubbed; bundle assembly and plist parsing use
the host tools and filesystem.
"""

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "Scripts/package_store_preview.sh"
ENTITLEMENTS = REPOSITORY_ROOT / "Scripts/StorePreview.entitlements"


class StorePreviewPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="store-preview-package-")
        self.root = Path(self.temporary_directory.name)
        self.project = self.root / "project"
        self.scripts = self.project / "Scripts"
        self.scripts.mkdir(parents=True)
        self.assertTrue(SCRIPT.is_file(), "package_store_preview.sh must exist")
        self.assertTrue(ENTITLEMENTS.is_file(), "StorePreview.entitlements must exist")
        shutil.copy2(SCRIPT, self.scripts / SCRIPT.name)
        shutil.copy2(ENTITLEMENTS, self.scripts / ENTITLEMENTS.name)

        self.tool_log = self.root / "tool.log"
        self.stub_bin = self.root / "stub-bin"
        self.stub_bin.mkdir()
        self._write_stub_toolchain()
        self.environment = os.environ.copy()
        self.environment["PATH"] = str(self.stub_bin) + os.pathsep + self.environment["PATH"]
        self.environment["STORE_PREVIEW_TOOL_LOG"] = str(self.tool_log)
        self.environment["STORE_PREVIEW_TEST_ENTITLEMENTS"] = str(self.scripts / ENTITLEMENTS.name)
        self.environment["STORE_PREVIEW_REAL_DITTO"] = "/usr/bin/ditto"

    def tearDown(self):
        self.temporary_directory.cleanup()

    def _write_executable(self, name, body):
        path = self.stub_bin / name
        path.write_text(body)
        path.chmod(0o755)

    def _write_stub_toolchain(self):
        self._write_executable(
            "swift",
            r'''#!/bin/bash
set -euo pipefail
printf 'swift' >> "$STORE_PREVIEW_TOOL_LOG"
printf ' <%s>' "$@" >> "$STORE_PREVIEW_TOOL_LOG"
printf ' cwd=<%s>' "$PWD" >> "$STORE_PREVIEW_TOOL_LOG"
printf '\n' >> "$STORE_PREVIEW_TOOL_LOG"
[ "${STORE_PREVIEW_FAIL_SWIFT:-0}" != 1 ] || exit 97
scratch=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--scratch-path" ]; then
        scratch="$2"
        break
    fi
    shift
done
[ -n "$scratch" ] || { echo "stub: missing --scratch-path" >&2; exit 91; }
product="$scratch/apple/Products/Release"
mkdir -p "$product/LiveAstroStudio_LiveAstroStudio.bundle/Contents/Resources"
printf '#!/bin/bash\nexit 0\n' > "$product/LiveAstroStudio"
chmod +x "$product/LiveAstroStudio"
cat > "$product/LiveAstroStudio_LiveAstroStudio.bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>fixture.resources</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
printf 'fixture-resource\n' > "$product/LiveAstroStudio_LiveAstroStudio.bundle/Contents/Resources/fixture.txt"
''',
        )
        self._write_executable(
            "codesign",
            r'''#!/bin/bash
set -euo pipefail
printf 'codesign' >> "$STORE_PREVIEW_TOOL_LOG"
printf ' <%s>' "$@" >> "$STORE_PREVIEW_TOOL_LOG"
printf '\n' >> "$STORE_PREVIEW_TOOL_LOG"
display_entitlements=0
display_details=0
previous=""
verify=0
for argument in "$@"; do
  if [ "$previous" = "-d" ] && [ "$argument" = "--entitlements" ]; then
    display_entitlements=1
  fi
  [ "$argument" = "-dv" ] && display_details=1
  [ "$argument" = "--verify" ] && verify=1
  previous="$argument"
done
target="${!#}"
if [ "$verify" -eq 1 ]; then
    case "$target" in
      "${STORE_PREVIEW_TEST_OUTPUT:-}"|*.publish.*)
        if [ "${STORE_PREVIEW_CREATE_CONCURRENT_OUTPUT:-0}" = 1 ]; then
            mkdir -p "$STORE_PREVIEW_TEST_OUTPUT"
            printf 'concurrent owner\n' > "$STORE_PREVIEW_TEST_OUTPUT/concurrent-marker.txt"
        fi
        [ "${STORE_PREVIEW_FAIL_FINAL_VERIFY:-0}" != 1 ] || exit 95
        ;;
    esac
fi
if [ "$display_entitlements" -eq 1 ]; then
    cat "$STORE_PREVIEW_TEST_ENTITLEMENTS"
elif [ "$display_details" -eq 1 ]; then
    echo 'Executable=fixture' >&2
    echo 'Identifier=com.pauldavis.liveastrostudio.store-preview' >&2
    echo 'Authority=Developer ID Application: Paul Davis (HCAXQRGYPR)' >&2
    echo 'TeamIdentifier=HCAXQRGYPR' >&2
fi
''',
        )
        self._write_executable(
            "ditto",
            r'''#!/bin/bash
set -euo pipefail
printf 'ditto' >> "$STORE_PREVIEW_TOOL_LOG"
printf ' <%s>' "$@" >> "$STORE_PREVIEW_TOOL_LOG"
printf '\n' >> "$STORE_PREVIEW_TOOL_LOG"
target="${!#}"
case "$target" in
  "${STORE_PREVIEW_TEST_OUTPUT:-}"|*.publish.*)
    [ "${STORE_PREVIEW_FAIL_PUBLISH_COPY:-0}" != 1 ] || exit 96
    ;;
esac
exec "$STORE_PREVIEW_REAL_DITTO" "$@"
''',
        )
        self._write_executable(
            "xcrun",
            r'''#!/bin/bash
set -euo pipefail
printf 'xcrun' >> "$STORE_PREVIEW_TOOL_LOG"
printf ' <%s>' "$@" >> "$STORE_PREVIEW_TOOL_LOG"
printf '\n' >> "$STORE_PREVIEW_TOOL_LOG"
exec /usr/bin/xcrun "$@"
''',
        )
        self._write_executable(
            "xattr",
            r'''#!/bin/bash
set -euo pipefail
printf 'xattr' >> "$STORE_PREVIEW_TOOL_LOG"
printf ' <%s>' "$@" >> "$STORE_PREVIEW_TOOL_LOG"
printf '\n' >> "$STORE_PREVIEW_TOOL_LOG"
''',
        )

    def invoke(self, *arguments, cwd=None, umask=0o022):
        return subprocess.run(
            ["bash", str(self.scripts / SCRIPT.name), *map(str, arguments)],
            cwd=cwd or self.project,
            env=self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
            umask=umask,
        )

    def test_bad_arguments_fail_before_building(self):
        # Every refusal test makes the build boundary fail closed as well: a
        # validation regression can be observed, but cannot reach assembly.
        self.environment["STORE_PREVIEW_FAIL_SWIFT"] = "1"
        cases = [
            ("--unknown",),
            ("--identity",),
            ("--version", "1..2", "--identity", "fixture"),
            ("--output-app", "/Applications/LiveAstro Store Preview.app", "--identity", "fixture"),
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.tool_log.unlink(missing_ok=True)
                result = self.invoke(*arguments)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.tool_log.exists(), "invalid arguments must fail before any build/sign tool")

    def test_existing_output_fails_before_build_and_is_preserved(self):
        self.environment["STORE_PREVIEW_FAIL_SWIFT"] = "1"
        output = self.root / "development" / "LiveAstro Store Preview.app"
        output.mkdir(parents=True)
        marker = output / "keep.txt"
        marker.write_text("do not replace\n")

        result = self.invoke("--identity", "fixture", "--output-app", output)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(marker.read_text(), "do not replace\n")
        self.assertFalse(self.tool_log.exists(), "existing output must be rejected before building")

    def test_symlinked_applications_parent_is_rejected_before_build(self):
        applications_link = self.root / "linked-applications"
        applications_link.symlink_to("/Applications", target_is_directory=True)
        output = applications_link / "LiveAstro Store Preview.app"
        # Defense in depth for this negative test: if the production guard
        # regresses, the Swift stub stops before any bundle can be assembled or
        # copied through the symlink into the real /Applications directory.
        self.environment["STORE_PREVIEW_FAIL_SWIFT"] = "1"

        result = self.invoke("--identity", "fixture", "--output-app", output)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.tool_log.exists(), "a resolved /Applications target must fail before building")

    def test_publish_copy_failure_leaves_no_output_and_retry_succeeds(self):
        output_parent = self.root / "copy-failure-output"
        output_parent.mkdir()
        output = output_parent / "LiveAstro Store Preview.app"
        self.environment["STORE_PREVIEW_TEST_OUTPUT"] = str(output)
        self.environment["STORE_PREVIEW_FAIL_PUBLISH_COPY"] = "1"

        failed = self.invoke("--identity", "fixture", "--output-app", output)

        self.assertNotEqual(failed.returncode, 0, failed.stdout)
        self.assertFalse(output.exists(), "a failed publication copy must not expose the final app")
        self.assertEqual(list(output_parent.glob(".LiveAstro Store Preview.app.publish.*")), [])

        self.environment.pop("STORE_PREVIEW_FAIL_PUBLISH_COPY")
        retried = self.invoke("--identity", "fixture", "--output-app", output)
        self.assertEqual(retried.returncode, 0, retried.stdout)
        self.assertTrue((output / "Contents/Info.plist").is_file())

    def test_final_verification_failure_leaves_no_output_and_retry_succeeds(self):
        output_parent = self.root / "verification-failure-output"
        output_parent.mkdir()
        output = output_parent / "LiveAstro Store Preview.app"
        self.environment["STORE_PREVIEW_TEST_OUTPUT"] = str(output)
        self.environment["STORE_PREVIEW_FAIL_FINAL_VERIFY"] = "1"

        failed = self.invoke("--identity", "fixture", "--output-app", output)

        self.assertNotEqual(failed.returncode, 0, failed.stdout)
        self.assertFalse(output.exists(), "a rejected publication copy must not expose the final app")
        self.assertEqual(list(output_parent.glob(".LiveAstro Store Preview.app.publish.*")), [])

        self.environment.pop("STORE_PREVIEW_FAIL_FINAL_VERIFY")
        retried = self.invoke("--identity", "fixture", "--output-app", output)
        self.assertEqual(retried.returncode, 0, retried.stdout)
        self.assertTrue((output / "Contents/Info.plist").is_file())

    def test_concurrent_destination_is_preserved_by_exclusive_publish(self):
        output_parent = self.root / "concurrent-output"
        output_parent.mkdir()
        output = output_parent / "LiveAstro Store Preview.app"
        self.environment["STORE_PREVIEW_TEST_OUTPUT"] = str(output)
        self.environment["STORE_PREVIEW_CREATE_CONCURRENT_OUTPUT"] = "1"

        result = self.invoke("--identity", "fixture", "--output-app", output)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((output / "concurrent-marker.txt").read_text(), "concurrent owner\n")
        self.assertFalse((output / "Contents").exists(), "publisher must not merge into a concurrent destination")
        self.assertEqual(list(output_parent.glob(".LiveAstro Store Preview.app.publish.*")), [])

    def test_build_is_anchored_to_package_root_from_unrelated_working_directory(self):
        unrelated = self.root / "unrelated-working-directory"
        unrelated.mkdir()
        output = self.root / "development-from-unrelated" / "LiveAstro Store Preview.app"
        scratch_root = self.root / "unrelated-build-root"
        scratch_root.mkdir()

        result = self.invoke(
            "--identity", "fixture",
            "--scratch-root", scratch_root,
            "--output-app", output,
            cwd=unrelated,
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        swift_line = next(line for line in self.tool_log.read_text().splitlines() if line.startswith("swift"))
        swift_cwd = Path(swift_line.split(" cwd=<", 1)[1].rsplit(">", 1)[0])
        self.assertTrue(os.path.samefile(swift_cwd, self.project))

    def test_supplied_paths_are_isolated_and_bundle_has_expected_layout(self):
        build_root = self.root / "build-root"
        build_root.mkdir()
        shared_marker = build_root / "shared-release-scratch" / "keep.txt"
        shared_marker.parent.mkdir()
        shared_marker.write_text("preserve shared scratch\n")
        output_parent = self.root / "development-output"
        output_parent.mkdir()
        output_marker = output_parent / "keep.txt"
        output_marker.write_text("preserve sibling\n")
        (self.project / "dist").mkdir()
        dist_marker = self.project / "dist" / "keep.txt"
        dist_marker.write_text("preserve dist\n")
        output = output_parent / "LiveAstro Store Preview.app"

        result = self.invoke(
            "--identity", "fixture",
            "--version", "3.6.11",
            "--scratch-root", build_root,
            "--output-app", output,
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(output.is_dir())
        self.assertEqual(output.stat().st_mode & 0o777, 0o755,
                         "publication must preserve the staged app root mode, not mktemp's 0700")
        info = plistlib.loads((output / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.pauldavis.liveastrostudio.store-preview")
        self.assertEqual(info["CFBundleName"], "LiveAstro Store Preview")
        self.assertEqual(info["CFBundleDisplayName"], "LiveAstro Store Preview")
        resources = output / "Contents/Resources/LiveAstroStudio_LiveAstroStudio.bundle"
        self.assertTrue((resources / "Contents/Resources/fixture.txt").is_file())
        self.assertFalse((output / "Contents/MacOS/LiveAstroStudio_LiveAstroStudio.bundle").exists())

        log = self.tool_log.read_text()
        swift_line = next(line for line in log.splitlines() if line.startswith("swift"))
        scratch_argument = swift_line.split(" <--scratch-path> <", 1)[1].split(">", 1)[0]
        scratch = Path(scratch_argument)
        self.assertEqual(scratch.parent, build_root)
        self.assertTrue(scratch.name.startswith("liveastro-store-preview."))
        self.assertFalse(scratch.exists(), "the script must clean only its owned mktemp scratch")
        verify_lines = [line for line in log.splitlines()
                        if line.startswith("codesign <--verify> <--deep> <--strict>")]
        self.assertTrue(any(".publish." in line for line in verify_lines), log)
        self.assertNotIn(f"codesign <--verify> <--deep> <--strict> <{output}>", log)
        self.assertIn("codesign <-d> <--entitlements> <-> <--xml>", log)
        self.assertIn("codesign <-dv> <--verbose=4>", log)
        self.assertEqual(shared_marker.read_text(), "preserve shared scratch\n")
        self.assertEqual(output_marker.read_text(), "preserve sibling\n")
        self.assertEqual(dist_marker.read_text(), "preserve dist\n")

    def test_entitlement_set_is_narrow_and_complete(self):
        values = plistlib.loads(ENTITLEMENTS.read_bytes())
        self.assertEqual(
            values,
            {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.files.user-selected.read-write": True,
                "com.apple.security.files.bookmarks.app-scope": True,
                "com.apple.security.network.client": True,
            },
        )

    def test_publish_root_preserves_nondefault_staged_mode(self):
        output = self.root / "restricted-development" / "LiveAstro Store Preview.app"
        result = self.invoke("--identity", "fixture", "--output-app", output, umask=0o027)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(output.stat().st_mode & 0o777, 0o750,
                         "the owned publish sibling must retain the staged root's actual mode")


if __name__ == "__main__":
    unittest.main(verbosity=2)
