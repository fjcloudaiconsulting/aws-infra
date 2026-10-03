"""Release drift probe: compare logic against a stubbed `gh` (INFRA-38).

Stdlib only: `python3 -m unittest discover -s tests`.
"""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / ".github/scripts/check-release-drift.sh"
NOW = 1_800_000_000
DAY = 86400
STUB = """#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "api repos/fjcloudaiconsulting/ziftbook/releases/latest") printf '%s\\t%s\\n' "$REL_TAG" "$REL_PUB" ;;
  "issue list") echo "${EXISTING:-}" ;;
esac
"""


def iso(age_days):
    import datetime
    return datetime.datetime.fromtimestamp(NOW - age_days * DAY, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(tags, *, latest="v0.21.0", age=3, grace=2, existing="", files=None):
    """tags: image tags written to clusters/ (one image each); files overrides the raw file list."""
    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        (d / "clusters").mkdir()
        for i, t in enumerate(tags):
            (d / "clusters" / f"a{i}.yaml").write_text(f"image: ghcr.io/fjcloudaiconsulting/ziftbook/img{i}:{t}\n")
        for name, text in (files or {}).items():
            (d / "clusters" / name).write_text(text)
        (d / "bin").mkdir()
        gh = d / "bin/gh"
        gh.write_text(STUB)
        gh.chmod(0o755)
        r = subprocess.run(
            ["bash", str(SCRIPT)], capture_output=True, text=True, cwd=d,
            env={**os.environ, "PATH": f"{d/'bin'}:{os.environ['PATH']}", "GH_LOG": str(d / "log"),
                 "GH_REPO": "o/r", "RUN_URL": "u", "GRACE_DAYS": str(grace), "NOW_EPOCH": str(NOW),
                 "REL_TAG": latest, "REL_PUB": iso(age), "EXISTING": existing},
        )
        log = (d / "log").read_text() if (d / "log").exists() else ""
        return r, log


class Drift(unittest.TestCase):
    def test_drift_opens_an_issue(self):
        r, log = run(["v0.20.2"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", log)

    def test_existing_issue_is_updated_not_duplicated(self):
        r, log = run(["v0.20.2"], existing="7")
        self.assertIn("issue edit 7", log)
        self.assertNotIn("issue create", log)

    def test_lowest_tag_per_repo_counts(self):
        # frontend lags at v0.19.0 while backend is at the latest: still drift (kills "highest").
        r, log = run(["v0.19.0", "v0.21.0"])
        self.assertIn("issue create", log)
        self.assertIn("v0.19.0", r.stdout)

    def test_grace_boundary_is_inclusive(self):
        # age == grace is drift (kills `>`); age < grace is not (kills "no grace").
        self.assertIn("issue create", run(["v0.20.2"], age=2, grace=2)[1])
        self.assertNotIn("issue create", run(["v0.20.2"], age=1, grace=2)[1])

    def test_clear_closes_the_open_issue(self):
        r, log = run(["v0.21.0"], existing="7")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue close 7", log)

    def test_older_latest_is_not_drift(self):
        self.assertNotIn("issue create", run(["v0.22.0"])[1])


class FailsClosed(unittest.TestCase):
    def assert_closed(self, r, log):
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertNotIn("issue close", log)
        self.assertNotIn("issue create", log)

    def test_prerelease_pin_fails(self):
        self.assert_closed(*run(["v0.21.0-rc1"], existing="7"))

    def test_digest_pin_fails(self):
        self.assert_closed(*run(["v0.20.2@sha256:abc"], existing="7"))

    def test_no_refs_fails(self):
        self.assert_closed(*run([], existing="7"))

    def test_expected_repo_missing_fails(self):
        r, log = run([], existing="7", files={"x.yaml": "image: ghcr.io/fjcloudaiconsulting/other/img:v1.0.0\n"})
        self.assert_closed(r, log)
        self.assertIn("expected repo ziftbook", r.stderr)

    def test_bad_grace_fails(self):
        self.assert_closed(*run(["v0.20.2"], grace="x", existing="7"))


if __name__ == "__main__":
    unittest.main()
