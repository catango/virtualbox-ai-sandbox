#!/usr/bin/env bash
# ailab-destroy.sh - completely remove the ailab VM, its disks and snapshots,
# and the local state (SSH key, known_hosts, cached base image).
#
#   ./ailab-destroy.sh [-y] [--force] [--keep-cache]
#     -y            do not ask for confirmation
#     --force       destroy even if the lab has uncommitted/unpushed git work
#     --keep-cache  keep the downloaded Debian image (saves a ~400 MB re-download)
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASSUME_YES=0; FORCE=0; KEEP_CACHE=0
for a in "$@"; do
  case "$a" in
    -y|--yes)     ASSUME_YES=1 ;;
    --force)      FORCE=1 ;;
    --keep-cache) KEEP_CACHE=1 ;;
    -h|--help)    sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done

need VBoxManage

if vm_exists; then
  guard_unpushed
  confirm "Permanently delete VM '$VM_NAME' and all local ailab state?" || die "aborted"
  if [[ "$(vm_state)" != "poweroff" ]]; then
    log "powering off VM"
    VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    sleep 3
  fi
  log "unregistering and deleting VM (disks + snapshots)"
  VBoxManage unregistervm "$VM_NAME" --delete
  # fallback systemd unit (only exists if enabled with --systemd)
  if [[ -f /etc/systemd/system/ailab-vm.service ]]; then "$AILAB_DIR/ailab-autostart.sh" disable || true; fi
else
  confirm "VM '$VM_NAME' not found. Remove leftover local ailab state in $STATE_DIR?" || die "aborted"
fi

# Local state: only touch directories that ailab-setup.sh created.
if [[ -f "$STATE_DIR/.ailab-state" ]]; then
  rm -rf "$VM_BASE" "$STATE_DIR"/build.* "$KNOWN_HOSTS" "$SSH_KEY" "$SSH_KEY.pub"
  if ((KEEP_CACHE)); then
    log "kept image cache in $CACHE_DIR"
  else
    rm -rf "$CACHE_DIR" "$STATE_DIR/.ailab-state"
    rmdir "$STATE_DIR" 2>/dev/null || warn "$STATE_DIR not empty, left in place"
  fi
elif [[ -e "$STATE_DIR" ]]; then
  warn "$STATE_DIR has no ailab marker file, not deleting it"
fi

cat <<EOF

ailab removed. Manual leftovers (not touched by this script):
  - 'Host ailab' block in ~/.ssh/config (if you added it)
  - GitHub deploy keys titled "ailab" on your repos (Settings -> Deploy keys)
EOF
