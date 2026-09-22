#!/usr/bin/env python3
"""Safe bidirectional bridge between Apple Reminders and Google Tasks.

Dry-run is the default. Writes require both --apply and --confirm APPLY.
Only Google tasks carrying this bridge's marker are ever modified or read back
into Apple Reminders. Deletions are intentionally not synchronized.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from zoneinfo import ZoneInfo

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build


SCOPES = ["https://www.googleapis.com/auth/tasks"]
LEGACY_MARKER = "[apple-reminders-bridge:v1]"
MARKER = "[apple-reminders-bridge:v2]"
APPLE_ID_RE = re.compile(r"^apple_reminder_id: ([^\n]+)$", re.MULTILINE)
APPLE_SERIES_ID_RE = re.compile(r"^apple_series_id: ([^\n]+)$", re.MULTILINE)


@dataclass
class Action:
    kind: str
    direction: str
    apple_id: str
    title: str
    reason: str
    google_task_id: str | None = None
    due_date: str | None = None
    original_time: str | None = None
    series_id: str | None = None
    recurrence: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bidirectional Apple Reminders and Google Tasks bridge."
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--apple-json", type=Path, help="Previously exported remindctl JSON.")
    source.add_argument("--remindctl", type=Path, help="Path to an authorized remindctl executable.")
    parser.add_argument("--credentials", type=Path, required=True)
    parser.add_argument("--token", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--tasklist-id", default="@default")
    parser.add_argument("--timezone", default="America/Sao_Paulo")
    parser.add_argument(
        "--direction",
        choices=("apple-to-google", "bidirectional"),
        default="bidirectional",
    )
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirm", help="Required literal APPLY when --apply is used.")
    parser.add_argument("--plan-json", type=Path)
    parser.add_argument(
        "--summary-only",
        action="store_true",
        help="Print only action counts and changes, omitting unchanged/skipped items.",
    )
    return parser.parse_args()


def load_apple_reminders(args: argparse.Namespace) -> list[dict[str, Any]]:
    if args.apple_json:
        data = json.loads(args.apple_json.read_text(encoding="utf-8"))
    else:
        completed = subprocess.run(
            [str(args.remindctl), "show", "all", "--json", "--no-input"],
            check=True,
            capture_output=True,
            text=True,
        )
        data = json.loads(completed.stdout)
    if not isinstance(data, list):
        raise ValueError("Expected remindctl to return a JSON array.")
    return data


def load_google_credentials(credentials_path: Path, token_path: Path) -> Credentials:
    credentials = None
    if token_path.exists():
        credentials = Credentials.from_authorized_user_file(token_path, SCOPES)
    if credentials and credentials.expired and credentials.refresh_token:
        credentials.refresh(Request())
        write_private_json(token_path, json.loads(credentials.to_json()))
    if not credentials or not credentials.valid:
        flow = InstalledAppFlow.from_client_secrets_file(credentials_path, SCOPES)
        credentials = flow.run_local_server(port=0, open_browser=False)
        write_private_json(token_path, json.loads(credentials.to_json()))
    return credentials


def write_private_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(path, 0o600)


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 3, "mappings": {}}
    state = json.loads(path.read_text(encoding="utf-8"))
    state.setdefault("version", 3)
    state.setdefault("mappings", {})
    return state


def list_google_tasks(service, tasklist_id: str) -> list[dict[str, Any]]:
    tasks: list[dict[str, Any]] = []
    page_token = None
    while True:
        response = (
            service.tasks()
            .list(
                tasklist=tasklist_id,
                maxResults=100,
                pageToken=page_token,
                showCompleted=True,
                showHidden=True,
                showDeleted=False,
            )
            .execute()
        )
        tasks.extend(response.get("items", []))
        page_token = response.get("nextPageToken")
        if not page_token:
            return tasks


def parse_google_bridge_id(task: dict[str, Any]) -> str | None:
    notes = task.get("notes") or ""
    if MARKER not in notes and LEGACY_MARKER not in notes:
        return None
    match = APPLE_ID_RE.search(notes)
    return match.group(1).strip() if match else None


def google_marker_version(task: dict[str, Any]) -> int:
    notes = task.get("notes") or ""
    if MARKER in notes:
        return 2
    if LEGACY_MARKER in notes:
        return 1
    return 0


def parse_google_series_id(task: dict[str, Any]) -> str | None:
    notes = task.get("notes") or ""
    match = APPLE_SERIES_ID_RE.search(notes)
    return match.group(1).strip() if match else None


def index_bridge_tasks(
    google_tasks: Iterable[dict[str, Any]],
) -> tuple[dict[str, dict[str, Any]], set[str]]:
    result: dict[str, dict[str, Any]] = {}
    conflicts: set[str] = set()
    for task in google_tasks:
        apple_id = parse_google_bridge_id(task)
        if not apple_id:
            continue
        if apple_id in result:
            conflicts.add(apple_id)
        else:
            result[apple_id] = task
    return result, conflicts


def parse_timestamp(value: str | None) -> datetime:
    if not value:
        return datetime.min.replace(tzinfo=timezone.utc)
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def recurrence_signature(reminder: dict[str, Any]) -> str | None:
    creation_date = reminder.get("creationDate")
    list_id = reminder.get("listID")
    if not creation_date or not list_id:
        return None
    return f"{list_id}\0{creation_date}"


def recurrence_catalog(reminders: Iterable[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Map every occurrence in a series to the rule carried by its open occurrence.

    EventKit gives each completed occurrence a new reminder ID and only exposes the
    recurrence rule on the current open occurrence. Its list and creation timestamp
    stay stable, which lets us recognize completed occurrences without using titles.
    """
    catalog: dict[str, dict[str, Any]] = {}
    for reminder in reminders:
        rule = reminder.get("recurrenceRule")
        signature = recurrence_signature(reminder)
        if signature and isinstance(rule, dict) and rule.get("frequency"):
            catalog[signature] = rule
    return catalog


