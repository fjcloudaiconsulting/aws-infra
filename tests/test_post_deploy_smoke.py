"""Post-deploy smoke: gate, frontend, app smoke and alarm against stubbed curl, gh and sleep (INFRA-114).

Stdlib only: `python3 -m unittest discover -s tests`.
"""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / ".github/scripts/post-deploy-smoke.sh"

# Health answers come from $VERSIONS (comma list, one per call, the last repeats; "down" is a 5xx, "html" a 200 page
# that is not JSON); `-w %{http_code}` calls (the frontend) from $FRONT_CODES the same way. Every call is logged.
CURL = r"""#!/usr/bin/env bash
echo "curl $*" >> "$LOG"
pop() { # pop <list> <counter-file>: the n-th item of a comma list, the last one repeating
  local n; n=$(cat "$2" 2>/dev/null || echo 0); echo $((n + 1)) > "$2"
  IFS=, read -ra items <<<"$1"; local i=$(( n < ${#items[@]} ? n : ${#items[@]} - 1 )); printf '%s' "${items[$i]}"
}
case "$*" in
  *http_code*) pop "$FRONT_CODES" "$STATE/front" ;;
  *) v=$(pop "$VERSIONS" "$STATE/health")
     [[ "$v" == down ]] && exit 22
     [[ "$v" == html ]] && { echo "<html>Just a moment...</html>"; exit 0; }
     printf '{"status":"ok","version":"%s"}' "$v" ;;
esac
"""
# The fetched app smoke reports what it sees and prints a marker that must never reach an issue.
GH = r"""#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$LOG"
case "$1 $2" in
  "api -H") [[ "${FETCH_RC:-0}" == 0 ]] || exit "$FETCH_RC"
            printf 'echo "app smoke base=$SMOKE_BASE_URL user=${SMOKE_USERNAME:+set} gh=${GH_TOKEN:-unset} SMOKE-OUTPUT-MARKER"; exit %s\n' "$APP_RC" ;;
  "issue list") printf '%b' "${EXISTING:-}" ;;
esac
"""
SLEEP = """#!/usr/bin/env bash
echo "sleep $*" >> "$LOG"
"""
TBD = "image: ghcr.io/fjcloudaiconsulting/tbd/backend:{}\n"
ZIF = "image: ghcr.io/fjcloudaiconsulting/ziftbook/backend:{}\n"


def issue(n, ns="tbd-prod"):
    return f"{n}\t[post-deploy-smoke] {ns}\n"


def run(ns="tbd-prod", manifest=None, *, versions="0.290.0,0.291.0", front="200", app_rc=0, existing="",
        converge=30, frontend=0, fetch_rc=0):
    """Default: the first poll still sees the old version, the second the new one (a real rollout)."""
    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        for sub in ("clusters/tbd-prod", "clusters/tbd-staging", "clusters/ziftbook-staging", "clusters/ziftbook-prod", "bin", "state"):
            (d / sub).mkdir(parents=True)
        (d / "clusters/tbd-prod/backend.yaml").write_text(TBD.format("v0.291.0"))
        (d / "clusters/tbd-staging/backend.yaml").write_text(TBD.format("v0.292.0"))
        (d / "clusters/ziftbook-staging/backend.yaml").write_text(ZIF.format("v0.291.0"))
        (d / "clusters/ziftbook-prod/backend.yaml").write_text(ZIF.format("v0.291.0"))
        if manifest is not None:
            (d / "clusters" / ns / "backend.yaml").write_text(manifest)
        for name, body in (("curl", CURL), ("gh", GH), ("sleep", SLEEP)):
            (d / "bin" / name).write_text(body)
            (d / "bin" / name).chmod(0o755)
        r = subprocess.run(
            ["bash", str(SCRIPT), ns], capture_output=True, text=True, cwd=d, timeout=60,
            env={**os.environ, "PATH": f"{d/'bin'}:{os.environ['PATH']}", "LOG": str(d / "log"),
                 "STATE": str(d / "state"), "VERSIONS": versions, "FRONT_CODES": front, "APP_RC": str(app_rc), "FETCH_RC": str(fetch_rc),
                 "EXISTING": existing, "CLUSTERS_DIR": str(d / "clusters"), "CONVERGE_SECONDS": str(converge),
                 "FRONTEND_SECONDS": str(frontend), "GH_REPO": "o/r", "RUN_URL": "u", "GH_TOKEN": "tok",
                 "SMOKE_USERNAME": "x", "SMOKE_PASSWORD": "y"},
        )
        log = (d / "log").read_text() if (d / "log").exists() else ""
        return r, log


