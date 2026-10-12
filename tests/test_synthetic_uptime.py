"""Fences for the Synthetic Monitoring payloads (INFRA-172): free-tier budget and check/alert job names stay in step."""
import json
import unittest
from pathlib import Path

G = Path(__file__).resolve().parents[1] / "grafana"
FREE_EXECUTIONS = 100_000  # Grafana Cloud free tier, test executions per month
PROBES = 2  # the apply step picks two EU probes
MONTH_MS = 31 * 86400 * 1000


class SyntheticUptime(unittest.TestCase):
    def test_checks_fit_free_tier_and_are_covered_by_the_alert(self):
        checks = [json.loads(p.read_text()) for p in sorted(G.glob("synthetic-*.check.json"))]
        rule = json.loads((G / "synthetic-uptime.rules.json").read_text())["rules"][0]
        expr = rule["data"][0]["model"]["expr"]
        self.assertEqual(len(checks), 2)
        self.assertLessEqual(sum(MONTH_MS // c["frequency"] * PROBES for c in checks), FREE_EXECUTIONS)
        for c in checks:
            self.assertIn(c["job"], expr)
            self.assertEqual(c["settings"]["http"]["validStatusCodes"], [200])
        self.assertEqual(rule["notification_settings"]["receiver"], "owner-email")


if __name__ == "__main__":
    unittest.main()
