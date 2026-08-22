# Pi deployment and safe updates

This fork is intended to be source-built on the Raspberry Pi at `/opt/stacks/opengym`.
Persistent state remains in `.env`, `data/`, and `media/`.

## Update path

Upstream does not write directly to this fork's `main` branch.

1. `.github/workflows/sync-upstream.yml` fetches `ramananbuilds/openGym`, the GitHub mirror of the canonical Gitea project.
2. It merges the mirror into `automation/upstream-sync` and opens/updates a pull request.
3. `Upstream Gate` runs frontend, API/AI-Coach, MCP, generated-library and Docker-build checks with read-only permissions.
4. Only a successful gate allows `Merge upstream after gate` to merge the candidate into `main`.
5. The Pi timer fetches this fork's `main`, fast-forwards only, rebuilds from source, and probes both the API and nginx-to-API path.
6. A failed rollout resets to the previous commit and rebuilds the previous containers automatically.

A merge conflict, failed CI job, force-pushed/divergent `main`, dirty tracked Pi checkout, failed container startup, or failed health probe therefore stops the update rather than replacing the working deployment.

## One-time Pi timer installation

After the repository is checked out at `/opt/stacks/opengym` and the stack is working:

```bash
sudo cp /opt/stacks/opengym/deploy/systemd/opengym-auto-update.service /etc/systemd/system/
sudo cp /opt/stacks/opengym/deploy/systemd/opengym-auto-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now opengym-auto-update.timer
```

Check it with:

```bash
systemctl status opengym-auto-update.timer --no-pager
sudo systemctl start opengym-auto-update.service
sudo journalctl -u opengym-auto-update.service -n 100 --no-pager
```

The timer checks roughly every two hours (with a small randomized delay). If `main` has not changed it exits without rebuilding anything.

## AI Coach / Codex state

Codex uses a dedicated bind mount:

```text
./data/codex  ->  /codex
```

The API container installs its own pinned Codex CLI. Do not mount a host `~/.codex` directory into openGym. Treat `data/codex/auth.json` as a refreshable credential and protect backups accordingly.
