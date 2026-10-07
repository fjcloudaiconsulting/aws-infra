"""Fences for the node log retention script (INFRA-130): expiry is judged by the first (oldest) line, not mtime."""
import gzip
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "clusters/platform/observability/log-retention/log-retention.sh"
CUTOFF = "2026-10-01T12:00:00"
OLD = "2026-09-20T08:00:00.123456789Z stdout F old line\n"
NEW = "2026-10-05T08:00:00.1Z stdout F new line\n"


class LogRetention(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "pods"
        self.d = self.root / "ns_pod_uid" / "c"
        self.d.mkdir(parents=True)
        self.addCleanup(self.tmp.cleanup)

    def run_script(self, **env):
        e = {**os.environ, "LOG_ROOT": str(self.root), "CUTOFF": CUTOFF, "TMPDIR": self.tmp.name, **env}
        return subprocess.run(["sh", str(SCRIPT)], env=e, capture_output=True, text=True)

    def test_live_file_with_old_first_line_is_truncated_not_unlinked(self):
        f = self.d / "0.log"
        f.write_text(OLD + NEW)  # fresh mtime and fresh tail: only the first line gives it away
        inode = f.stat().st_ino
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(f.stat().st_size, 0)
        self.assertEqual(f.stat().st_ino, inode)

    def test_fresh_live_file_untouched(self):
        f = self.d / "0.log"
        f.write_text(NEW)
        self.run_script()
        self.assertEqual(f.read_text(), NEW)

    def test_rotated_plain_and_gz_deleted_when_old_kept_when_new(self):
        (self.d / "0.log.20260920-000000").write_text(OLD)
        with gzip.open(self.d / "0.log.20260921-000000.gz", "wt") as g:
            g.write(OLD)
        (self.d / "0.log.20261005-000000").write_text(NEW)
        with gzip.open(self.d / "0.log.20261006-000000.gz", "wt") as g:
            g.write(NEW)
        self.run_script()
        self.assertEqual(sorted(p.name for p in self.d.iterdir()), ["0.log.20261005-000000", "0.log.20261006-000000.gz"])

    def test_unparseable_first_line_fails_closed(self):
        f = self.d / "0.log"
        f.write_text("garbage\n" + NEW)
        self.run_script()
        self.assertEqual(f.stat().st_size, 0)

    def test_symlink_not_followed(self):
        target = Path(self.tmp.name) / "outside.log"
        target.write_text(OLD)
        (self.d / "0.log").symlink_to(target)
        self.run_script()
        self.assertEqual(target.read_text(), OLD)

    def test_failure_exits_nonzero_without_heartbeat(self):
        f = self.d / "0.log"
        f.write_text(OLD)
        f.chmod(0o444)
        d = self.root / "ns_pod_uid"
        # an unreadable directory makes find fail: no success may be reported
        bad = d / "locked"
        bad.mkdir()
        (bad / "x.log").write_text(OLD)
        bad.chmod(0)
        self.addCleanup(bad.chmod, 0o755)
        if os.geteuid() == 0:
            self.skipTest("root ignores directory modes")
        r = self.run_script(HEARTBEAT_URL="http://127.0.0.1:9/never")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no heartbeat", r.stderr)


if __name__ == "__main__":
    unittest.main()
