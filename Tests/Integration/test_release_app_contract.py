import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD_SCRIPT = ROOT / "Scripts" / "build-signed-app.sh"
PROJECT_SPEC = ROOT / "project.yml"
INFO_PLIST = ROOT / "Info.plist"
PACKAGE = ROOT / "Package.swift"
README = ROOT / "README.md"
TRANSPORT = ROOT / "Sources" / "HermesMonitorCore" / "OpenSSHTransport.swift"
SYNTHETIC_SIGNING_IDENTITY = "Synthetic External Code Signing Identity"


class ReleaseAppContractTests(unittest.TestCase):
    def test_snapshot_helper_has_dual_build_resource_contract(self):
        package = PACKAGE.read_text(encoding="utf-8")
        project = PROJECT_SPEC.read_text(encoding="utf-8")
        transport = TRANSPORT.read_text(encoding="utf-8")

        self.assertIn('.copy("Resources/RemoteSQLiteSnapshot.py")', package)
        self.assertIn(
            "- path: Sources/HermesMonitorCore/Resources/RemoteSQLiteSnapshot.py",
            project,
        )
        self.assertIn("buildPhase: resources", project)
        self.assertIn("#if SWIFT_PACKAGE", transport)
        self.assertIn("return Bundle.module", transport)
        self.assertIn("return Bundle.main", transport)
        self.assertIn("RemoteSQLiteSnapshotResource.url", transport)

    def test_build_fails_closed_without_external_signing_identity(self):
        self.assertTrue(BUILD_SCRIPT.is_file(), "source-owned production build script is missing")

        environment = os.environ.copy()
        environment.pop("HERMES_MONITOR_CODE_SIGN_IDENTITY", None)
        result = subprocess.run(
            [str(BUILD_SCRIPT)],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HERMES_MONITOR_CODE_SIGN_IDENTITY is required", result.stderr)

    def test_build_rejects_ad_hoc_signing_identity_before_platform_tools(self):
        environment = os.environ.copy()
        environment["HERMES_MONITOR_CODE_SIGN_IDENTITY"] = "-"

        result = subprocess.run(
            [str(BUILD_SCRIPT)],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must name a usable external code-signing identity", result.stderr)

    def test_source_owned_production_app_contract_is_fixed_and_signing_required(self):
        project = PROJECT_SPEC.read_text(encoding="utf-8")
        build_script = BUILD_SCRIPT.read_text(encoding="utf-8")
        package = PACKAGE.read_text(encoding="utf-8")
        readme = README.read_text(encoding="utf-8")
        with INFO_PLIST.open("rb") as stream:
            info = plistlib.load(stream)

        self.assertIn("type: application", project)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: com.hermes.monitor.app", project)
        self.assertIn('PRODUCT_NAME: "Hermes Monitor"', project)
        self.assertIn('CODE_SIGN_IDENTITY: "$(HERMES_MONITOR_CODE_SIGN_IDENTITY)"', project)
        self.assertIn("CODE_SIGN_STYLE: Manual", project)
        self.assertIn("CODE_SIGNING_ALLOWED: YES", project)
        self.assertIn("CODE_SIGNING_REQUIRED: YES", project)
        self.assertIn("ENABLE_HARDENED_RUNTIME: YES", project)
        self.assertNotIn('CODE_SIGN_IDENTITY: "-"', project)
        self.assertIn('INSTALL_PATH: "/Applications"', project)
        self.assertIn("SKIP_INSTALL: NO", project)
        self.assertIn('ARCHS: "arm64"', project)
        self.assertIn("ONLY_ACTIVE_ARCH: NO", project)

        self.assertEqual(info["CFBundleName"], "Hermes Monitor")
        self.assertEqual(info["CFBundleDisplayName"], "Hermes Monitor")
        self.assertEqual(info["CFBundleExecutable"], "Hermes Monitor")
        self.assertEqual(info["CFBundleIdentifier"], "com.hermes.monitor.app")
        self.assertEqual(info["CFBundlePackageType"], "APPL")

        self.assertIn("xcodegen generate", build_script)
        self.assertIn("xcodebuild", build_script)
        self.assertIn('"$install_root/Applications/Hermes Monitor.app"', build_script)
        self.assertIn("security find-identity -v -p codesigning", build_script)
        self.assertIn("codesign --verify --deep --strict", build_script)
        self.assertIn("codesign -d -r-", build_script)
        self.assertIn("lipo -archs", build_script)
        self.assertIn('expected_architecture="arm64"', build_script)
        self.assertNotIn(SYNTHETIC_SIGNING_IDENTITY, build_script)

        self.assertIn('.executableTarget(\n        name: "HermesMonitorApp"', package)
        self.assertIn('.copy("Resources/RemoteSQLiteSnapshot.py")', package)
        self.assertIn('.linkedFramework("Security", .when(platforms: [.macOS]))', package)
        self.assertIn("Scripts/build-signed-app.sh", readme)
        self.assertIn("/Applications/Hermes Monitor.app", readme)
        self.assertIn("must not be deployed as the production app", readme)

    def test_build_rejects_temporary_production_output_before_platform_tools(self):
        environment = os.environ.copy()
        environment["HERMES_MONITOR_CODE_SIGN_IDENTITY"] = SYNTHETIC_SIGNING_IDENTITY
        environment["HERMES_MONITOR_BUILD_ROOT"] = "/tmp/HermesMonitor-production"

        result = subprocess.run(
            [str(BUILD_SCRIPT)],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production build root must not be under /tmp", result.stderr)

    def test_build_rejects_dot_segment_alias_of_temporary_root(self):
        environment = os.environ.copy()
        environment["HERMES_MONITOR_CODE_SIGN_IDENTITY"] = SYNTHETIC_SIGNING_IDENTITY
        environment["HERMES_MONITOR_BUILD_ROOT"] = "/var/../tmp/HermesMonitor-production"

        result = subprocess.run(
            [str(BUILD_SCRIPT)],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production build root must not be under /tmp", result.stderr)

    def test_build_rejects_symlink_alias_of_temporary_root(self):
        environment = os.environ.copy()
        environment["HERMES_MONITOR_CODE_SIGN_IDENTITY"] = SYNTHETIC_SIGNING_IDENTITY

        with tempfile.TemporaryDirectory(prefix=".release-root-test-", dir=ROOT) as scratch:
            alias = pathlib.Path(scratch) / "tmp-alias"
            alias.symlink_to("/tmp", target_is_directory=True)
            environment["HERMES_MONITOR_BUILD_ROOT"] = str(
                alias / "HermesMonitor-production"
            )
            result = subprocess.run(
                [str(BUILD_SCRIPT)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production build root must not be under /tmp", result.stderr)

    def test_build_rejects_unresolved_prefix_alias_of_temporary_root(self):
        environment = os.environ.copy()
        environment["HERMES_MONITOR_CODE_SIGN_IDENTITY"] = SYNTHETIC_SIGNING_IDENTITY
        absent = pathlib.Path("/") / f".hermes-monitor-absent-{os.urandom(16).hex()}"
        raw_build_root = f"{absent}/../tmp/HermesMonitor-production"
        expected_build_root = pathlib.Path("/tmp/HermesMonitor-production")

        self.assertFalse(raw_build_root.startswith(("/tmp/", "/private/tmp/")))
        self.assertFalse(absent.exists() or absent.is_symlink())
        self.assertEqual(os.path.normpath(raw_build_root), str(expected_build_root))
        self.assertEqual(
            pathlib.Path(raw_build_root).resolve(strict=False),
            expected_build_root.resolve(strict=False),
        )
        environment["HERMES_MONITOR_BUILD_ROOT"] = raw_build_root

        result = subprocess.run(
            [str(BUILD_SCRIPT)],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production build root must not be under /tmp", result.stderr)
        self.assertNotIn("signed production app must be built on macOS", result.stderr)
        self.assertNotIn("required tool is unavailable", result.stderr)

    def test_build_allows_canonical_non_temporary_root_before_platform_tools(self):
        environment = os.environ.copy()
        environment["HERMES_MONITOR_CODE_SIGN_IDENTITY"] = SYNTHETIC_SIGNING_IDENTITY
        environment["HERMES_MONITOR_BUILD_ROOT"] = str(
            ROOT / ".build" / "release-contract-positive"
        )
        if sys.platform == "darwin":
            environment["PATH"] = "/usr/bin:/bin"

        result = subprocess.run(
            [str(BUILD_SCRIPT)],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        if sys.platform == "darwin":
            self.assertIn("required tool is unavailable: xcodegen", result.stderr)
        else:
            self.assertIn("signed production app must be built on macOS", result.stderr)
        self.assertNotIn("production build root must not be under /tmp", result.stderr)


if __name__ == "__main__":
    unittest.main()
