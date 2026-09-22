#!/bin/zsh
set -u

INSTALL_DIR="${0:A:h}"
RUNTIME_DIR="$INSTALL_DIR/runtime"
LOCK_DIR="$RUNTIME_DIR/sync.lock"

mkdir -p "$RUNTIME_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date -u +%FT%TZ) skipped: another sync is running"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

echo "$(date -u +%FT%TZ) sync started"
PYTHONWARNINGS=ignore "$INSTALL_DIR/.venv/bin/python" \
  "$INSTALL_DIR/bridge.py" \
  --remindctl "$INSTALL_DIR/bin/remindctl" \
  --credentials "$INSTALL_DIR/secrets/credentials.json" \
  --token "$INSTALL_DIR/secrets/token.json" \
  --state "$RUNTIME_DIR/state.json" \
  --tasklist-id @default \
  --timezone America/Sao_Paulo \
  --direction bidirectional \
  --plan-json "$RUNTIME_DIR/latest-plan.json" \
  --summary-only \
  --apply --confirm APPLY
sync_exit=$?
echo "$(date -u +%FT%TZ) sync finished exit=$sync_exit"
exit "$sync_exit"
