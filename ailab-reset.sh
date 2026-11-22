#!/usr/bin/env bash
# ailab-reset.sh - throw away everything inside the lab and return to the clean
# post-setup state (restores the "clean" VirtualBox snapshot).
#
#   ./ailab-reset.sh [-y] [--force]
#     -y       do not ask for confirmation
#     --force  discard even if the lab has uncommitted/unpushed git work
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASSUME_YES=0; FORCE=0
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=1 ;;
    --force)  FORCE=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done

need VBoxManage ssh
vm_exists   || die "VM '$VM_NAME' does not exist. Run ailab-setup.sh first."
vm_has_snap || die "snapshot '$SNAPSHOT_NAME' not found on '$VM_NAME'. Run ailab-destroy.sh and ailab-setup.sh."

guard_unpushed
confirm "Reset '$VM_NAME': everything inside the lab (code, deploy keys, installs) is lost. Continue?" || die "aborted"

log "stopping VM"
vm_stop 60
log "restoring snapshot '$SNAPSHOT_NAME'"
VBoxManage snapshot "$VM_NAME" restore "$SNAPSHOT_NAME"
vm_apply_autostart
log "starting VM"
vm_start
wait_for_ssh 180

log "ailab is back to a clean state. New projects need a new deploy key: ailab-newproject <name> <owner/repo>"
