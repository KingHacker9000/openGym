#!/usr/bin/env bash
# Update a source-built openGym deployment from this fork's tested main branch.
# Designed for /opt/stacks/opengym on the Raspberry Pi. Persistent ./data, ./media and .env
# are never removed. If the new containers fail health checks, the source tree and containers
# are rebuilt from the previous commit automatically.
set -euo pipefail

STACK_DIR="${OPENGYM_STACK_DIR:-/opt/stacks/opengym}"
REMOTE="${OPENGYM_REMOTE:-origin}"
BRANCH="${OPENGYM_BRANCH:-main}"
LOCK_FILE="${OPENGYM_UPDATE_LOCK:-/run/lock/opengym-auto-update.lock}"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "openGym update already running; exiting."
  exit 0
fi

cd "$STACK_DIR"

if [[ ! -d .git ]]; then
  echo "ERROR: $STACK_DIR is not a git checkout; refusing automatic update." >&2
  exit 1
fi
if [[ ! -f .env ]]; then
  echo "ERROR: $STACK_DIR/.env is missing; refusing automatic update." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "ERROR: tracked files have local changes; refusing to overwrite them." >&2
  git status --short
  exit 1
fi

old_sha="$(git rev-parse HEAD)"
git fetch --prune "$REMOTE" "$BRANCH"
new_sha="$(git rev-parse "$REMOTE/$BRANCH")"

if [[ "$old_sha" == "$new_sha" ]]; then
  echo "openGym already current at ${old_sha:0:12}."
  exit 0
fi

# The live checkout must only move forward along main. A force-push or unexpected divergent
# history stops here instead of making the deployment guess which history to trust.
if ! git merge-base --is-ancestor "$old_sha" "$new_sha"; then
  echo "ERROR: $REMOTE/$BRANCH is not a fast-forward from the deployed commit; refusing update." >&2
  exit 1
fi

echo "Updating openGym ${old_sha:0:12} -> ${new_sha:0:12}"

git merge --ff-only "$REMOTE/$BRANCH"
mkdir -p data/codex media/img media/gif

rollback() {
  local rc=$?
  trap - ERR
  echo "Update failed; rolling source and containers back to ${old_sha:0:12}." >&2
  git reset --hard "$old_sha"
  sudo docker compose up -d --build --remove-orphans
  exit "$rc"
}
trap rollback ERR

# Build from the checked-in source rather than pulling the old upstream GHCR images.
sudo docker compose up -d --build --remove-orphans

# Wait for the API's Docker HEALTHCHECK. This checks the Node server and the persistent-data mount.
api_id="$(sudo docker compose ps -q api)"
web_id="$(sudo docker compose ps -q web)"
[[ -n "$api_id" && -n "$web_id" ]]

for _ in $(seq 1 36); do
  api_state="$(sudo docker inspect -f '{{.State.Status}}' "$api_id")"
  api_health="$(sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$api_id")"
  web_state="$(sudo docker inspect -f '{{.State.Status}}' "$web_id")"

  if [[ "$api_state" == "running" && "$api_health" == "healthy" && "$web_state" == "running" ]]; then
    # Verify nginx -> API proxying from inside the web container as well.
    nginx_port="${NGINX_PORT:-80}"
    if sudo docker compose exec -T web sh -c "wget -qO- http://127.0.0.1:${nginx_port}/api/health >/dev/null"; then
      trap - ERR
      echo "openGym update healthy at ${new_sha:0:12}."
      exit 0
    fi
  fi

  if [[ "$api_state" == "exited" || "$web_state" == "exited" || "$api_health" == "unhealthy" ]]; then
    echo "Container failed during rollout: api=$api_state/$api_health web=$web_state" >&2
    false
  fi
  sleep 5
done

echo "Timed out waiting for the new openGym deployment to become healthy." >&2
false
