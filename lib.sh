#!/usr/bin/env bash
# Shared helpers for ailab-*.sh. Source this file, do not execute it.

AILAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ailab.conf
source "$AILAB_DIR/ailab.conf"
# shellcheck disable=SC1091
[[ -f "$AILAB_DIR/ailab.local.conf" ]] && source "$AILAB_DIR/ailab.local.conf"

SSH_KEY="$STATE_DIR/id_ed25519"
KNOWN_HOSTS="$STATE_DIR/known_hosts"
CLIENT_KEYS_FILE="$STATE_DIR/client_keys.pub"
CACHE_DIR="$STATE_DIR/cache"
VM_BASE="$STATE_DIR/vm"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "missing host tools: ${missing[*]} (Debian/Ubuntu: sudo apt install qemu-utils genisoimage curl openssh-client)"
}

vm_exists()   { VBoxManage showvminfo "$VM_NAME" --machinereadable >/dev/null 2>&1; }
vm_state()    { VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null | sed -n 's/^VMState="\(.*\)"$/\1/p'; }
vm_has_snap() { VBoxManage snapshot "$VM_NAME" list --machinereadable 2>/dev/null | grep -q "^SnapshotName=\"$SNAPSHOT_NAME\""; }

# ssh_vm <user> [command...]
ssh_vm() {
  local user="$1"; shift
  ssh -i "$SSH_KEY" -p "$SSH_PORT" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o LogLevel=ERROR "$user@$SSH_BIND" "$@"
}

wait_for_ssh() {
  local timeout="${1:-300}" waited=0
  log "waiting for SSH on $SSH_BIND:$SSH_PORT (max ${timeout}s)"
  until ssh_vm "$ADMIN_USER" true 2>/dev/null; do
    sleep 5; waited=$((waited + 5))
    ((waited < timeout)) || die "SSH did not come up in ${timeout}s (try: VBoxManage startvm $VM_NAME --type gui)"
  done
}

# Graceful ACPI shutdown, hard poweroff after timeout.
vm_stop() {
  local timeout="${1:-60}" waited=0
  [[ "$(vm_state)" == "running" ]] || return 0
  VBoxManage controlvm "$VM_NAME" acpipowerbutton || true
  while [[ "$(vm_state)" == "running" ]]; do
    sleep 2; waited=$((waited + 2))
    if ((waited >= timeout)); then
      warn "graceful shutdown timed out, powering off"
      VBoxManage controlvm "$VM_NAME" poweroff || true
      sleep 3; break
    fi
  done
}

vm_start() { VBoxManage startvm "$VM_NAME" --type headless >/dev/null; }

confirm() {
  [[ "${ASSUME_YES:-0}" == 1 ]] && return 0
  local ans; read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# Refuse to continue if the lab holds work that is not on GitHub (unless FORCE=1).
guard_unpushed() {
  [[ "$(vm_state)" == "running" ]] || return 0
  local out rc=0
  out="$(ssh_vm "$WORK_USER" ailab-check-unpushed 2>/dev/null)" || rc=$?
  case "$rc" in
    0)   return 0 ;;
    1)   warn "work in the lab is NOT on GitHub:"; sed 's/^/    /' <<<"$out" >&2
         [[ "${FORCE:-0}" == 1 ]] || die "push it first (git push), or re-run with --force to discard it" ;;
    *)   warn "could not check the lab for unpushed work (VM unreachable?)"
         [[ "${FORCE:-0}" == 1 ]] || confirm "Continue anyway and lose anything not on GitHub?" || die "aborted" ;;
  esac
}

# VM autostart/autostop flags (VM must be powered off). Snapshot restore reverts
# them, so setup/reset/addkey re-apply after every restore.
vm_set_autostart() {  # on|off
  if [[ "$1" == on ]]; then
    VBoxManage modifyvm "$VM_NAME" --autostart-enabled on --autostart-delay "$AUTOSTART_DELAY" --autostop-type acpishutdown
  else
    VBoxManage modifyvm "$VM_NAME" --autostart-enabled off --autostop-type disabled
  fi
}
# Never fatal: the host side may not be configured yet (see ailab-autostart.sh enable).
vm_apply_autostart() {
  [[ "$AUTOSTART" == yes ]] || return 0
  vm_set_autostart on || warn "could not set VM autostart flags; run ./ailab-autostart.sh enable"
}
