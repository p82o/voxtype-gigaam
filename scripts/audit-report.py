"""Prepare frozen audit inputs and enforce package/version-scoped exceptions."""
import argparse
import datetime
import json
from pathlib import Path
import re
import sys


def normalize(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def prepare_lock(path):
    packages = {}
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "--hash=sha256:", "--index-url ", "--extra-index-url ")):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([^\s\\]+)(?:\s+.*)?", stripped)
        if not match:
            raise ValueError("Lock must contain fully pinned packages")
        name, version = normalize(match[1]), match[2]
        if name in ("torch", "torchaudio"):
            version = version.removesuffix("+cpu")
        if name in packages and packages[name] != version:
            raise ValueError("Conflicting package versions")
        packages[name] = version
    if not packages:
        raise ValueError("Empty lock")
    return "".join(f"{name}=={version}\n" for name, version in sorted(packages.items()))


def load_exceptions(path, today):
    entries = json.loads(path.read_text())
    if not isinstance(entries, list):
        raise ValueError("Invalid exception list")
    for entry in entries:
        if not all(entry.get(key) for key in ("package", "versions", "ids", "expires", "reason", "source")):
            raise ValueError("Incomplete exception")
        if datetime.date.fromisoformat(entry["expires"]) <= today:
            raise ValueError("Expired security exception")
    return entries


def validate_coverage(report, expected):
    dependencies = report["dependencies"]
    observed = {normalize(item["name"]): item["version"] for item in dependencies}
    actual = "".join(f"{name}=={version}\n" for name, version in sorted(observed.items()))
    if len(observed) != len(dependencies) or actual != prepare_lock(expected):
        raise ValueError("Dependency audit does not match requested packages")


def findings(report, kind):
    if kind == "pip":
        dependencies = report["dependencies"]
        if not isinstance(dependencies, list) or not dependencies:
            raise ValueError("Empty dependency audit")
        for dependency in dependencies:
            if dependency.get("skip_reason"):
                raise ValueError("Dependency skipped by auditor")
            if not dependency.get("name") or not dependency.get("version") or not isinstance(dependency.get("vulns"), list):
                raise ValueError("Incomplete dependency audit")
            for vulnerability in dependency["vulns"]:
                yield {
                    "package": normalize(dependency["name"]), "version": dependency["version"],
                    "id": vulnerability["id"], "aliases": vulnerability.get("aliases", []),
                    "scope": "python", "severity": "UNKNOWN",
                    "fixed": vulnerability.get("fix_versions", []),
                }
    else:
        results = report["Results"]
        if not isinstance(results, list) or not results:
            raise ValueError("Empty image audit")
        if not any(result.get("Type") == "debian" for result in results):
            raise ValueError("Debian audit missing")
        for result in results:
            if result.get("Type") not in ("debian", "python-pkg"):
                raise ValueError("Unsupported image audit target")
            for vulnerability in result.get("Vulnerabilities") or []:
                yield {
                    "package": normalize(vulnerability["PkgName"]), "version": vulnerability["InstalledVersion"],
                    "id": vulnerability["VulnerabilityID"], "aliases": [],
                    "scope": "python" if result.get("Type") == "python-pkg" else "os",
                    "severity": vulnerability.get("Severity", "UNKNOWN"),
                    "fixed": vulnerability.get("FixedVersion", ""),
                }


def evaluate(items, exceptions):
    accepted, report_only, blocked = [], [], []
    seen = set()
    for item in items:
        key = (item["scope"], item["package"], item["version"], item["id"])
        if key in seen:
            continue
        seen.add(key)
        ids = {item["id"], *item["aliases"]}
        exception = next((entry for entry in exceptions if item["scope"] == "python"
                          and normalize(entry["package"]) == item["package"]
                          and item["version"] in entry["versions"] and ids.intersection(entry["ids"])), None)
        if exception:
            accepted.append({**item, "exception_expires": exception["expires"]})
        elif item["scope"] == "os" and not (item["severity"] in ("HIGH", "CRITICAL") and item["fixed"]):
            report_only.append(item)
        else:
            blocked.append(item)
    return accepted, report_only, blocked


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("lock", type=Path)
    prepare.add_argument("output", type=Path)
    check = sub.add_parser("check")
    check.add_argument("kind", choices=("pip", "trivy"))
    check.add_argument("report", type=Path)
    check.add_argument("exceptions", type=Path)
    check.add_argument("output", type=Path)
    check.add_argument("--expected", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        args.output.write_text(prepare_lock(args.lock))
        return 0
    exceptions = load_exceptions(args.exceptions, datetime.datetime.now(datetime.timezone.utc).date())
    report = json.loads(args.report.read_text())
    if args.kind == "pip":
        if args.expected is None:
            raise ValueError("Expected audit input missing")
        validate_coverage(report, args.expected)
    accepted, report_only, blocked = evaluate(findings(report, args.kind), exceptions)
    args.output.write_text(json.dumps({"accepted": accepted, "report_only": report_only, "blocked": blocked}, indent=2) + "\n")
    print(f"{args.kind}: {len(accepted)} documented exceptions, {len(report_only)} report-only Debian findings, {len(blocked)} blocking findings")
    if report_only:
        counts = {severity: sum(item["severity"] == severity for item in report_only)
                  for severity in ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")}
        print("Debian findings retained in full report:", ", ".join(f"{name}={count}" for name, count in counts.items()))
    return int(bool(blocked))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError) as error:
        print("Audit validation failed:", type(error).__name__, file=sys.stderr)
        sys.exit(2)