def recurrence_rule_for(
    reminder: dict[str, Any], catalog: dict[str, dict[str, Any]] | None = None
) -> dict[str, Any] | None:
    rule = reminder.get("recurrenceRule")
    if isinstance(rule, dict) and rule.get("frequency"):
        return rule
    signature = recurrence_signature(reminder)
    return catalog.get(signature) if catalog and signature else None


def recurrence_series_id(
    reminder: dict[str, Any], catalog: dict[str, dict[str, Any]] | None = None
) -> str | None:
    if not recurrence_rule_for(reminder, catalog):
        return None
    signature = recurrence_signature(reminder)
    if not signature:
        return None
    return hashlib.sha256(signature.encode("utf-8")).hexdigest()[:24]


def recurrence_text(rule: dict[str, Any] | None) -> str | None:
    if not rule:
        return None
    frequency = str(rule.get("frequency", "")).lower()
    interval = int(rule.get("interval") or 1)
    names = {
        "daily": ("diária", "dias"),
        "weekly": ("semanal", "semanas"),
        "monthly": ("mensal", "meses"),
        "yearly": ("anual", "anos"),
    }
    singular, plural = names.get(frequency, (frequency or "desconhecida", frequency))
    return singular if interval == 1 else f"a cada {interval} {plural}"


