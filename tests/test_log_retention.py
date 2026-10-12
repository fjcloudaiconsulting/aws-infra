"""Fences for the node log retention script (INFRA-130): expiry is judged by the first (oldest) line, not mtime."""
import gzip
import http.server
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "clusters/platform/observability/log-retention/log-retention.sh"
HETZNER_SCRIPT = ROOT / "clusters/hetzner/observability/log-retention/log-retention.sh"
CUTOFF = "2026-10-01T12:00:00"
OLD = "2026-09-20T08:00:00.123456789Z stdout F old line\n"
NEW = "2026-10-05T08:00:00.1Z stdout F new line\n"


class LogRetention(unittest.TestCase):
    script = SCRIPT

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "pods"
        self.d = self.root / "ns_pod_uid" / "c"
        self.d.mkdir(parents=True)
        self.addCleanup(self.tmp.cleanup)

    def run_script(self, **env):
        e = {**os.environ, "LOG_ROOT": str(self.root), "CUTOFF": CUTOFF, "TMPDIR": self.tmp.name}
        e.pop("NODE_NAME", None)  # only what a test passes: an outer NODE_NAME would change the heartbeat
        e.update(env)
        return subprocess.run(["sh", str(self.script)], env=e, capture_output=True, text=True)

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

    def test_cutoff_derived_from_now_is_six_days(self):
        if subprocess.run(["date", "-u", "-d", "@0"], capture_output=True).returncode != 0:
            self.skipTest("host date lacks -d @N (BSD date); the script targets GNU/busybox date")
        now = 1790000000  # fixed epoch
        iso = lambda s: __import__("time").strftime("%Y-%m-%dT%H:%M:%S", __import__("time").gmtime(now - s))
        old, kept = self.d / "old.log", self.d / "kept.log"
        old.write_text(f"{iso(6 * 86400 + 60)}.1Z stdout F x\n")
        kept.write_text(f"{iso(6 * 86400 - 60)}.1Z stdout F x\n")
        e = {**os.environ, "LOG_ROOT": str(self.root), "TMPDIR": self.tmp.name, "NOW": str(now)}
        e.pop("CUTOFF", None)
        self.assertEqual(subprocess.run(["sh", str(self.script)], env=e, capture_output=True, text=True).returncode, 0)
        self.assertEqual(old.stat().st_size, 0)
        self.assertGreater(kept.stat().st_size, 0)

    def otlp_stand_in(self):
        """A local OTLP endpoint; returns its URL and the list that collects posted bodies."""
        if not shutil.which("wget"):
            self.skipTest("no wget on this host; the script posts with busybox wget")
        bodies = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                bodies.append(self.rfile.read(int(self.headers["Content-Length"])))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *a):
                pass

        srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)  # cleanups run last-in first-out: shutdown, then close
        self.addCleanup(srv.shutdown)
        return f"http://127.0.0.1:{srv.server_port}/v1/metrics", bodies

    def heartbeat(self, **env):
        """Runs a clean pass against the stand-in; returns the posted payload's resource attributes."""
        url, bodies = self.otlp_stand_in()
        r = self.run_script(HEARTBEAT_URL=url, NOW="1790000000", **env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(bodies), 1)
        res = json.loads(bodies[0])["resourceMetrics"][0]
        point = res["scopeMetrics"][0]["metrics"][0]["gauge"]["dataPoints"][0]
        self.assertEqual(point["asDouble"], 1790000000)
        return {a["key"]: a["value"]["stringValue"] for a in res["resource"]["attributes"]}

    def test_failed_pass_posts_no_heartbeat(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores directory modes")
        url, bodies = self.otlp_stand_in()
        # an unreadable directory makes find fail; the endpoint is reachable, so only the script can stop the post
        bad = self.root / "ns_pod_uid" / "locked"
        bad.mkdir()
        bad.chmod(0)
        self.addCleanup(bad.chmod, 0o755)
        r = self.run_script(HEARTBEAT_URL=url)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(bodies, [], "a pass with errors must not report success")

    def test_heartbeat_is_otlp_json(self):
        self.assertEqual(self.heartbeat(), {"service.name": "log-retention"})


class LogRetentionHetzner(LogRetention):
    """The Hetzner copy (INFRA-171) runs as a DaemonSet: the same rules, plus one heartbeat series per node."""

    script = HETZNER_SCRIPT

    def test_heartbeat_names_the_node(self):
        attrs = self.heartbeat(NODE_NAME="db-1")
        self.assertEqual(attrs, {"service.name": "log-retention", "service.instance.id": "db-1"})


if __name__ == "__main__":
    unittest.main()
