# code-247

24/7 cloud coding environment (VS Code in the browser) on cycling GitHub
Actions VMs. Controlled entirely from a phone via the GitHub mobile app and
any browser.

## How it works

`code-server.yml` boots a VM, restores the workspace from Release
`workspace-snapshot` (asset `ws-current.tar.gz`), starts code-server +
a cloudflared quick tunnel, and beacons the live URL to `status.txt`.
When idle 30+ min (or at the T+5h30 hard rail), it snapshots the workspace,
rotates the release assets, dispatches its successor, and exits. The watchdog
(`workflow_run` trigger) heals a broken chain in seconds.

## Phone control

- **Status:** open `status.txt` in the repo (or GitHub mobile) — live tunnel
  URL + milestones
- **Console:** push shell commands to `console-command.txt` (executed ~30s)
- **Handover:** create `handover.txt` in the repo (consumed once, triggers a
  graceful snapshot + VM swap)
- **Boot/kill:** GitHub mobile app → Actions → Code Server → Run workflow

## Secrets

| Name | Purpose |
|---|---|
| `GH_PAT` | dispatch + release rotation |
| `CODE_PASSWORD` | code-server login password |
