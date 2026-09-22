#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo


MODULE_PATH = Path(__file__).with_name("bridge.py")
SPEC = importlib.util.spec_from_file_location("bridge", MODULE_PATH)
assert SPEC and SPEC.loader
bridge = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bridge
SPEC.loader.exec_module(bridge)
ZONE = ZoneInfo("America/Sao_Paulo")


class AuthorizationArgumentsTests(unittest.TestCase):
    def test_authorize_only_does_not_require_apple_or_state(self):
        with patch.object(sys, "argv", ["bridge.py", "--authorize-only", "--credentials", "client.json", "--token", "token.json"]):
            args = bridge.parse_args()
        self.assertTrue(args.authorize_only)
        self.assertIsNone(args.state)

    def test_sync_still_requires_apple_source_and_state(self):
        with patch.object(sys, "argv", ["bridge.py", "--credentials", "client.json", "--token", "token.json"]):
            with redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    bridge.parse_args()

    def test_authorize_only_never_reads_reminders(self):
        args = argparse.Namespace(
            authorize_only=True,
            credentials=Path("client.json"),
            token=Path("token.json"),
            google_browser="safari",
        )
        with patch.object(bridge, "parse_args", return_value=args), \
             patch.object(bridge, "load_google_credentials") as authorize, \
             patch.object(bridge, "load_apple_reminders", side_effect=AssertionError("read Apple")):
            with redirect_stdout(io.StringIO()):
                self.assertEqual(bridge.main(), 0)
            authorize.assert_called_once()


def apple(
    *,
    reminder_id="APPLE-1",
    completed=False,
    modified="2026-09-22T12:00:00Z",
    title="Task",
    due="2026-09-23T15:00:00Z",
    created="2026-06-25T16:56:25Z",
    recurrence=None,
):
    item = {
        "id": reminder_id,
        "title": title,
        "isCompleted": completed,
        "dueDate": due,
        "dueDateIsAllDay": False,
        "lastModifiedDate": modified,
        "creationDate": created,
        "listID": "LIST-1",
        "listName": "Personal",
        "priority": "none",
    }
    if recurrence:
        item["recurrenceRule"] = recurrence
    return item


def google(
    *,
    task_id="GOOGLE-1",
    apple_id="APPLE-1",
    completed=False,
    updated="2026-09-22T11:00:00Z",
    title="Task",
    due="2026-09-23T00:00:00.000Z",
    marker=None,
):
    return {
        "id": task_id,
        "title": title,
        "status": "completed" if completed else "needsAction",
        "due": due,
        "updated": updated,
        "notes": f"{marker or bridge.MARKER}\napple_reminder_id: {apple_id}",
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

    def test_legacy_marker_is_upgraded_without_creating_a_duplicate(self):
        current_a = apple()
        current_g = google(marker=bridge.LEGACY_MARKER)
        action = self.plan(current_a, current_g, {"version": 1, "mappings": {}})
        self.assertEqual(action.kind, "update_google")
        self.assertEqual(action.reason, "bridge-metadata-upgrade")
        self.assertEqual(action.google_task_id, "GOOGLE-1")

    def test_recurrence_series_is_stable_across_apple_occurrence_ids(self):
        rule = {"frequency": "daily", "interval": 1}
        old = apple(reminder_id="APPLE-OLD", completed=True, due="2026-09-22T15:00:00Z")
        current = apple(reminder_id="APPLE-NEW", due="2026-09-23T15:00:00Z", recurrence=rule)
        catalog = bridge.recurrence_catalog([old, current])
        self.assertEqual(
            bridge.recurrence_series_id(old, catalog),
            bridge.recurrence_series_id(current, catalog),
        )
        self.assertEqual(bridge.recurrence_text(rule), "diária")

    def test_apple_recurring_completion_closes_old_google_and_creates_next(self):
        rule = {"frequency": "daily", "interval": 1}
        old = apple(
            reminder_id="APPLE-OLD",
            completed=True,
            due="2026-09-22T15:00:00Z",
            modified="2026-09-22T16:00:00Z",
        )
        current = apple(
            reminder_id="APPLE-NEW",
            due="2026-09-23T15:00:00Z",
            recurrence=rule,
            modified="2026-09-22T16:00:00Z",
        )
        old_before = apple(
            reminder_id="APPLE-OLD",
            due="2026-09-22T15:00:00Z",
            modified="2026-09-22T12:00:00Z",
        )
        old_google = google(
            apple_id="APPLE-OLD",
            due="2026-09-22T00:00:00.000Z",
        )
        old_catalog = bridge.recurrence_catalog([old_before, current])
        state = {
            "version": 3,
            "mappings": {
                "APPLE-OLD": {
                    "google_task_id": "GOOGLE-1",
                    "apple_snapshot": bridge.apple_snapshot(old_before, ZONE, old_catalog),
                    "google_snapshot": bridge.google_snapshot(old_google),
                }
            },
        }
        actions, _, desired = bridge.build_plan(
            [old, current],
            {"APPLE-OLD": old_google},
            set(),
            state,
            ZONE,
            "bidirectional",
        )
        by_id = {action.apple_id: action for action in actions}
        self.assertEqual(by_id["APPLE-OLD"].kind, "update_google")
        self.assertEqual(by_id["APPLE-NEW"].kind, "create_google")
        self.assertEqual(by_id["APPLE-NEW"].reason, "new-recurrence-occurrence")
        self.assertEqual(by_id["APPLE-OLD"].series_id, by_id["APPLE-NEW"].series_id)
        self.assertIn("Recorrência Apple: diária", desired["APPLE-NEW"]["notes"])
        self.assertIn("apple_series_id:", desired["APPLE-NEW"]["notes"])

    def test_google_completion_of_current_recurring_occurrence_updates_apple(self):
        rule = {"frequency": "daily", "interval": 1}
        current_a = apple(recurrence=rule)
        previous_g = google()
        catalog = bridge.recurrence_catalog([current_a])
        state = {
            "version": 3,
            "mappings": {
                "APPLE-1": {
                    "google_task_id": "GOOGLE-1",
                    "apple_snapshot": bridge.apple_snapshot(current_a, ZONE, catalog),
                    "google_snapshot": bridge.google_snapshot(previous_g),
                }
            },
        }
        completed_g = google(completed=True, updated="2026-09-22T13:00:00Z")
        actions, _, _ = bridge.build_plan(
            [current_a],
            {"APPLE-1": completed_g},
            set(),
            state,
            ZONE,
            "bidirectional",
        )
        self.assertEqual(actions[0].kind, "update_apple")
        self.assertEqual(actions[0].reason, "google-changed")

    def test_completed_recurring_history_without_mapping_is_not_backfilled(self):
        rule = {"frequency": "daily", "interval": 1}
        old = apple(reminder_id="APPLE-OLD", completed=True, due="2026-09-22T15:00:00Z")
        current = apple(reminder_id="APPLE-NEW", recurrence=rule)
        actions, _, _ = bridge.build_plan(
            [old, current], {}, set(), {"version": 3, "mappings": {}}, ZONE, "bidirectional"
        )
        by_id = {action.apple_id: action for action in actions}
        self.assertEqual(by_id["APPLE-OLD"].kind, "skip")
        self.assertEqual(by_id["APPLE-NEW"].kind, "create_google")


if __name__ == "__main__":
    unittest.main()
