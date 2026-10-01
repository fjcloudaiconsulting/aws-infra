"""Backup freshness probe: verdicts and alarm wiring (ported from tbd, INFRA-20).

Stdlib only so CI needs no installs: `python3 -m unittest discover -s tests`.
"""
import datetime
import json
import os
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROBE = ROOT / ".github/scripts/check-backup-freshness.sh"
WORKFLOW = ROOT / ".github/workflows/backup-freshness-probe.yml"
PREFIX = "pfv-data-01/2026/08/27"
NOW = 1000000000


def night(age_hours, *, prefix=PREFIX, manifest=True, grants=True, dump=True, dump_size=620000):
    ts = datetime.datetime.fromtimestamp(
        NOW - age_hours * 3600, datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    objs = []
    if dump:
        objs.append({"Key": f"{prefix}/pfv2_x.sql.gz", "Size": dump_size, "LastModified": ts})
    if grants:
        objs.append({"Key": f"{prefix}/grants_x.sql.gz", "Size": 800, "LastModified": ts})
    if manifest:
        objs.append({"Key": f"{prefix}/manifest_x.json", "Size": 484, "LastModified": ts})
    return objs


def listing(age_hours, **kw):
    return json.dumps({"Contents": night(age_hours, **kw)})


def probe(payload):
    return subprocess.run(
        ["bash", str(PROBE)], input=payload, capture_output=True, text=True,
        env={**os.environ, "NOW_EPOCH": str(NOW)},
    )


class Verdicts(unittest.TestCase):
    def test_fresh_for_a_complete_recent_night(self):
        r = probe(listing(2))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("fresh", r.stdout)

    def test_stale_after_one_missed_night(self):
        # 26h is one missed run. The threshold must alarm on ONE miss, not two.
        r = probe(listing(26))
        self.assertEqual(r.returncode, 1)
        self.assertIn("STALE", r.stdout)

    def test_stale_when_the_manifest_is_missing(self):
        # The manifest is uploaded last; without it the night may not have completed.
        r = probe(listing(2, manifest=False))
        self.assertEqual(r.returncode, 1)
        self.assertIn("manifest", r.stdout)

    def test_stale_when_grants_are_missing(self):
        self.assertEqual(probe(listing(2, grants=False)).returncode, 1)

    def test_stale_for_an_implausibly_small_dump(self):
        self.assertEqual(probe(listing(2, dump_size=12)).returncode, 1)

    def test_stale_for_an_empty_bucket(self):
        self.assertEqual(probe(json.dumps({"Contents": []})).returncode, 1)

    def test_stale_for_a_genuinely_empty_bucket(self):
        # list-objects-v2 omits Contents for an empty result.
        r = probe('{"KeyCount": 0, "Name": "tbd-mysql-backups-884686184019"}')
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("empty", r.stdout.lower())

    def test_could_not_run_rather_than_healthy(self):
        # Exit 2, never 0. A truncated listing could miss the newest page.
        for payload in ("not json", '{"Name": "b"}', "", '{"IsTruncated": true, "Contents": []}'):
            with self.subTest(payload=payload):
                self.assertEqual(probe(payload).returncode, 2)


    def test_could_not_run_for_a_future_dated_manifest(self):
        # A skewed or doctored timestamp must not read as fresh forever.
        self.assertEqual(probe(listing(-3)).returncode, 2)

    def test_judges_the_newest_night(self):
        # Kills: picking the oldest manifest.
        old = night(50, prefix="pfv-data-01/2026/08/25")
        self.assertEqual(probe(json.dumps({"Contents": old + night(2)})).returncode, 0)

    def test_artifacts_must_sit_beside_the_newest_manifest(self):
        # Kills: looking for the dump anywhere in the listing, not in the manifest's prefix.
        old = night(26, prefix="pfv-data-01/2026/08/26")
        r = probe(json.dumps({"Contents": old + night(2, dump=False)}))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("no dump", r.stdout)


class AlarmWiring(unittest.TestCase):
    def test_the_workflow_alarms_on_every_non_fresh_verdict(self):
        # Kills: alarming only on `stale`, which silences could-not-run.
        wf = WORKFLOW.read_text()
        step = re.search(r"- name: Raise the alarm\n(.*?)(?=\n      - name:)", wf, re.S)
        self.assertTrue(step, "no 'Raise the alarm' step")
        self.assertIn("bash .github/scripts/notify-backup-stale.sh", step.group(1))
        cond = re.search(r"^\s+if: (.+)$", step.group(1), re.M)
        self.assertTrue(cond, "the alarm step has no if:")
        self.assertEqual(" ".join(cond.group(1).split()), "steps.check.outputs.verdict != 'fresh'")

    def test_the_job_fails_on_every_non_fresh_verdict(self):
        step = re.search(r"- name: Fail the job when the backup is not fresh\n(.*)", WORKFLOW.read_text(), re.S)
        self.assertTrue(step, "no 'Fail the job' step")
        cond = re.search(r"^\s+if: (.+)$", step.group(1), re.M)
        self.assertEqual(" ".join(cond.group(1).split()), "steps.check.outputs.verdict != 'fresh'")

    def test_the_workflow_runs_this_repos_probe(self):
        # A wrong path exits 127 and reads as could-not-run every night.
        self.assertIn("bash .github/scripts/check-backup-freshness.sh", WORKFLOW.read_text())

    def test_a_keepalive_job_re_enables_the_workflow(self):
        # Kills: no keepalive, so 60 quiet days in this public repo disable the schedule.
        wf = WORKFLOW.read_text()
        job = re.search(r"\n  keepalive:\n(.*?)(?=\n  \S|\Z)", wf, re.S)
        self.assertTrue(job, "no keepalive job")
        self.assertIn("actions: write", job.group(1))
        self.assertRegex(job.group(1), r"run: gh api -X PUT \"repos/\$\{GH_REPO\}/actions/workflows/backup-freshness-probe\.yml/enable\"")

    def test_the_workflow_is_scheduled(self):
        # Without a schedule the probe detects no silence.
        self.assertRegex(WORKFLOW.read_text(), r"\n  schedule:\n    (#.*\n    )*- cron: ")


if __name__ == "__main__":
    unittest.main()
