"""Every Secret under clusters/ is SOPS-encrypted (INFRA-23).

Stdlib only so CI needs no installs: `python3 -m unittest discover -s tests`.
"""
import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECK = ROOT / ".github/scripts/check-sops-secrets.py"

SOPS_TAIL = """\
sops:
    age:
        - recipient: age1example
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            -----END AGE ENCRYPTED FILE-----
    encrypted_regex: ^(data|stringData)$
    mac: ENC[AES256_GCM,data:bWFj,iv:aXY=,tag:dGFn,type:str]
    version: 3.13.3
"""

SECRET_HEAD = """\
apiVersion: v1
kind: Secret
metadata:
    name: s
    namespace: flux-system
type: Opaque
"""


def run(files):
    with tempfile.TemporaryDirectory() as d:
        for name, body in files.items():
            p = pathlib.Path(d, name)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(textwrap.dedent(body))
        return subprocess.run(
            ["python3", str(CHECK), d], capture_output=True, text=True
        )


class SopsSecrets(unittest.TestCase):
    def assertFails(self, files, needle):
        r = run(files)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(needle, r.stdout + r.stderr)

    def test_repo_clusters_pass(self):
        # guard: the committed tree (canary + Flux components) is clean.
        r = subprocess.run(
            ["python3", str(CHECK), str(ROOT / "clusters")], capture_output=True, text=True
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_encrypted_secret_passes(self):
        # guard: a correctly encrypted file, data and stringData both ENC.
        r = run({"a/x.secret.yaml": SECRET_HEAD
                 + "data:\n    k: ENC[AES256_GCM,data:eA==,type:str]\n"
                 + "stringData:\n    k2: ENC[AES256_GCM,data:eA==,type:str]\n"
                 + SOPS_TAIL})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_secret_file_without_sops_metadata_fails(self):
        # fence: kills a check that trusts the .secret.yaml name alone.
        self.assertFails(
            {"x.secret.yaml": SECRET_HEAD + "stringData:\n    k: ENC[fake]\n"},
            "x.secret.yaml",
        )

    def test_plaintext_value_with_sops_metadata_fails(self):
        # fence: kills a check that only looks for a sops: block
        # (e.g. a file encrypted with a wrong encrypted_regex, then edited).
        self.assertFails(
            {"x.secret.yaml": SECRET_HEAD
             + "stringData:\n    ok: ENC[AES256_GCM,data:eA==,type:str]\n    pw: hunter2\n"
             + SOPS_TAIL},
            "pw",
        )

    def test_block_scalar_value_fails(self):
        # fence: kills a value check that skips multi-line (|) values.
        self.assertFails(
            {"x.secret.yaml": SECRET_HEAD + "data:\n    k: |\n        aHVudGVyMg==\n" + SOPS_TAIL},
            "x.secret.yaml",
        )

    def test_secret_outside_secret_yaml_fails(self):
        # fence: kills a check that only scans *.secret.yaml files.
        self.assertFails(
            {"app/deploy.yaml": "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: c\n---\n"
             + SECRET_HEAD + "stringData:\n  pw: hunter2\n"},
            "deploy.yaml",
        )

    def test_yml_extension_is_scanned(self):
        # fence: kills a scan limited to *.yaml.
        self.assertFails(
            {"app/s.yml": SECRET_HEAD + "stringData:\n  pw: hunter2\n"},
            "s.yml",
        )


if __name__ == "__main__":
    unittest.main()
