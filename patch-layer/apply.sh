#!/usr/bin/env bash
# Quota publish-leg patch layer — apply / re-apply.
#
# Applies the seam-A publish leg (useMonitor publishes each polled monitor
# snapshot through the feature-detected host.publishMonitorLive door) to a
# deployed quota plugin.js that does not carry it yet. Idempotent: a file
# that already carries the publish call is left untouched (SKIP), which is
# also how the layer retires itself once an upstream release carries the
# change natively — see patch-layer/README.md.
#
# Source PR: rarf/hermes-quota-plugin PR #118 (branch
# musti/publish-monitor-live-t_f5fd2ab0 on the ycetindil fork). The change
# applied here is byte-identical in logic to that PR; only the anchor
# differs (deployed 3.0.7's useMonitor carries house-only fields the
# upstream master does not).
#
# Usage:
#   apply.sh --backup-dir DIR <plugin.js> [<plugin.js> ...]
#
# Behaviour per file (nothing is silently overwritten):
#   - already carries `host.publishMonitorLive`  -> SKIP, untouched.
#   - anchor (the two lines below) missing or ambiguous -> FAILED, untouched.
#   - otherwise: backup first, insert the block, verify by read-back
#     (exactly one publish call; the inserted block reads back identical
#     to the expected text; `node --check` when node is available).
# Exit status is 0 only when every file ended PATCHED or SKIP.
#
# Backups go to --backup-dir, which must be OUTSIDE any plugin-scanned
# tree: never inside desktop-plugins/ or plugins/ (a stray directory
# there is picked up as a plugin and fails the load with a duplicate id).
set -euo pipefail

BACKUP_DIR=""
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    --backup-dir=*) BACKUP_DIR="${1#--backup-dir=}"; shift ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0 ;;
    --) shift; FILES+=("$@"); break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done
[ -n "$BACKUP_DIR" ] || { echo "apply.sh: --backup-dir is required" >&2; exit 2; }
[ "${#FILES[@]}" -gt 0 ] || { echo "apply.sh: no plugin.js given" >&2; exit 2; }
command -v python3 >/dev/null || { echo "apply.sh: python3 is required" >&2; exit 2; }
mkdir -p "$BACKUP_DIR"

# The publish block, exactly as applied (tabs; matches the source PR).
# Command substitution keeps the lines' leading tabs and drops only the
# trailing newline, which the inserter re-adds before `return {`.
PUBLISH_BLOCK="$(cat <<'BLOCKEOF'
	// Seam A publish leg: share each polled monitor snapshot with the
	// Desktop host (`host.publishMonitorLive`, hermes-agent branch
	// musti/live-session-unification-t_c63fe524) so the sidebar's Open-now
	// section shows the same live rows. Feature-detected: hosts without
	// the door ignore this silently. The host validates the payload and
	// keeps the last good snapshot on a malformed publish; a failed
	// publish must never break the widget.
	useEffect(() => {
		if (!snapshot || !scope) return;
		try {
			host.publishMonitorLive?.({
				profile: scope.profile,
				live: snapshot.live,
				fetchedAt: snapshot.generated_at,
			});
		} catch {
			/* Publish failures are not widget errors. */
		}
	}, [scope && scope.profile, snapshot]);
BLOCKEOF
)"

export PUBLISH_BLOCK
overall=0
for file in "${FILES[@]}"; do
  case "$file" in
    *profiles/*/plugins/quota/desktop/plugin.js) key="$(echo "$file" | sed 's|.*/profiles/\([^/]*\)/.*|\1|')" ;;
    *runtime/plugins/quota/desktop/plugin.js) key="repo" ;;
    *desktop-plugins/quota/plugin.js) key="framework" ;;
    *) key="$(echo -n "$file" | md5sum | cut -c1-8)" ;;
  esac
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [ ! -f "$file" ]; then echo "FAILED $file (not a file)"; overall=1; continue; fi
  if grep -q "host\.publishMonitorLive" "$file"; then echo "SKIP $file (already carries publishMonitorLive)"; continue; fi
  backup="$BACKUP_DIR/$key.plugin.js.$stamp.bak"
  cp -p "$file" "$backup" || { echo "FAILED $file (backup failed)"; overall=1; continue; }
  if ! python3 - "$file" <<'PYEOF'; then
import sys
path = sys.argv[1]
block = __import__('os').environ['PUBLISH_BLOCK']
anchor = "\tconst snapshot = payload && !(payload.error && !payload.live) ? payload : null;\n\treturn {"
src = open(path, encoding='utf-8').read()
if src.count(anchor) != 1:
    print(f"anchor count {src.count(anchor)} (need exactly 1)", file=sys.stderr)
    sys.exit(1)
if 'host.publishMonitorLive' in src:
    print("publish call already present", file=sys.stderr)
    sys.exit(1)
new = src.replace(anchor, "\tconst snapshot = payload && !(payload.error && !payload.live) ? payload : null;\n" + block + "\n\treturn {", 1)
tmp = path + '.publish-layer-tmp'
open(tmp, 'w', encoding='utf-8').write(new)
import os as _os
_os.replace(tmp, path)
PYEOF
    echo "FAILED $file (anchor insert failed; original kept at $backup)"; overall=1; continue
  fi
  # Verify by read-back: exactly one publish call, block identical, syntax clean.
  calls="$(grep -c "host\.publishMonitorLive?\.({" "$file" || true)"
  if [ "$calls" != "1" ]; then echo "FAILED $file (publish calls found: $calls, want 1; original kept at $backup)"; overall=1; continue; fi
  if ! python3 - "$file" <<'PYEOF'; then
import sys, os
path = sys.argv[1]
block = os.environ['PUBLISH_BLOCK']
src = open(path, encoding='utf-8').read()
if src.count(block) != 1:
    print(f"inserted block count {src.count(block)} (want 1)", file=sys.stderr)
    sys.exit(1)
PYEOF
    echo "FAILED $file (inserted block does not read back; original kept at $backup)"; overall=1; continue
  fi
  if command -v node >/dev/null; then
    if ! node --check "$file" 2>/dev/null; then echo "FAILED $file (node --check failed; original kept at $backup)"; overall=1; continue; fi
  else
    echo "note: node not on PATH for $file, syntax check skipped (block read-back verified)"
  fi
  echo "PATCHED $file (backup $backup)"
  grep -n "publishMonitorLive" "$file"
done
exit "$overall"