class Pass(unittest.TestCase):
    def test_converged_release_passes_and_closes_the_issue(self):
        # The manifest says v0.291.0, the app reports 0.291.0 (kills comparing with the v prefix).
        r, log = run(existing=issue(7))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("gh issue close 7", log)
        self.assertNotIn("issue create", log)

    def test_rollout_gap_is_waited_for(self):
        # Old version, a 5xx and an HTML page during the Recreate gap, then the new one (kills a single-shot check
        # and treating a non-JSON answer as a failure).
        r, log = run(versions="0.290.0,down,html,0.291.0")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("issue create", log)
        self.assertIn("after 4 poll(s)", r.stdout)
        # Every poll carries its own cache-busting query, so Cloudflare cannot replay an old body.
        self.assertIn("/health?smoke=local-4", log)

    def test_unchanged_version_settles_before_checking(self):
        # A push that leaves the backend tag alone (a policy, a Secret) is not applied yet on the first poll: the
        # checks must wait for Flux (kills testing the old state at once).
        r, log = run(versions="0.291.0")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("sleep 150", log)
        self.assertLess(log.index("sleep 150"), log.index("http_code"))

    def test_changed_version_does_not_settle(self):
        r, log = run()
        self.assertNotIn("sleep 150", log)

    def test_frontend_rollout_is_waited_for(self):
        # The frontend rolls out on its own: 503s first, then three 200s pass (kills failing on the first non-200).
        r, log = run(front="503,503,200", frontend=30)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(log.count("http_code"), 5, log)

    def test_frontend_needs_three_in_a_row(self):
        # 200, 502, then 200s: the streak restarts, so it takes 1 + 1 + 3 checks (kills counting non-consecutive 200s).
        r, log = run(front="200,502,200", frontend=30)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(log.count("http_code"), 5, log)

    def test_app_smoke_is_fetched_at_the_deployed_tag_without_the_token(self):
        # Kills fetching the script from main (or a branch named like the tag), and exporting GH_TOKEN to it.
        r, log = run()
        self.assertIn("repos/fjcloudaiconsulting/tbd/contents/scripts/smoke-test.sh?ref=refs/tags/v0.291.0", log)
        self.assertIn("app smoke base=https://app.thebetterdecision.com user=set gh=unset", r.stdout)

    def test_backend_tag_is_read_not_the_migrations_tag(self):
        m = "image: ghcr.io/fjcloudaiconsulting/tbd/migrations:v0.290.0\n" + TBD.format("v0.291.0")
        r, log = run(manifest=m)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_quoted_or_digest_pinned_tag_is_read(self):
        for m in ("image: 'ghcr.io/fjcloudaiconsulting/tbd/backend:v0.291.0'\n",
                  "image: ghcr.io/fjcloudaiconsulting/tbd/backend:v0.291.0@sha256:abc\n"):
            r, log = run(manifest=m)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_tbd_staging_is_health_and_frontend_only(self):
        # Staging has no smoke account: its own host, no app smoke fetched or run (kills a copied tbd-prod entry,
        # which would fetch smoke-test.sh and fail on the missing login).
        # Its own manifest (v0.292.0, prod is v0.291.0): kills reading the tbd-prod tag for staging.
        r, log = run("tbd-staging", versions="0.292.0")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("https://dev.thebetterdecision.com/health", log)
        self.assertNotIn("app.thebetterdecision.com", log)
        self.assertNotIn("contents/scripts", log)
        self.assertNotIn("app smoke", r.stdout)

    def test_tbd_staging_frontend_check_hits_the_bypassed_path_without_following_redirects(self):
        # Behind Cloudflare Access only /health and /robots.txt are open (INFRA-117). A GET / with -L would follow
        # the login redirect to a 200 page and pass falsely (kills reusing the prod frontend check).
        r, log = run("tbd-staging", versions="0.292.0")
        front = [l for l in log.splitlines() if "http_code" in l]
        self.assertEqual(len(front), 3, log)
        for l in front:
            self.assertTrue(l.endswith("https://dev.thebetterdecision.com/robots.txt"), l)
            self.assertNotIn(" -L ", l)
        self.assertIn("frontend GET /robots.txt 200 x3", r.stdout)

    def test_other_environments_still_follow_redirects_on_the_root(self):
        # Prod's / redirects (307): kills dropping -L or the root path for everyone.
        r, log = run()
        front = [l for l in log.splitlines() if "http_code" in l]
        self.assertTrue(front and all(" -L " in l and l.endswith("https://app.thebetterdecision.com/") for l in front), log)

    def test_ziftbook_runs_its_app_smoke_at_the_deployed_tag(self):
        # Kills app_smoke="" for ziftbook-staging (the database-reachable check would never run).
        r, log = run("ziftbook-staging")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("repos/fjcloudaiconsulting/ziftbook/contents/scripts/smoke-test.sh?ref=refs/tags/v0.291.0", log)
        self.assertIn("https://dev.ziftbook.com/api/healthz", log)

    def test_ziftbook_prod_uses_app_host(self):
        r, log = run("ziftbook-prod")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("https://app.ziftbook.com/api/healthz", log)
        self.assertNotIn("dev.ziftbook.com", log)
        # Kills app_smoke="" for ziftbook-prod: production runs the app's database-reachable check too.
        self.assertIn("repos/fjcloudaiconsulting/ziftbook/contents/scripts/smoke-test.sh?ref=refs/tags/v0.291.0", log)

    def test_pass_closes_only_its_own_namespace_issue(self):
        # Other issues listed first: the ziftbook-staging one and a title that starts with ours (kills taking the
        # first row, and a prefix match).
        r, log = run(existing=issue(3, "ziftbook-staging") + issue(5, "tbd-prod-canary") + issue(8))
        self.assertIn("gh issue close 8", log)
        self.assertNotIn("issue close 3", log)
        self.assertNotIn("issue close 5", log)

    def test_lookup_is_limited_to_the_actions_bot(self):
        # The repo is public: an outsider's issue with the same title must never be the alarm.
        r, log = run()
        self.assertIn("--author app/github-actions", log)


