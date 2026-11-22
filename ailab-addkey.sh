#!/usr/bin/env bash
# ailab-addkey.sh - authorize an extra client SSH key (e.g. the machine that runs
# Claude Code) for the workspace user. The key is baked into the "clean" snapshot,
# so it survives ailab-reset.sh. NOTE: this resets the lab to clean first.
#
#   ./ailab-addkey.sh [-y] [--force] <public-key-file>
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASSUME_YES=0; FORCE=0; keyfile=""
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=1 ;;
    --force)  FORCE=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    -*) die "unknown option: $a" ;;
    *) keyfile="$a" ;;
  esac
done
[[ -f "$keyfile" ]] || die "usage: ailab-addkey.sh [-y] [--force] <public-key-file>"
key="$(grep -E '^(ssh-|ecdsa-|sk-)' "$keyfile" | head -n1 || true)"
[[ -n "$key" && "$key" != *\"* ]] || die "$keyfile does not contain a valid public key"

need VBoxManage ssh
vm_exists   || die "VM '$VM_NAME' does not exist. Run ailab-setup.sh first."
vm_has_snap || die "snapshot '$SNAPSHOT_NAME' not found on '$VM_NAME'."

guard_unpushed
confirm "Add key and reset the lab to a clean state (re-snapshots). Continue?" || die "aborted"

mkdir -p "$STATE_DIR"
touch "$CLIENT_KEYS_FILE"
grep -qxF "$key" "$CLIENT_KEYS_FILE" || printf '%s\n' "$key" >>"$CLIENT_KEYS_FILE"

log "restoring clean state"
vm_stop 60
VBoxManage snapshot "$VM_NAME" restore "$SNAPSHOT_NAME"
vm_apply_autostart
vm_start
wait_for_ssh 180

log "authorizing key for $WORK_USER"
ssh_vm "$ADMIN_USER" "grep -qxF '$key' /home/$WORK_USER/.ssh/authorized_keys || echo '$key' | sudo tee -a /home/$WORK_USER/.ssh/authorized_keys >/dev/null"

log "refreshing snapshot '$SNAPSHOT_NAME'"
ssh_vm "$ADMIN_USER" 'sudo systemctl poweroff' || true
for _ in $(seq 1 30); do [[ "$(vm_state)" == "poweroff" ]] && break; sleep 2; done
[[ "$(vm_state)" == "poweroff" ]] || { VBoxManage controlvm "$VM_NAME" poweroff; sleep 3; }
VBoxManage snapshot "$VM_NAME" delete "$SNAPSHOT_NAME"
VBoxManage snapshot "$VM_NAME" take "$SNAPSHOT_NAME" --description "ailab clean (client key added)"
vm_start
wait_for_ssh 180
log "done. The key is authorized for '$WORK_USER' and will survive ailab-reset.sh"
