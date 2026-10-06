"""Prod image tags must not be newer than staging's (INFRA-89). Stdlib only."""
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / ".github/scripts/check-prod-tags.py"


def img(repo, name, tag):
    return f"          image: ghcr.io/fjcloudaiconsulting/{repo}/{name}:{tag}\n"


def run(layout):
    """layout: {dir under the clusters root: {file: text}}."""
    with tempfile.TemporaryDirectory() as d:
        for rel, files in layout.items():
            (pathlib.Path(d) / rel).mkdir(parents=True)
            for n, t in files.items():
                (pathlib.Path(d) / rel / n).write_text(t)
        return subprocess.run(["python3", "-I", str(SCRIPT), d], capture_output=True, text=True)


def tbd(prod, stg):
    return {"p/tbd-prod": {"a.yaml": "".join(img("tbd", n, t) for n, t in prod)},
            "p/tbd-staging": {"a.yaml": "".join(img("tbd", n, t) for n, t in stg)}}


class ProdTags(unittest.TestCase):
    def test_equal_passes(self):
        self.assertEqual(run(tbd([("backend", "v0.2.0")], [("backend", "v0.2.0")])).returncode, 0)

    def test_prod_ahead_fails(self):
        r = run(tbd([("backend", "v0.3.0")], [("backend", "v0.2.0")]))
        self.assertEqual(r.returncode, 1)
        self.assertIn("backend", r.stderr)

    def test_version_order_is_numeric(self):
        # v0.10.0 is newer than v0.9.0 (kills string comparison).
        self.assertEqual(run(tbd([("backend", "v0.10.0")], [("backend", "v0.9.0")])).returncode, 1)
        self.assertEqual(run(tbd([("backend", "v0.9.0")], [("backend", "v0.10.0")])).returncode, 0)

    def test_prod_older_passes_for_rollback(self):
        self.assertEqual(run(tbd([("backend", "v0.1.0")], [("backend", "v0.2.0")])).returncode, 0)

    def test_lagging_staging_ref_bounds_prod(self):
        # staging runs backend v0.2.0 in one manifest and v0.3.0 in another: v0.3.0 is not safe (kills "max").
        r = run(tbd([("backend", "v0.3.0")], [("backend", "v0.2.0"), ("backend", "v0.3.0")]))
        self.assertEqual(r.returncode, 1)

    def test_lagging_staging_image_bounds_whole_repo(self):
        # staging frontend lags: prod backend v0.3.0 is not a fully staged release (kills per-image comparison).
        r = run(tbd([("backend", "v0.3.0")], [("backend", "v0.3.0"), ("frontend", "v0.2.0")]))
        self.assertEqual(r.returncode, 1)
        self.assertIn("backend", r.stderr)

    def test_image_missing_in_staging_fails(self):
        r = run(tbd([("backend", "v0.2.0"), ("scheduler", "v0.2.0")], [("backend", "v0.2.0")]))
        self.assertEqual(r.returncode, 1)
        self.assertIn("scheduler", r.stderr)

    def test_prod_without_staging_dir_fails(self):
        # Fail closed: a new <app>-prod must come with its staging (kills "skip apps without staging").
        r = run({"p/zift-prod": {"a.yaml": img("zift", "api", "v1.0.0")}})
        self.assertEqual(r.returncode, 1)
        self.assertIn("zift-staging", r.stderr)

    def test_any_app_is_covered(self):
        # No app name is hard-coded: a second app is checked without a code change.
        layout = tbd([("backend", "v0.2.0")], [("backend", "v0.2.0")])
        layout["p/zift-prod"] = {"a.yaml": img("zift", "api", "v1.1.0")}
        layout["p/zift-staging"] = {"a.yaml": img("zift", "api", "v1.0.0")}
        r = run(layout)
        self.assertEqual(r.returncode, 1)
        self.assertIn("zift/api", r.stderr)

    def test_non_semver_prod_tag_fails(self):
        self.assertEqual(run(tbd([("backend", "latest")], [("backend", "v0.2.0")])).returncode, 1)

    def test_non_semver_staging_tag_fails(self):
        self.assertEqual(run(tbd([("backend", "v0.2.0")], [("backend", "sha-abc1234")])).returncode, 1)

    def test_no_prod_dir_is_an_error(self):
        # Never a silent pass if the layout changes under the check.
        self.assertEqual(run({"p/tbd-staging": {"a.yaml": img("tbd", "backend", "v0.2.0")}}).returncode, 1)

    def test_prod_dir_without_images_fails(self):
        r = run({"p/tbd-prod": {"a.yaml": "kind: Service\n"}, "p/tbd-staging": {"a.yaml": img("tbd", "backend", "v0.2.0")}})
        self.assertEqual(r.returncode, 1)


if __name__ == "__main__":
    unittest.main()
