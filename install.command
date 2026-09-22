#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
INSTALL_DIR="${BRIDGE_INSTALL_DIR:-$HOME/Library/Application Support/AppleGoogleRemindersBridge}"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LABEL="${BRIDGE_SYNC_LABEL:-com.local.apple-google-reminders-bridge}"
DASHBOARD_LABEL="${BRIDGE_DASHBOARD_LABEL:-com.local.apple-google-reminders-dashboard}"
PLIST_PATH="$LAUNCH_DIR/$LABEL.plist"
DASHBOARD_PLIST_PATH="$LAUNCH_DIR/$DASHBOARD_LABEL.plist"

PYTHON_BIN="${BRIDGE_PYTHON:-$(command -v python3 || true)}"
REMINDCTL_BIN="${BRIDGE_REMINDCTL:-$(command -v remindctl || true)}"
CREDENTIALS_SOURCE="${BRIDGE_CREDENTIALS:-$SOURCE_DIR/credentials.json}"
TOKEN_SOURCE="${BRIDGE_TOKEN:-$SOURCE_DIR/token.json}"
STATE_SOURCE="${BRIDGE_STATE:-}"

if [[ -z "$PYTHON_BIN" ]] || ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "Python 3.10 ou superior é necessário. Defina BRIDGE_PYTHON com o caminho correto."
  exit 1
fi
if [[ -z "$REMINDCTL_BIN" || ! -x "$REMINDCTL_BIN" ]]; then
  echo "remindctl não encontrado. Instale-o ou defina BRIDGE_REMINDCTL."
  exit 1
fi
if [[ ! -f "$CREDENTIALS_SOURCE" || ! -f "$TOKEN_SOURCE" ]]; then
  echo "credentials.json e token.json são necessários."
  echo "Use BRIDGE_CREDENTIALS e BRIDGE_TOKEN para informar seus caminhos."
  exit 1
fi

echo "Instalando Apple Lembretes ↔ Google Tasks..."
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/secrets" "$INSTALL_DIR/runtime" "$LAUNCH_DIR"
chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/secrets" "$INSTALL_DIR/runtime"

install -m 700 "$SOURCE_DIR/bridge.py" "$INSTALL_DIR/bridge.py"
install -m 700 "$SOURCE_DIR/dashboard.py" "$INSTALL_DIR/dashboard.py"
install -m 700 "$SOURCE_DIR/run-sync.sh" "$INSTALL_DIR/run-sync.sh"
install -m 700 "$SOURCE_DIR/open-dashboard.command" "$INSTALL_DIR/open-dashboard.command"
install -m 600 "$SOURCE_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
install -m 700 "$REMINDCTL_BIN" "$INSTALL_DIR/bin/remindctl"
install -m 600 "$CREDENTIALS_SOURCE" "$INSTALL_DIR/secrets/credentials.json"
install -m 600 "$TOKEN_SOURCE" "$INSTALL_DIR/secrets/token.json"

if [[ -n "$STATE_SOURCE" && -f "$STATE_SOURCE" && ! -f "$INSTALL_DIR/runtime/state.json" ]]; then
  install -m 600 "$STATE_SOURCE" "$INSTALL_DIR/runtime/state.json"
fi

if [[ ! -x "$INSTALL_DIR/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$INSTALL_DIR/.venv"
fi
"$INSTALL_DIR/.venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$INSTALL_DIR/requirements.txt"

sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$SOURCE_DIR/launchd.plist.template" > "$PLIST_PATH"
sed \
  -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
  -e "s|__DASHBOARD_LABEL__|$DASHBOARD_LABEL|g" \
  -e "s|__SYNC_LABEL__|$LABEL|g" \
  -e "s|__SYNC_PLIST__|$PLIST_PATH|g" \
  "$SOURCE_DIR/dashboard.plist.template" > "$DASHBOARD_PLIST_PATH"
chmod 600 "$PLIST_PATH"
chmod 600 "$DASHBOARD_PLIST_PATH"
plutil -lint "$PLIST_PATH"
plutil -lint "$DASHBOARD_PLIST_PATH"

user_id=$(id -u)
launchctl bootout "gui/$user_id/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$user_id" "$PLIST_PATH"
launchctl enable "gui/$user_id/$LABEL"
launchctl kickstart -k "gui/$user_id/$LABEL"
launchctl bootout "gui/$user_id/$DASHBOARD_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$user_id" "$DASHBOARD_PLIST_PATH"
launchctl enable "gui/$user_id/$DASHBOARD_LABEL"
launchctl kickstart -k "gui/$user_id/$DASHBOARD_LABEL"

echo
echo "Instalação concluída. A sincronização rodará a cada 5 minutos."
echo "Painel: http://127.0.0.1:8765"
echo "Logs: $INSTALL_DIR/runtime/sync.log"
open -a Safari "http://127.0.0.1:8765"
echo
read "?Pressione Enter para fechar esta janela..."
