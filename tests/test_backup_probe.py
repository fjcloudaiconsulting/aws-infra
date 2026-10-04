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


def night(age_hours, *, prefix=PREFIX, manifest=True, grants=True, dump=True, dump_size=620000, db="tbd", stamp="x"):
    ts = datetime.datetime.fromtimestamp(
        NOW - age_hours * 3600, datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    objs = []
    if dump:
        objs.append({"Key": f"{prefix}/{db}_{stamp}.sql.gz", "Size": dump_size, "LastModified": ts})
    if grants:
        objs.append({"Key": f"{prefix}/grants_{stamp}.sql.gz", "Size": 800, "LastModified": ts})
    if manifest:
        objs.append({"Key": f"{prefix}/manifest_{stamp}.json", "Size": 484, "LastModified": ts})
    return objs


def listing(age_hours, **kw):
    return json.dumps({"Contents": night(age_hours, **kw)})


def probe(payload, *floors):
    return subprocess.run(
        ["bash", str(PROBE), *(floors or ["pfv-data-01=100000"])], input=payload, capture_output=True, text=True,
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

    def test_artifacts_must_carry_the_newest_manifests_stamp(self):
        # Two sets in one day directory (a CronJob retry or a manual Job); only the older is complete.
        # Kills: matching dump and grants by day directory, so the older set's dump passes a broken newer set.
        older = night(6, stamp="20260827-020000")
        for broken in ({"dump": False}, {"grants": False}, {"dump_size": 12}):
            with self.subTest(**broken):
                r = probe(json.dumps({"Contents": older + night(2, stamp="20260827-084115", **broken)}))
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn("20260827-084115", r.stdout)

    def test_a_broken_older_set_does_not_spoil_a_complete_newer_one(self):
        # Kills: judging the oldest stamp, or requiring every set in the day to be complete.
        older = night(6, stamp="20260827-020000", dump_size=12, grants=False)
        r = probe(json.dumps({"Contents": older + night(2, stamp="20260827-084115")}))
        self.assertEqual(r.returncode, 0, r.stdout)


MYSQL = "tbd-mysql/2026/08/27"
PG = "ziftbook-postgres/2026/08/27"
FLOORS = ("pfv-data-01=100000", "tbd-mysql=300", "ziftbook-postgres=300")


def all_three(*, pfv=2, mysql=2, pg=2):
    return json.dumps({"Contents": night(pfv)
                       + night(mysql, prefix=MYSQL, dump_size=600)
                       + night(pg, prefix=PG, dump_size=600, db="ziftbook")})


class PerPrefix(unittest.TestCase):
    def test_each_prefix_is_judged_on_its_own_floor(self):
        # Kills: one global floor (the high one fails the k3s dumps, the low one waves through a tiny droplet dump).
        self.assertEqual(probe(all_three(), *FLOORS).returncode, 0, probe(all_three(), *FLOORS).stdout)
        tiny_pfv = json.dumps({"Contents": night(2, dump_size=600)
                               + night(2, prefix=MYSQL, dump_size=600)
                               + night(2, prefix=PG, dump_size=600, db="ziftbook")})
        self.assertEqual(probe(tiny_pfv, *FLOORS).returncode, 1)

    def test_postgres_naming_is_understood(self):
        # ziftbook_<ts>.sql.gz plus pg_dumpall globals as grants_<ts>.sql.gz.
        r = probe(json.dumps({"Contents": night(2, prefix=PG, dump_size=600, db="ziftbook")}), "ziftbook-postgres=300")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_one_stale_prefix_fails_the_run_and_is_named(self):
        # Kills: first-verdict-wins, and judging only the newest manifest in the whole bucket.
        r = probe(all_three(pg=26), *FLOORS)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("ziftbook-postgres", r.stdout.splitlines()[0])
        self.assertNotIn("pfv-data-01", r.stdout.splitlines()[0])

    def test_a_prefix_with_no_objects_is_stale(self):
        r = probe(listing(2), *FLOORS)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("tbd-mysql", r.stdout.splitlines()[0])

    def test_a_sibling_prefix_does_not_stand_in(self):
        # Kills: matching on the bare name, so a fresh tbd-mysql-x/ hides an empty tbd-mysql/.
        r = probe(json.dumps({"Contents": night(2, prefix="tbd-mysql-x/2026/08/27", dump_size=600)}), "tbd-mysql=300")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("tbd-mysql", r.stdout.splitlines()[0])

    def test_the_worst_verdict_wins(self):
        # could-not-run (future-dated) outranks stale, whatever the order.
        self.assertEqual(probe(all_three(mysql=26, pg=-3), *FLOORS).returncode, 2)
        self.assertEqual(probe(all_three(mysql=-3, pg=26), *FLOORS).returncode, 2)

    def test_could_not_run_without_a_floor(self):
        for bad in ("tbd-mysql", "tbd-mysql=", "tbd-mysql=abc"):
            with self.subTest(bad=bad):
                self.assertEqual(probe(listing(2), bad).returncode, 2)


class AlarmWiring(unittest.TestCase):
    def test_the_workflow_probes_every_prefix_with_its_floor(self):
        wf = WORKFLOW.read_text()
        for floor in ("pfv-data-01=100000", "tbd-mysql=100000", "ziftbook-postgres=300"):
            self.assertIn(floor, wf)

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