class Alarm(unittest.TestCase):
    def assert_alarm(self, r, log, text):
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("gh issue create --title [post-deploy-smoke] tbd-prod --body", log)
        self.assertIn(text, log)
        self.assertNotIn("issue close", log)
        self.assertNotIn("SMOKE-OUTPUT-MARKER", log)  # the smoke output stays in the run log

    def test_never_converged_names_both_versions(self):
        r, log = run(versions="0.290.0", converge=0)
        self.assert_alarm(r, log, "never converged (live 0.290.0, expected 0.291.0)")
        self.assertNotIn("contents/", log)  # no login when the new pods never came up

    def test_down_app_never_converges(self):
        self.assert_alarm(*run(versions="down", converge=0), "never converged (live none, expected 0.291.0)")

    def test_frontend_failure_after_two_good_checks(self):
        # Kills checking the frontend once, or ignoring its status code.
        self.assert_alarm(*run(front="200,200,502"), "frontend GET / returned 502")

    def test_app_smoke_fetch_failure(self):
        # Kills ignoring the fetch: an empty file would "pass" and close the issue.
        self.assert_alarm(*run(fetch_rc=1), "could not fetch tbd scripts/smoke-test.sh at v0.291.0")

    def test_app_smoke_failure(self):
        self.assert_alarm(*run(app_rc=1), "app smoke failed")

    def test_existing_issue_gets_a_comment_not_a_duplicate(self):
        r, log = run(versions="0.290.0", converge=0, existing=issue(7))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("gh issue comment 7", log)
        self.assertNotIn("issue create", log)

    def test_other_namespace_issue_is_not_reused(self):
        r, log = run(versions="0.290.0", converge=0, existing=issue(3, "ziftbook-staging"))
        self.assert_alarm(r, log, "never converged")
        self.assertNotIn("comment 3", log)

    def test_rc_tag_in_manifest_raises_the_alarm(self):
        self.assert_alarm(*run(manifest=TBD.format("v0.292.0-rc1")), "bad backend tag")

    def test_missing_tag_in_manifest_raises_the_alarm(self):
        self.assert_alarm(*run(manifest="kind: Deployment\n"), "bad backend tag")

    def test_two_backend_tags_raise_the_alarm(self):
        self.assert_alarm(*run(manifest=TBD.format("v0.291.0") + TBD.format("v0.292.0")), "bad backend tag")

    def test_unknown_namespace_is_a_usage_error(self):
        r, log = run("nope")
        self.assertEqual(r.returncode, 2)
        self.assertNotIn("issue", log)


if __name__ == "__main__":
    unittest.main()
