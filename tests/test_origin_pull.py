"""Traefik's origin pull client-cert requirement stays intact (INFRA-93).

Checks the real clusters/ tree, because each way to break it is silent:
- a second TLSOption named default (any namespace): Traefik drops both and falls back to no client auth (open);
- a router or entrypoint naming its own TLS option: those hosts skip the default (open);
- a listed CA Secret missing, or without a ca.crt / tls.ca key: Traefik fails closed for every host (outage).
Stdlib only, line-based, like .github/scripts/check-sops-secrets.py.
"""
import pathlib
import re
import unittest

CLUSTERS = pathlib.Path(__file__).resolve().parent.parent / "clusters"


def docs():
    for path in sorted(CLUSTERS.rglob("*.y*ml")):
        for doc in re.split(r"^---\s*$", path.read_text(), flags=re.M):
            yield path, doc


def field(doc, key):
    m = re.search(rf"^\s*{key}:\s*[\"']?([^\"'\s#]+)", doc, re.M)
    return m.group(1) if m else None


class OriginPull(unittest.TestCase):
    def test_one_default_tlsoption_requires_our_ca(self):
        defaults = [d for _, d in docs() if field(d, "kind") == "TLSOption" and field(d, "name") == "default"]
        self.assertEqual(len(defaults), 1, "exactly one TLSOption named default, in any namespace")
        opt = defaults[0]
        self.assertEqual(field(opt, "clientAuthType"), "RequireAndVerifyClientCert")
        block = re.search(r"^\s*secretNames:\s*\n((?:\s+-\s*\S+\s*\n?)+)", opt, re.M)
        self.assertIsNotNone(block, "clientAuth.secretNames is empty")
        names = re.findall(r"-\s*(\S+)", block.group(1))
        # SOPS encrypts only data values, so the key names stay readable.
        secrets = {
            (field(d, "name"), field(d, "namespace")): bool(re.search(r"(?m)^\s+(ca\.crt|tls\.ca):", d))
            for p, d in docs()
            if p.name.endswith(".secret.yaml") and field(d, "kind") == "Secret"
        }
        for name in names:
            key = (name, field(opt, "namespace"))
            self.assertIn(key, secrets, f"CA Secret {name} missing: every host fails closed")
            self.assertTrue(secrets[key], f"CA Secret {name} has no ca.crt or tls.ca key: every host fails closed")

    def test_nothing_bypasses_the_default(self):
        for path, doc in docs():
            kind = field(doc, "kind")
            if kind in ("IngressRoute", "IngressRouteTCP"):
                self.assertNotRegex(doc, r"(?m)^\s+options:", f"{path}: router names its own TLS option")
            if kind == "Ingress":
                self.assertNotIn("router.tls.options", doc, f"{path}: Ingress names its own TLS option")
            if kind in ("HelmChartConfig", "HelmChart"):
                # Traefik chart values ports.<ep>.tls.options, or the --entryPoints.<ep>.http.tls.options flag.
                self.assertNotRegex(doc, r"(?m)tls\.options|^\s+options:", f"{path}: entrypoint names its own TLS option")


if __name__ == "__main__":
    unittest.main()
