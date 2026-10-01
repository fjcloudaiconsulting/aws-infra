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


def listing(age_hours, *, manifest=True, grants=True, dump_size=620000):
    ts = datetime.datetime.fromtimestamp(
        NOW - age_hours * 3600, datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    objs = [{"Key": f"{PREFIX}/pfv2_x.sql.gz", "Size": dump_size, "LastModified": ts}]
    if grants:
        objs.append({"Key": f"{PREFIX}/grants_x.sql.gz", "Size": 800, "LastModified": ts})
    if manifest:
        objs.append({"Key": f"{PREFIX}/manifest_x.json", "Size": 484, "LastModified": ts})
    return json.dumps({"Contents": objs})


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

    def test_the_workflow_is_scheduled(self):
        # Without a schedule the probe detects no silence.
        self.assertRegex(WORKFLOW.read_text(), r"\n  schedule:\n    (#.*\n    )*- cron: ")


if __name__ == "__main__":
    unittest.main()