def apple_snapshot(
    reminder: dict[str, Any],
    zone: ZoneInfo,
    catalog: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    due = reminder.get("dueDate")
    due_date = None
    original_time = None
    if due:
        local_due = parse_timestamp(due).astimezone(zone)
        due_date = local_due.date().isoformat()
        if not reminder.get("dueDateIsAllDay"):
            original_time = local_due.strftime("%H:%M")
    rule = recurrence_rule_for(reminder, catalog)
    return {
        "title": reminder.get("title", ""),
        "completed": bool(reminder.get("isCompleted")),
        "due_date": due_date,
        "original_time": original_time,
        "all_day": bool(reminder.get("dueDateIsAllDay")),
        "list_name": reminder.get("listName", ""),
        "priority": reminder.get("priority", "none"),
        "recurrence": rule,
        "series_id": recurrence_series_id(reminder, catalog),
    }


def google_snapshot(task: dict[str, Any]) -> dict[str, Any]:
    due = task.get("due")
    return {
        "title": task.get("title", ""),
        "completed": task.get("status") == "completed",
        "due_date": due[:10] if due else None,
    }


def equivalent_core(apple: dict[str, Any], google: dict[str, Any]) -> bool:
    return (
        apple["title"] == google["title"]
        and apple["completed"] == google["completed"]
        and apple["due_date"] == google["due_date"]
    )


def desired_google_task(
    reminder: dict[str, Any],
    zone: ZoneInfo,
    catalog: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    snapshot = apple_snapshot(reminder, zone, catalog)
    time_text = snapshot["original_time"] or "dia inteiro"
    note_lines = [
        "Sincronizado do Apple Lembretes.",
        f"Lista Apple: {snapshot['list_name']}",
        f"Horário original: {time_text} ({zone.key})",
        f"Prioridade Apple: {snapshot['priority']}",
    ]
    recurrence = recurrence_text(snapshot["recurrence"])
    if recurrence:
        note_lines.append(f"Recorrência Apple: {recurrence}")
    note_lines.extend(
        [
            "",
            MARKER,
            f"apple_reminder_id: {reminder['id']}",
        ]
    )
    if snapshot["series_id"]:
        note_lines.append(f"apple_series_id: {snapshot['series_id']}")
    note_lines.append(f"apple_last_modified: {reminder.get('lastModifiedDate', '')}")
    notes = "\n".join(note_lines)
    body: dict[str, Any] = {
        "title": snapshot["title"],
        "notes": notes,
        "status": "completed" if snapshot["completed"] else "needsAction",
        "due": (
            f"{snapshot['due_date']}T00:00:00.000Z"
            if snapshot["due_date"]
            else None
        ),
    }
    if not snapshot["completed"]:
        body["completed"] = None
    return body


def build_plan(
    reminders: list[dict[str, Any]],
    google_by_apple_id: dict[str, dict[str, Any]],
    conflicts: set[str],
    state: dict[str, Any],
    zone: ZoneInfo,
    direction: str,
) -> tuple[list[Action], dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    actions: list[Action] = []
    reminder_by_id: dict[str, dict[str, Any]] = {}
    desired_by_id: dict[str, dict[str, Any]] = {}
    mappings = state.get("mappings", {})
    recurrence_rules = recurrence_catalog(reminders)

    for reminder in reminders:
        apple_id = reminder.get("id")
        title = reminder.get("title", "")
        if not apple_id:
            actions.append(Action("skip", "none", "", title, "missing-apple-id"))
            continue
        reminder_by_id[apple_id] = reminder
        apple = apple_snapshot(reminder, zone, recurrence_rules)
        desired_by_id[apple_id] = desired_google_task(reminder, zone, recurrence_rules)
        due = apple["due_date"]
        current_google = google_by_apple_id.get(apple_id)

        if apple_id in conflicts:
            actions.append(Action("conflict", "none", apple_id, title, "duplicate-google-markers"))
            continue
        if not current_google:
            if apple["completed"]:
                actions.append(Action("skip", "none", apple_id, title, "completed-without-mapping"))
            else:
                actions.append(
                    Action(
                        "create_google",
                        "apple-to-google",
                        apple_id,
                        title,
                        "new-recurrence-occurrence" if apple["recurrence"] else "not-yet-synced",
                        due_date=due,
                        original_time=apple["original_time"],
                        series_id=apple["series_id"],
                        recurrence=recurrence_text(apple["recurrence"]),
                    )
                )
            continue

        google = google_snapshot(current_google)
        previous = mappings.get(apple_id, {})
        previous_apple = previous.get("apple_snapshot")
        previous_google = previous.get("google_snapshot")
        apple_changed = previous_apple is not None and apple != previous_apple
        google_changed = previous_google is not None and google != previous_google
        needs_marker_upgrade = google_marker_version(current_google) < 2

        if previous_apple is None or previous_google is None:
            if equivalent_core(apple, google):
                chosen = "update_google" if needs_marker_upgrade else "unchanged"
                reason = "bridge-metadata-upgrade" if needs_marker_upgrade else "bootstrap-equivalent"
            elif direction == "apple-to-google":
                chosen = "update_google"
                reason = "bootstrap-apple-authoritative"
            elif parse_timestamp(reminder.get("lastModifiedDate")) >= parse_timestamp(current_google.get("updated")):
                chosen = "update_google"
                reason = "bootstrap-apple-newer"
            else:
                chosen = "update_apple"
                reason = "bootstrap-google-newer"
        elif apple_changed and not google_changed:
            chosen = "update_google"
            reason = "apple-changed"
        elif google_changed and not apple_changed:
            if direction == "bidirectional":
                chosen = "update_apple"
                reason = "google-changed"
            else:
                chosen = "update_google"
                reason = "apple-authoritative"
        elif apple_changed and google_changed:
            apple_modified = parse_timestamp(reminder.get("lastModifiedDate"))
            google_modified = parse_timestamp(current_google.get("updated"))
            if apple_modified > google_modified:
                chosen = "update_google"
                reason = "both-changed-apple-newer"
            elif direction == "bidirectional" and google_modified > apple_modified:
                chosen = "update_apple"
                reason = "both-changed-google-newer"
            else:
                chosen = "conflict"
                reason = "both-changed-same-timestamp"
        elif equivalent_core(apple, google):
            chosen = "update_google" if needs_marker_upgrade else "unchanged"
            reason = "bridge-metadata-upgrade" if needs_marker_upgrade else "already-synchronized"
        else:
            chosen = "conflict"
            reason = "state-diverged-without-detected-change"

        actions.append(
            Action(
                chosen,
                "apple-to-google" if chosen == "update_google" else "google-to-apple" if chosen == "update_apple" else "none",
                apple_id,
                title,
                reason,
                google_task_id=current_google.get("id"),
                due_date=due,
                original_time=apple["original_time"],
                series_id=apple["series_id"],
                recurrence=recurrence_text(apple["recurrence"]),
            )
        )
    return actions, reminder_by_id, desired_by_id


def apply_google_action(service, tasklist_id: str, action: Action, body: dict[str, Any]) -> dict[str, Any]:
    if action.kind == "create_google":
        insert_body = {key: value for key, value in body.items() if value is not None}
        return service.tasks().insert(tasklist=tasklist_id, body=insert_body).execute()
    if action.kind == "update_google":
        return (
            service.tasks()
            .patch(tasklist=tasklist_id, task=action.google_task_id, body=body)
            .execute()
        )
    raise ValueError(f"Unsupported Google action: {action.kind}")


def apply_apple_action(
    remindctl: Path,
    action: Action,
    reminder: dict[str, Any],
    google_task: dict[str, Any],
    zone: ZoneInfo,
) -> None:
    current = apple_snapshot(reminder, zone)
    desired = google_snapshot(google_task)
    command = [str(remindctl), "edit", action.apple_id]

    if current["title"] != desired["title"]:
        command.extend(["--title", desired["title"]])
    if current["completed"] != desired["completed"]:
        command.append("--complete" if desired["completed"] else "--incomplete")
    if current["due_date"] != desired["due_date"]:
        if desired["due_date"] is None:
            command.extend(["--clear-due", "--clear-alarm"])
        elif current["all_day"] or not current["original_time"]:
            command.extend(["--due", desired["due_date"]])
        else:
            local_due = f"{desired['due_date']} {current['original_time']}"
            command.extend(["--due", local_due, "--alarm", local_due])

    if len(command) == 3:
        return
    command.extend(["--json", "--no-input"])
    subprocess.run(command, check=True, capture_output=True, text=True)


def write_current_state(
    state_path: Path,
    reminders: list[dict[str, Any]],
    google_tasks: list[dict[str, Any]],
    zone: ZoneInfo,
) -> None:
    google_by_apple_id, conflicts = index_bridge_tasks(google_tasks)
    reminder_by_id = {item.get("id"): item for item in reminders if item.get("id")}
    recurrence_rules = recurrence_catalog(reminders)
    mappings: dict[str, Any] = {}
    for apple_id, google_task in google_by_apple_id.items():
        reminder = reminder_by_id.get(apple_id)
        if not reminder or apple_id in conflicts:
            continue
        mappings[apple_id] = {
            "google_task_id": google_task["id"],
            "apple_snapshot": apple_snapshot(reminder, zone, recurrence_rules),
            "google_snapshot": google_snapshot(google_task),
            "series_id": recurrence_series_id(reminder, recurrence_rules),
            "last_sync": datetime.now(timezone.utc).isoformat(),
        }
    write_private_json(state_path, {"version": 3, "mappings": mappings})


def apply_plan(
    args: argparse.Namespace,
    service,
    actions: list[Action],
    reminder_by_id: dict[str, dict[str, Any]],
    desired_by_id: dict[str, dict[str, Any]],
    google_by_apple_id: dict[str, dict[str, Any]],
    zone: ZoneInfo,
) -> list[dict[str, Any]]:
    results = []
    for action in actions:
        if action.kind in {"create_google", "update_google"}:
            task = apply_google_action(
                service, args.tasklist_id, action, desired_by_id[action.apple_id]
            )
            results.append(
                {"kind": action.kind, "apple_id": action.apple_id, "google_task_id": task["id"]}
            )
        elif action.kind == "update_apple":
            if not args.remindctl:
                raise RuntimeError("Google-to-Apple writes require --remindctl, not --apple-json.")
            apply_apple_action(
                args.remindctl,
                action,
                reminder_by_id[action.apple_id],
                google_by_apple_id[action.apple_id],
                zone,
            )
            results.append(
                {"kind": action.kind, "apple_id": action.apple_id, "google_task_id": action.google_task_id}
            )

    refreshed_reminders = load_apple_reminders(args)
    refreshed_google = list_google_tasks(service, args.tasklist_id)
    write_current_state(args.state, refreshed_reminders, refreshed_google, zone)
    return results


def print_summary(actions: list[Action], mode: str, summary_only: bool = False) -> None:
    counts: dict[str, int] = {}
    for action in actions:
        counts[action.kind] = counts.get(action.kind, 0) + 1
    print(f"Mode: {mode}")
    print("Summary: " + ", ".join(f"{key}={value}" for key, value in sorted(counts.items())))
    for index, action in enumerate(actions, start=1):
        if summary_only and action.kind in {"unchanged", "skip"}:
            continue
        time_suffix = f" at {action.original_time}" if action.original_time else ""
        print(
            f"{index}. {action.kind.upper()} [{action.direction}]: "
            f"{action.title} (due={action.due_date or 'none'}{time_suffix}; {action.reason})"
        )


def main() -> int:
    args = parse_args()
    if args.apply and args.confirm != "APPLY":
        raise SystemExit("Refusing writes: use --apply --confirm APPLY.")
    zone = ZoneInfo(args.timezone)
    reminders = load_apple_reminders(args)
    state = load_state(args.state)
    credentials = load_google_credentials(args.credentials, args.token)
    service = build("tasks", "v1", credentials=credentials, cache_discovery=False)
    google_tasks = list_google_tasks(service, args.tasklist_id)
    google_by_apple_id, conflicts = index_bridge_tasks(google_tasks)
    actions, reminder_by_id, desired_by_id = build_plan(
        reminders,
        google_by_apple_id,
        conflicts,
        state,
        zone,
        args.direction,
    )

    plan = {
        "mode": "apply" if args.apply else "dry-run",
        "direction": args.direction,
        "tasklist_id": args.tasklist_id,
        "timezone": zone.key,
        "source_count": len(reminders),
        "managed_google_count": len(google_by_apple_id),
        "unmanaged_google_count": len(google_tasks) - len(google_by_apple_id),
        "actions": [asdict(action) for action in actions],
    }
    if args.plan_json:
        args.plan_json.parent.mkdir(parents=True, exist_ok=True)
        args.plan_json.write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding="utf-8")

    print_summary(actions, plan["mode"], args.summary_only)
    if args.apply:
        results = apply_plan(
            args,
            service,
            actions,
            reminder_by_id,
            desired_by_id,
            google_by_apple_id,
            zone,
        )
        print(json.dumps({"applied": results}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Interrupted; no further actions were applied.", file=sys.stderr)
        raise SystemExit(130)
