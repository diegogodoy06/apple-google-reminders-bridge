#!/usr/bin/env python3
"""Local status and control panel for the reminders bridge.

The server binds only to loopback. Mutating requests require a per-install token
sent in a custom header, preventing ordinary cross-site form submissions.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_SYNC_LABEL = "com.local.apple-google-reminders-bridge"
START_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) sync started$")
FINISH_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) sync finished exit=(\d+)$"
)
ACTION_RE = re.compile(
    r"^\d+\. ([A-Z_]+) \[([^]]+)\]: (.*) \(due=(.*); ([^)]+)\)$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local dashboard for the reminders bridge.")
    parser.add_argument("--host", default=os.environ.get("BRIDGE_DASHBOARD_HOST", DEFAULT_HOST))
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("BRIDGE_DASHBOARD_PORT", DEFAULT_PORT))
    )
    parser.add_argument(
        "--install-dir",
        type=Path,
        default=Path(os.environ.get("BRIDGE_INSTALL_DIR", Path(__file__).resolve().parent)),
    )
    parser.add_argument(
        "--sync-label", default=os.environ.get("BRIDGE_SYNC_LABEL", DEFAULT_SYNC_LABEL)
    )
    parser.add_argument("--sync-plist", type=Path)
    return parser.parse_args()


def parse_utc(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def iso_or_none(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_summary(value: str) -> dict[str, int]:
    result: dict[str, int] = {}
    for part in value.split(","):
        key, separator, count = part.strip().partition("=")
        if separator and count.isdigit():
            result[key] = int(count)
    return result


def parse_history(log_path: Path, limit: int = 40) -> list[dict[str, Any]]:
    if not log_path.exists():
        return []
    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    events: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None

    for line in lines:
        start = START_RE.match(line)
        if start:
            if current:
                events.append(current)
            current = {
                "started_at": start.group(1),
                "finished_at": None,
                "exit_code": None,
                "summary": {},
                "actions": [],
            }
            continue
        if current is None:
            continue
        if line.startswith("Summary: "):
            current["summary"] = parse_summary(line.removeprefix("Summary: "))
            continue
        action = ACTION_RE.match(line)
        if action:
            current["actions"].append(
                {
                    "kind": action.group(1).lower(),
                    "direction": action.group(2),
                    "title": action.group(3),
                    "due": action.group(4),
                    "reason": action.group(5),
                }
            )
            continue
        finish = FINISH_RE.match(line)
        if finish:
            current["finished_at"] = finish.group(1)
            current["exit_code"] = int(finish.group(2))
            events.append(current)
            current = None

    if current:
        events.append(current)
    return list(reversed(events[-limit:]))


def safe_json(path: Path, fallback: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return fallback


def tail_text(path: Path, line_count: int = 30) -> str:
    if not path.exists():
        return ""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(lines[-line_count:])


class DashboardApp:
    def __init__(
        self,
        install_dir: Path,
        sync_label: str,
        sync_plist: Path,
        host: str,
        port: int,
    ) -> None:
        self.install_dir = install_dir.resolve()
        self.runtime_dir = self.install_dir / "runtime"
        self.sync_label = sync_label
        self.sync_plist = sync_plist.expanduser().resolve()
        self.host = host
        self.port = port
        self.user_id = os.getuid()
        self.domain = f"gui/{self.user_id}"
        self.service_target = f"{self.domain}/{self.sync_label}"
        self.pause_marker = self.runtime_dir / "paused"
        self.token = self._load_token()

    def _load_token(self) -> str:
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        token_path = self.runtime_dir / "dashboard-token"
        if token_path.exists():
            return token_path.read_text(encoding="utf-8").strip()
        token = secrets.token_urlsafe(32)
        token_path.write_text(token, encoding="utf-8")
        os.chmod(token_path, 0o600)
        return token

    def launchctl(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/launchctl", *arguments],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

    def is_loaded(self) -> bool:
        return self.launchctl("print", self.service_target).returncode == 0

    def history(self) -> list[dict[str, Any]]:
        return parse_history(self.runtime_dir / "sync.log")

    def status(self) -> dict[str, Any]:
        history = self.history()
        last = history[0] if history else None
        loaded = self.is_loaded()
        paused = self.pause_marker.exists()
        syncing = bool(last and last["finished_at"] is None)
        if paused:
            state = "paused"
        elif syncing:
            state = "syncing"
        elif loaded:
            state = "running"
        else:
            state = "attention"

        state_data = safe_json(self.runtime_dir / "state.json", {})
        mapping_count = len(state_data.get("mappings", {}))
        last_started = parse_utc(last["started_at"]) if last else None
        next_run = last_started + timedelta(minutes=5) if loaded and last_started else None
        today = datetime.now(timezone.utc) - timedelta(hours=24)
        recent = [item for item in history if (parse_utc(item["started_at"]) or today) >= today]
        successful = sum(item.get("exit_code") == 0 for item in recent)
        changes = sum(
            sum(
                count
                for key, count in item.get("summary", {}).items()
                if key not in {"unchanged", "skip"}
            )
            for item in recent
        )
        error_text = tail_text(self.runtime_dir / "sync-error.log")
        return {
            "state": state,
            "loaded": loaded,
            "paused": paused,
            "syncing": syncing,
            "label": self.sync_label,
            "last_run": last,
            "next_run": iso_or_none(next_run),
            "mapping_count": mapping_count,
            "runs_24h": len(recent),
            "successful_24h": successful,
            "changes_24h": changes,
            "has_errors": bool(error_text.strip()),
            "error_tail": error_text,
            "history": history,
        }

    def control(self, action: str) -> dict[str, Any]:
        if action == "pause":
            self.pause_marker.write_text(datetime.now(timezone.utc).isoformat(), encoding="utf-8")
            result = self.launchctl("bootout", self.service_target)
            if result.returncode != 0 and self.is_loaded():
                raise RuntimeError(result.stderr.strip() or "Não foi possível pausar o serviço.")
            return {"message": "Sincronização pausada."}

        if action == "resume":
            if not self.sync_plist.exists():
                raise RuntimeError(f"Arquivo do serviço não encontrado: {self.sync_plist}")
            self.launchctl("enable", self.service_target)
            result = self.launchctl("bootstrap", self.domain, str(self.sync_plist))
            if result.returncode != 0 and not self.is_loaded():
                raise RuntimeError(result.stderr.strip() or "Não foi possível retomar o serviço.")
            self.pause_marker.unlink(missing_ok=True)
            kick = self.launchctl("kickstart", "-k", self.service_target)
            if kick.returncode != 0:
                raise RuntimeError(kick.stderr.strip() or "O serviço foi carregado, mas não iniciou.")
            return {"message": "Sincronização retomada."}

        if action == "sync":
            if self.pause_marker.exists():
                raise RuntimeError("Retome a sincronização antes de executar agora.")
            if not self.is_loaded():
                raise RuntimeError("O serviço não está carregado.")
            result = self.launchctl("kickstart", "-k", self.service_target)
            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip() or "Não foi possível iniciar a sincronização.")
            return {"message": "Sincronização iniciada."}

        raise ValueError("Ação desconhecida.")

    def html(self) -> str:
        token = json.dumps(self.token)
        return DASHBOARD_HTML.replace("__CONTROL_TOKEN__", token)


def make_handler(app: DashboardApp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "RemindersBridgeDashboard/1.0"

        def log_message(self, format_string: str, *arguments: Any) -> None:
            print(f"{self.address_string()} - {format_string % arguments}")

        def security_headers(self) -> None:
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
                "connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'",
            )

        def send_json(self, value: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
            body = json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.security_headers()
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            path = urlparse(self.path).path
            if path == "/":
                body = app.html().encode("utf-8")
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.security_headers()
                self.end_headers()
                self.wfile.write(body)
                return
            if path == "/api/status":
                self.send_json(app.status())
                return
            self.send_json({"error": "Não encontrado."}, HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:  # noqa: N802
            if urlparse(self.path).path != "/api/control":
                self.send_json({"error": "Não encontrado."}, HTTPStatus.NOT_FOUND)
                return
            if self.headers.get("X-Dashboard-Token") != app.token:
                self.send_json({"error": "Comando não autorizado."}, HTTPStatus.FORBIDDEN)
                return
            try:
                content_length = min(int(self.headers.get("Content-Length", "0")), 4096)
                payload = json.loads(self.rfile.read(content_length) or b"{}")
                result = app.control(str(payload.get("action", "")))
                self.send_json({**result, "status": app.status()})
            except (ValueError, RuntimeError, json.JSONDecodeError) as error:
                self.send_json({"error": str(error)}, HTTPStatus.BAD_REQUEST)

    return Handler


DASHBOARD_HTML = r'''<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Ponte de lembretes</title>
  <style>
    :root {
      color-scheme: light;
      --canvas: #edf1f4;
      --surface: #ffffff;
      --ink: #18212b;
      --muted: #65717d;
      --rule: #d7dde2;
      --green: #13795b;
      --green-soft: #dff2e9;
      --amber: #9a6700;
      --amber-soft: #fff0c2;
      --red: #a83a3a;
      --red-soft: #f8dddd;
      --shadow: 0 18px 60px rgba(45, 61, 72, .12);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100dvh; background: var(--canvas); color: var(--ink); }
    button { font: inherit; }
    .shell { width: min(1040px, calc(100% - 32px)); margin: 0 auto; padding: 34px 0 60px; }
    .topbar { display: flex; align-items: flex-start; justify-content: space-between; gap: 24px; margin-bottom: 22px; }
    .identity { display: flex; align-items: center; gap: 14px; }
    .mark { width: 44px; height: 44px; display: grid; place-items: center; border-radius: 13px; background: var(--ink); color: white; font-weight: 760; letter-spacing: -.06em; box-shadow: 0 8px 20px rgba(24, 33, 43, .18); }
    h1 { margin: 1px 0 4px; font-size: 21px; letter-spacing: -.025em; }
    .subtitle { margin: 0; color: var(--muted); font-size: 13px; }
    .actions { display: flex; gap: 9px; flex-wrap: wrap; justify-content: flex-end; }
    .button { border: 1px solid var(--rule); border-radius: 10px; padding: 9px 14px; background: var(--surface); color: var(--ink); cursor: pointer; font-weight: 620; box-shadow: 0 1px 1px rgba(24, 33, 43, .05); transition: background .12s ease, transform .12s ease; }
    .button:hover { background: #f8fafb; }
    .button:active { transform: translateY(1px); }
    .button:focus-visible { outline: 3px solid rgba(19, 121, 91, .28); outline-offset: 2px; }
    .button.primary { background: var(--ink); border-color: var(--ink); color: white; }
    .button.primary:hover { background: #2a3541; }
    .button.danger { color: var(--red); }
    .button[disabled] { opacity: .48; cursor: not-allowed; transform: none; }
    .panel { background: var(--surface); border: 1px solid rgba(119, 133, 145, .28); border-radius: 18px; box-shadow: var(--shadow); overflow: hidden; }
    .status-row { display: grid; grid-template-columns: 1.35fr repeat(3, 1fr); min-height: 150px; }
    .status-main { padding: 28px; border-right: 1px solid var(--rule); display: flex; flex-direction: column; justify-content: space-between; }
    .status-label { display: flex; align-items: center; gap: 9px; font-size: 14px; font-weight: 680; }
    .dot { width: 10px; height: 10px; border-radius: 50%; background: var(--green); box-shadow: 0 0 0 5px var(--green-soft); }
    .status-main[data-state="syncing"] .dot { animation: pulse 1.25s ease-in-out infinite; }
    .status-main[data-state="paused"] .dot { background: var(--amber); box-shadow: 0 0 0 5px var(--amber-soft); }
    .status-main[data-state="attention"] .dot { background: var(--red); box-shadow: 0 0 0 5px var(--red-soft); }
    .status-copy { margin: 18px 0 0; max-width: 36ch; color: var(--muted); font-size: 14px; line-height: 1.5; }
    .metric { padding: 28px 22px; border-right: 1px solid var(--rule); }
    .metric:last-child { border-right: 0; }
    .metric dt { color: var(--muted); font-size: 12px; margin-bottom: 12px; }
    .metric dd { margin: 0; font-size: 23px; font-weight: 720; letter-spacing: -.035em; }
    .metric small { display: block; color: var(--muted); margin-top: 7px; font-size: 12px; }
    .section { border-top: 1px solid var(--rule); }
    .section-head { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; padding: 22px 28px 14px; }
    h2 { margin: 0; font-size: 15px; letter-spacing: -.01em; }
    .section-note { color: var(--muted); font-size: 12px; }
    .timeline { padding: 0 28px 24px; }
    .event { display: grid; grid-template-columns: 118px 20px minmax(0, 1fr) auto; gap: 12px; align-items: start; padding: 14px 0; border-top: 1px solid #e8ecef; }
    .event:first-child { border-top: 0; }
    .event-time { color: var(--muted); font-size: 12px; padding-top: 2px; font-variant-numeric: tabular-nums; }
    .event-node { position: relative; width: 8px; height: 8px; margin-top: 5px; border-radius: 50%; background: var(--green); }
    .event.failed .event-node { background: var(--red); }
    .event.running .event-node { background: var(--amber); }
    .event-title { font-size: 13px; font-weight: 650; }
    .event-detail { color: var(--muted); font-size: 12px; margin-top: 4px; line-height: 1.45; }
    .event-count { color: var(--muted); font-size: 12px; white-space: nowrap; }
    .empty { padding: 34px 0; color: var(--muted); font-size: 13px; }
    details.errors { margin: 0 28px 26px; border-top: 1px solid var(--rule); padding-top: 16px; }
    details summary { cursor: pointer; font-size: 13px; font-weight: 650; }
    pre { overflow: auto; padding: 14px; background: #f5f7f8; border-radius: 10px; color: #3c4853; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; }
    .toast { position: fixed; right: 22px; bottom: 22px; max-width: min(360px, calc(100% - 44px)); padding: 12px 15px; border-radius: 11px; background: var(--ink); color: white; font-size: 13px; box-shadow: 0 12px 35px rgba(24, 33, 43, .28); opacity: 0; transform: translateY(8px); pointer-events: none; transition: .18s ease; }
    .toast.visible { opacity: 1; transform: translateY(0); }
    .toast.error { background: var(--red); }
    @keyframes pulse { 50% { transform: scale(.72); opacity: .55; } }
    @media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation: none !important; transition: none !important; } }
    @media (max-width: 780px) {
      .shell { width: min(100% - 20px, 620px); padding-top: 20px; }
      .topbar { display: block; }
      .actions { justify-content: flex-start; margin-top: 18px; }
      .status-row { grid-template-columns: 1fr 1fr; }
      .status-main { grid-column: 1 / -1; border-right: 0; border-bottom: 1px solid var(--rule); }
      .metric:nth-of-type(2) { border-right: 0; }
      .metric:last-child { grid-column: 1 / -1; border-top: 1px solid var(--rule); }
      .event { grid-template-columns: 86px 12px minmax(0, 1fr); }
      .event-count { grid-column: 3; }
    }
  </style>
</head>
<body>
  <main class="shell">
    <header class="topbar">
      <div class="identity">
        <div class="mark" aria-hidden="true">↔</div>
        <div><h1>Ponte de lembretes</h1><p class="subtitle">Apple Lembretes e Google Tasks</p></div>
      </div>
      <div class="actions">
        <button class="button primary" id="syncButton" type="button">Sincronizar agora</button>
        <button class="button danger" id="pauseButton" type="button">Pausar</button>
      </div>
    </header>

    <section class="panel" aria-live="polite">
      <div class="status-row">
        <div class="status-main" id="statusMain" data-state="loading">
          <div class="status-label"><span class="dot"></span><span id="statusText">Verificando…</span></div>
          <p class="status-copy" id="statusCopy">Lendo o estado do serviço local.</p>
        </div>
        <dl class="metric"><dt>Última execução</dt><dd id="lastRun">—</dd><small id="lastRunDetail">—</small></dl>
        <dl class="metric"><dt>Próxima execução</dt><dd id="nextRun">—</dd><small>A cada 5 minutos</small></dl>
        <dl class="metric"><dt>Tarefas ligadas</dt><dd id="mappingCount">—</dd><small id="runsDetail">—</small></dl>
      </div>

      <div class="section">
        <div class="section-head"><h2>Histórico recente</h2><span class="section-note" id="historyNote">Atualiza automaticamente</span></div>
        <div class="timeline" id="timeline"><div class="empty">Carregando histórico…</div></div>
        <details class="errors" id="errorsPanel" hidden><summary>Ver mensagens de erro</summary><pre id="errorText"></pre></details>
      </div>
    </section>
  </main>
  <div class="toast" id="toast" role="status"></div>
  <script>
    const controlToken = __CONTROL_TOKEN__;
    const $ = (id) => document.getElementById(id);
    const stateLabels = {
      running: ['Em funcionamento', 'O serviço está ativo e verifica alterações automaticamente.'],
      syncing: ['Sincronizando agora', 'Apple Lembretes e Google Tasks estão sendo comparados.'],
      paused: ['Sincronização pausada', 'O painel continua disponível. Nenhuma tarefa será alterada até você retomar.'],
      attention: ['Precisa de atenção', 'O serviço não está carregado. Veja as mensagens de erro ou tente retomar.']
    };
    const actionLabels = {
      create_google: 'Criada no Google', update_google: 'Atualizada no Google',
      update_apple: 'Atualizada no Apple', conflict: 'Conflito detectado'
    };
    const reasonLabels = {
      'new-recurrence-occurrence': 'nova ocorrência recorrente', 'apple-changed': 'alteração no Apple',
      'google-changed': 'alteração no Google', 'not-yet-synced': 'nova tarefa',
      'bridge-metadata-upgrade': 'atualização interna'
    };

    function localDate(value) {
      if (!value) return null;
      return new Date(value).toLocaleString('pt-BR', {day:'2-digit', month:'short', hour:'2-digit', minute:'2-digit'});
    }
    function localTime(value) {
      if (!value) return '—';
      return new Date(value).toLocaleTimeString('pt-BR', {hour:'2-digit', minute:'2-digit'});
    }
    function escapeHtml(value) {
      return String(value).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
    }
    function changedCount(summary) {
      return Object.entries(summary || {}).filter(([key]) => !['skip','unchanged'].includes(key)).reduce((sum, [, count]) => sum + count, 0);
    }
    function renderHistory(items) {
      if (!items.length) { $('timeline').innerHTML = '<div class="empty">O histórico aparecerá depois da primeira execução.</div>'; return; }
      $('timeline').innerHTML = items.slice(0, 12).map(item => {
        const running = !item.finished_at;
        const failed = item.exit_code !== null && item.exit_code !== 0;
        const count = changedCount(item.summary);
        const details = item.actions.slice(0, 3).map(action => `${actionLabels[action.kind] || action.kind}: ${escapeHtml(action.title)}`).join('<br>');
        const quiet = !running && !failed && count === 0;
        const title = running ? 'Sincronização em andamento' : failed ? 'Execução com erro' : quiet ? 'Tudo sincronizado' : 'Alterações sincronizadas';
        const detail = details || (quiet ? 'Nenhuma diferença encontrada.' : failed ? 'A execução não foi concluída.' : 'Processamento concluído.');
        return `<article class="event ${failed ? 'failed' : running ? 'running' : ''}">
          <time class="event-time">${localDate(item.started_at)}</time><span class="event-node"></span>
          <div><div class="event-title">${title}</div><div class="event-detail">${detail}</div></div>
          <div class="event-count">${running ? 'agora' : count ? `${count} alteração${count > 1 ? 'ões' : ''}` : 'sem alterações'}</div>
        </article>`;
      }).join('');
    }
    function render(data) {
      const label = stateLabels[data.state] || stateLabels.attention;
      $('statusMain').dataset.state = data.state;
      $('statusText').textContent = label[0]; $('statusCopy').textContent = label[1];
      $('lastRun').textContent = data.last_run ? localTime(data.last_run.started_at) : '—';
      $('lastRunDetail').textContent = data.last_run ? localDate(data.last_run.started_at) : 'Nenhuma execução';
      $('nextRun').textContent = data.paused ? 'Pausada' : localTime(data.next_run);
      $('mappingCount').textContent = data.mapping_count;
      $('runsDetail').textContent = `${data.successful_24h}/${data.runs_24h} execuções concluídas em 24h`;
      $('pauseButton').textContent = data.paused ? 'Retomar' : 'Pausar';
      $('pauseButton').classList.toggle('danger', !data.paused);
      $('syncButton').disabled = data.paused || data.syncing || !data.loaded;
      $('pauseButton').disabled = data.syncing;
      renderHistory(data.history || []);
      $('errorsPanel').hidden = !data.has_errors;
      $('errorText').textContent = data.error_tail || '';
      $('historyNote').textContent = `${data.changes_24h} alterações nas últimas 24h`;
    }
    function notify(message, error=false) {
      const toast = $('toast'); toast.textContent = message; toast.className = `toast visible${error ? ' error' : ''}`;
      clearTimeout(window.toastTimer); window.toastTimer = setTimeout(() => toast.className = 'toast', 3200);
    }
    async function refresh() {
      try { const response = await fetch('/api/status', {cache:'no-store'}); render(await response.json()); }
      catch { notify('Não foi possível atualizar o painel.', true); }
    }
    async function control(action) {
      for (const button of document.querySelectorAll('button')) button.disabled = true;
      try {
        const response = await fetch('/api/control', {method:'POST', headers:{'Content-Type':'application/json','X-Dashboard-Token':controlToken}, body:JSON.stringify({action})});
        const result = await response.json();
        if (!response.ok) throw new Error(result.error || 'Comando não concluído.');
        notify(result.message); render(result.status); setTimeout(refresh, 1800);
      } catch (error) { notify(error.message, true); await refresh(); }
    }
    $('syncButton').addEventListener('click', () => control('sync'));
    $('pauseButton').addEventListener('click', () => {
      const paused = $('statusMain').dataset.state === 'paused';
      if (paused || confirm('Pausar a sincronização automática? O painel continuará funcionando.')) control(paused ? 'resume' : 'pause');
    });
    refresh(); setInterval(refresh, 10000);
  </script>
</body>
</html>'''


def main() -> int:
    args = parse_args()
    if args.host not in {"127.0.0.1", "::1", "localhost"}:
        raise SystemExit("Refusing to expose the dashboard outside this Mac.")
    sync_plist = args.sync_plist or Path.home() / "Library" / "LaunchAgents" / f"{args.sync_label}.plist"
    app = DashboardApp(args.install_dir, args.sync_label, sync_plist, args.host, args.port)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(app))
    print(f"Dashboard running at http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
