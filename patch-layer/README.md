# Quota publish-leg patch layer

## What this is

The seam-A publish leg: the quota plugin's `useMonitor` publishes each
polled monitor snapshot to the Desktop host through the feature-detected
`host.publishMonitorLive` door, so the sidebar's Open-now section shows
the same live rows the Live tab renders.

```js
host.publishMonitorLive?.({
  profile: scope.profile,
  live: snapshot.live,
  fetchedAt: snapshot.generated_at,
})
```

## Why a layer, not just a PR

The source PR is rarf/hermes-quota-plugin **#118**
(`musti/publish-monitor-live-t_f5fd2ab0` on the ycetindil fork). Until it
merges upstream *and* a release carrying it is installed, every plugin
update (install.sh copies a fresh `desktop/plugin.js` over the deployed
one) would silently drop the publish leg. This layer re-applies the change
to whatever version is deployed, until that day.

The deployed line (3.0.7) also carries house-only fixes that upstream
master does not (the `--compact` transport fix, display names), so the
layer's patch is anchored on the deployed 3.0.7 text, not on master.

## Files

- `quota-publish-live.patch` — unified diff of the change against the
  deployed 3.0.7 `desktop/plugin.js` (md5 `f514762893d8f08254bf835802b804f6`,
  12062 lines). Applies cleanly with `patch -p1` and produces output
  byte-identical to `apply.sh`'s.
- `apply.sh` — the apply / re-apply mechanism. Self-contained
  (anchor-based insertion, no network, no repo needed). Idempotent: a file
  that already carries the publish call is left untouched (SKIP). On an
  anchor mismatch it fails loudly and leaves the file untouched. Backups
  go to `--backup-dir`, which must be OUTSIDE any plugin-scanned tree
  (never inside `desktop-plugins/` or `plugins/` — a stray directory
  there is picked up as a plugin and fails the load with a duplicate id).
- `README.md` — this file.

## Install inventory (7 installs, all 3.0.7, byte-identical before the layer)

| # | Install | Path |
|---|---------|------|
| 1 | ai-control repo / default home | `/srv/ai-control/runtime/plugins/quota/desktop/plugin.js` |
| 2 | container profile agora-leader | `/opt/data/profiles/agora-leader/plugins/quota/desktop/plugin.js` (inside `ai-control-agent-runtime-1`) |
| 3 | container profile agora-researcher | `/opt/data/profiles/agora-researcher/plugins/quota/desktop/plugin.js` (inside `ai-control-agent-runtime-1`) |
| 4 | container profile agora-writer | `/opt/data/profiles/agora-writer/plugins/quota/desktop/plugin.js` (inside `ai-control-agent-runtime-1`) |
| 5 | container profile hurmuz | `/opt/data/profiles/hurmuz/plugins/quota/desktop/plugin.js` (inside `ai-control-agent-runtime-1`) |
| 6 | container profile librarian | `/opt/data/profiles/librarian/plugins/quota/desktop/plugin.js` (inside `ai-control-agent-runtime-1`) |
| 7 | Framework | `~/.hermes/desktop-plugins/quota/plugin.js` (host `framework`, user `ycetindil`) |

Note: the `musti` profile has no quota install (known since card
t_0dba6ffd, c.16998) — there is nothing to patch there. If a quota install
appears under a new profile, run `apply.sh` against it; `install.sh`
enumerates profiles the same way.

## How to (re-)apply

From a checkout of this branch (or any copy of `apply.sh`):

```bash
# 1 — repo install (ai-control host)
./apply.sh --backup-dir /opt/data/quota-publish-layer-backups \
  /srv/ai-control/runtime/plugins/quota/desktop/plugin.js

# 2–6 — container profile installs (inside ai-control-agent-runtime-1)
docker exec ai-control-agent-runtime-1 bash -s -- \
  --backup-dir /opt/data/quota-publish-layer-backups \
  /opt/data/profiles/agora-leader/plugins/quota/desktop/plugin.js \
  /opt/data/profiles/agora-researcher/plugins/quota/desktop/plugin.js \
  /opt/data/profiles/agora-writer/plugins/quota/desktop/plugin.js \
  /opt/data/profiles/hurmuz/plugins/quota/desktop/plugin.js \
  /opt/data/profiles/librarian/plugins/quota/desktop/plugin.js \
  < apply.sh

# 7 — Framework install #7
ssh framework 'bash -s -- --backup-dir ~/.hermes/quota-publish-layer-backups \
  ~/.hermes/desktop-plugins/quota/plugin.js' < apply.sh
```

After every plugin update, re-run the three commands.
(`bash -s`, not `sh -s`: the container's `sh` is dash, which rejects
the script's arrays — found first-hand at first application.) Expected output is
`PATCHED` for a fresh install (or `SKIP` when the install already carries
the call); any `FAILED` line means that install was left untouched — do
not proceed past it, read the reason, and fix the anchor (usually the
deployed version moved and the patch needs re-anchoring).

The Desktop app reads the new file at its next launch; no restart is part
of this layer (a live restart stays the owner's hand-step).

## Verification

After applying, every install must show exactly one publish call:

```bash
grep -c 'host\.publishMonitorLive?\.(' <each plugin.js>   # -> 1
node --check <each plugin.js>                              # -> clean
```

The patched bytes were additionally proven through the plugin's own
offline monitor harness (live view and pane, synthetic snapshot): exactly
one publish per render, payload `{ profile, live, fetchedAt }` identical
to the snapshot — see PR #118.

## Retirement condition

Retire this layer when BOTH hold:

1. Source PR #118 is merged upstream, and
2. a deployed release carrying the change natively is installed on all 7
   installs — verified by `apply.sh` reporting `SKIP` on every install
   (the call is already there, from the release itself).

Then: delete this branch's layer files from the next update's path, remove
the backup dirs only after the native installs have run a full poll cycle,
and record the retirement on kanban card t_f5fd2ab0. Until then the layer
stays live: every plugin update re-runs the apply commands above.

## Application log

- 2026-11-26 (card t_f5fd2ab0, run watchwork-t_f5fd2ab0-202611262128):
  applied to all 7 installs; read-backs in the run record
  (`hidden_files/watchwork-t_f5fd2ab0-202611262128/RUN-RECORD.md`).
