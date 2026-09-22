#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from zoneinfo import ZoneInfo


MODULE_PATH = Path(__file__).with_name("bridge.py")
SPEC = importlib.util.spec_from_file_location("bridge", MODULE_PATH)
assert SPEC and SPEC.loader
bridge = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bridge
SPEC.loader.exec_module(bridge)
ZONE = ZoneInfo("America/Sao_Paulo")


def apple(*, completed=False, modified="2026-09-22T12:00:00Z", title="Task", due="2026-09-23T15:00:00Z"):
    return {
        "id": "APPLE-1",
        "title": title,
        "isCompleted": completed,
        "dueDate": due,
        "dueDateIsAllDay": False,
        "lastModifiedDate": modified,
        "listName": "Personal",
        "priority": "none",
    }


def google(*, completed=False, updated="2026-09-22T11:00:00Z", title="Task", due="2026-09-23T00:00:00.000Z"):
    return {
        "id": "GOOGLE-1",
        "title": title,
        "status": "completed" if completed else "needsAction",
        "due": due,
        "updated": updated,
        "notes": f"{bridge.MARKER}\napple_reminder_id: APPLE-1",
    }


def state_for(a, g):
    return {
        "version": 2,
        "mappings": {
            "APPLE-1": {
                "google_task_id": "GOOGLE-1",
                "apple_snapshot": bridge.apple_snapshot(a, ZONE),
                "google_snapshot": bridge.google_snapshot(g),
            }
        },
    }


class BridgePlanTests(unittest.TestCase):
    def plan(self, current_a, current_g, state):
        actions, _, _ = bridge.build_plan(
            [current_a], {"APPLE-1": current_g}, set(), state, ZONE, "bidirectional"
        )
        return actions[0]

    def test_unchanged_pair(self):
        a, g = apple(), google()
        self.assertEqual(self.plan(a, g, state_for(a, g)).kind, "unchanged")

    def test_completion_in_apple_updates_google(self):
        previous_a, previous_g = apple(), google()
        action = self.plan(apple(completed=True), previous_g, state_for(previous_a, previous_g))
        self.assertEqual(action.kind, "update_google")

    def test_completion_in_google_updates_apple(self):
        previous_a, previous_g = apple(), google()
        action = self.plan(previous_a, google(completed=True), state_for(previous_a, previous_g))
        self.assertEqual(action.kind, "update_apple")

    def test_reopen_in_google_updates_apple(self):
        previous_a = apple(completed=True)
        previous_g = google(completed=True)
        action = self.plan(previous_a, google(completed=False), state_for(previous_a, previous_g))
        self.assertEqual(action.kind, "update_apple")

    def test_both_changed_newer_google_wins(self):
        previous_a, previous_g = apple(), google()
        current_a = apple(title="Apple title", modified="2026-09-22T12:00:00Z")
        current_g = google(title="Google title", updated="2026-09-22T13:00:00Z")
        action = self.plan(current_a, current_g, state_for(previous_a, previous_g))
        self.assertEqual(action.kind, "update_apple")

    def test_new_open_apple_task_creates_google_task(self):
        actions, _, _ = bridge.build_plan(
            [apple()], {}, set(), {"version": 2, "mappings": {}}, ZONE, "bidirectional"
        )
        self.assertEqual(actions[0].kind, "create_google")

    def test_completed_unmapped_apple_task_is_skipped(self):
        actions, _, _ = bridge.build_plan(
            [apple(completed=True)], {}, set(), {"version": 2, "mappings": {}}, ZONE, "bidirectional"
        )
        self.assertEqual(actions[0].kind, "skip")


if __name__ == "__main__":
    unittest.main()
