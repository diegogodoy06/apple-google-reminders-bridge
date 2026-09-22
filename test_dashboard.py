#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("dashboard.py")
SPEC = importlib.util.spec_from_file_location("dashboard", MODULE_PATH)
assert SPEC and SPEC.loader
dashboard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = dashboard
SPEC.loader.exec_module(dashboard)


class DashboardHistoryTests(unittest.TestCase):
    def test_parses_successful_runs_and_actions(self):
        content = """2026-09-22T14:42:32Z sync started
Mode: apply
Summary: skip=92, update_google=1
66. UPDATE_GOOGLE [apple-to-google]: Example (due=2026-09-23 at 12:00; apple-changed)
2026-09-22T14:42:40Z sync finished exit=0
2026-09-22T14:47:40Z sync started
Mode: apply
Summary: skip=92, unchanged=5
2026-09-22T14:47:44Z sync finished exit=0
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sync.log"
            path.write_text(content, encoding="utf-8")
            history = dashboard.parse_history(path)
        self.assertEqual(len(history), 2)
        self.assertEqual(history[0]["summary"], {"skip": 92, "unchanged": 5})
        self.assertEqual(history[1]["actions"][0]["kind"], "update_google")
        self.assertEqual(history[1]["actions"][0]["title"], "Example")

    def test_keeps_an_in_progress_run(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sync.log"
            path.write_text("2026-09-22T14:50:00Z sync started\n", encoding="utf-8")
            history = dashboard.parse_history(path)
        self.assertIsNone(history[0]["finished_at"])
        self.assertIsNone(history[0]["exit_code"])

    def test_missing_log_is_an_empty_history(self):
        self.assertEqual(dashboard.parse_history(Path("/definitely/missing/sync.log")), [])


if __name__ == "__main__":
    unittest.main()
