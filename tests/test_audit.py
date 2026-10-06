"""The audit must reject incomplete scans and narrowly scope exceptions."""
import datetime
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("audit_report", REPO / "scripts/audit-report.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class AuditTests(unittest.TestCase):
    def test_cpu_wheels_are_audited_as_upstream_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "requirements.lock"
            path.write_text("--index-url https://pypi.org/simple\ntorch==2.11.0+cpu \\\n    --hash=sha256:abc\ntorchaudio==2.11.0+cpu\n")
            self.assertEqual(AUDIT.prepare_lock(path), "torch==2.11.0\ntorchaudio==2.11.0\n")

    def test_unpinned_empty_and_conflicting_locks_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "requirements.lock"
            for content in ("", "torch>=2.11", "torch==2.11\ntorch==2.12\n"):
                path.write_text(content)
                with self.assertRaises(ValueError):
                    AUDIT.prepare_lock(path)

    def test_skipped_packages_and_empty_reports_fail(self):
        for report in ({"dependencies": []}, {"dependencies": [{"name": "torch", "skip_reason": "unavailable"}]},
                       {"dependencies": [{"name": "torch", "version": "2.11.0"}]}):
            with self.assertRaises(ValueError):
                list(AUDIT.findings(report, "pip"))
        with self.assertRaises(ValueError):
            list(AUDIT.findings({"Results": []}, "trivy"))
        with self.assertRaises(ValueError):
            list(AUDIT.findings({"Results": [{"Type": "python-pkg"}]}, "trivy"))

    def test_exception_is_scoped_to_package_version_and_python(self):
        exception = {"package": "torch", "versions": ["2.11.0"], "ids": ["CVE-2025-3000"], "expires": "2026-11-06"}
        item = {"package": "torch", "version": "2.11.0", "scope": "python", "id": "PYSEC-2025-194", "aliases": ["CVE-2025-3000"]}
        accepted, report_only, blocked = AUDIT.evaluate([item], [exception])
        self.assertEqual((len(accepted), len(report_only), len(blocked)), (1, 0, 0))
        item = {**item, "severity": "HIGH", "fixed": "2.13.0"}
        for change in ({"version": "2.12.0"}, {"package": "other"}, {"scope": "os"}, {"aliases": []}):
            accepted, report_only, blocked = AUDIT.evaluate([{**item, **change}], [exception])
            self.assertEqual((len(accepted), len(report_only), len(blocked)), (0, 0, 1))

    def test_expired_exception_blocks_audit(self):
        entry = {"package": "torch", "versions": ["2.11.0"], "ids": ["CVE-2025-3000"], "expires": "2026-11-06", "reason": "Unused API", "source": "https://example.org/advisory"}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "exceptions.json"
            path.write_text(json.dumps([entry]))
            self.assertEqual(AUDIT.load_exceptions(path, datetime.date(2026, 11, 5)), [entry])
            with self.assertRaises(ValueError):
                AUDIT.load_exceptions(path, datetime.date(2026, 11, 6))

    def test_debian_findings_without_fixes_are_retained(self):
        report = {"Results": [{"Type": "debian", "Vulnerabilities": [{"PkgName": "ffmpeg", "InstalledVersion": "7.1", "VulnerabilityID": "CVE-EXAMPLE", "Severity": "HIGH"}]}]}
        accepted, report_only, blocked = AUDIT.evaluate(AUDIT.findings(report, "trivy"), [])
        self.assertEqual((len(accepted), len(report_only), len(blocked)), (0, 1, 0))
        self.assertEqual(report_only[0]["id"], "CVE-EXAMPLE")

    def test_debian_gate_blocks_only_fixable_high_and_critical(self):
        item = {"package": "ffmpeg", "version": "7.1", "scope": "os", "id": "CVE-EXAMPLE", "aliases": []}
        for severity in ("LOW", "MEDIUM", "HIGH", "CRITICAL", "UNKNOWN"):
            for fixed in ("", "7.2"):
                with self.subTest(severity=severity, fixed=fixed):
                    accepted, report_only, blocked = AUDIT.evaluate([{**item, "severity": severity, "fixed": fixed}], [])
                    must_block = severity in ("HIGH", "CRITICAL") and bool(fixed)
                    self.assertEqual((len(accepted), len(report_only), len(blocked)), (0, int(not must_block), int(must_block)))

    def test_python_without_a_fix_remains_blocking(self):
        item = {"package": "fastapi", "version": "0.142.2", "scope": "python", "id": "CVE-EXAMPLE", "aliases": [], "severity": "LOW", "fixed": []}
        accepted, report_only, blocked = AUDIT.evaluate([item], [])
        self.assertEqual((len(accepted), len(report_only), len(blocked)), (0, 0, 1))

    def test_audit_must_cover_exactly_the_requested_versions(self):
        packages = [{"name": "torch", "version": "2.11.0", "vulns": []},
                    {"name": "fastapi", "version": "0.142.2", "vulns": []}]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audit.txt"
            path.write_text("torch==2.11.0\nfastapi==0.142.2\n")
            AUDIT.validate_coverage({"dependencies": packages}, path)
            for incomplete in (packages[:1], packages + packages[:1],
                               [{**item, "version": "0"} for item in packages]):
                with self.assertRaises(ValueError):
                    AUDIT.validate_coverage({"dependencies": incomplete}, path)


if __name__ == "__main__":
    unittest.main()
