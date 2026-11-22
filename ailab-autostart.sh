#!/usr/bin/env bash
# ailab-autostart.sh - start the VM when the host boots and shut it down
# gracefully (ACPI) when the host shuts down, using VirtualBox's own
# autostart service (vboxautostart).
#
#   ./ailab-autostart.sh enable [--systemd]  configure host + VM (asks for sudo)
#   ./ailab-autostart.sh disable             turn it off again
#   ./ailab-autostart.sh status              show VM flags and service state
#
# --systemd: fallback for hosts without the vboxautostart service (e.g. the
# distro-packaged VirtualBox): installs a small systemd unit instead.
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VBOX_DIR=/etc/vbox
VBOX_CFG=$VBOX_DIR/autostart.cfg
VBOX_DEFAULTS=/etc/default/virtualbox
SVC=vboxautostart-service
UNIT_NAME="ailab-vm.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
STOP_TIMEOUT=90

# Change VM settings, which needs the VM powered off: stop briefly if running.
with_vm_off() {
  local was_running=0
  if [[ "$(vm_state)" == running ]]; then
    was_running=1; log "stopping VM briefly to change its settings (disk state is kept)"
    vm_stop 60
  fi
  local rc=0
  "$@" || rc=$?
  # always bring the VM back, even if the change failed
  if ((was_running)); then vm_start; log "VM started again"; fi
  return "$rc"
}

# VBoxSVC (VirtualBox's per-user daemon) does the write to /etc/vbox and keeps the
# group list of the session that started it. If it predates our vboxusers membership
# it answers VERR_ACCESS_DENIED, so restart it, but only when no VM is running.
set_flags() {  # on|off
  if [[ -z "$(VBoxManage list runningvms)" ]]; then
    pkill -u "$(id -u)" -x VBoxSVC 2>/dev/null && sleep 3 || true
  else
    warn "other VMs are running, cannot restart VBoxSVC; if this fails with VERR_ACCESS_DENIED, log out/in and retry"
  fi
  vm_set_autostart "$1"
}

append_once() {  # append_once <file> <grep-ERE> <line...>   (sudo)
  local file="$1" pat="$2"; shift 2
  sudo test -f "$file" || sudo touch "$file"
  sudo grep -qE "$pat" "$file" || printf '%s\n' "$@" | sudo tee -a "$file" >/dev/null
}

case "${1:-}" in
  # Run by the systemd fallback unit only.
  _start)
    need VBoxManage
    case "$(vm_state)" in running) ;; paused) VBoxManage controlvm "$VM_NAME" resume ;; *) vm_start ;; esac ;;
  _stop)
    need VBoxManage
    vm_exists && vm_stop "$STOP_TIMEOUT" ;;

  enable)
    need VBoxManage systemctl sudo
    vm_exists || die "VM '$VM_NAME' does not exist. Run ailab-setup.sh first."
    user="$(id -un)"

    if [[ "${2:-}" == "--systemd" ]]; then
      [[ "$AILAB_DIR" != *[[:space:]]* ]] || die "install path must not contain spaces: $AILAB_DIR"
      tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
      cat >"$tmp" <<EOF
[Unit]
Description=ailab VirtualBox VM ($VM_NAME)
After=network.target vboxdrv.service virtualbox.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$user
Group=$(id -gn)
Environment="AILAB_STATE_DIR=$STATE_DIR"
ExecStart=$AILAB_DIR/ailab-autostart.sh _start
ExecStop=$AILAB_DIR/ailab-autostart.sh _stop
TimeoutStopSec=$((STOP_TIMEOUT + 30))
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
      sudo install -m 0644 "$tmp" "$UNIT_PATH"
      sudo systemctl daemon-reload
      sudo systemctl enable --now "$UNIT_NAME"
      log "enabled via systemd unit $UNIT_NAME"
      exit 0
    fi

    systemctl cat "$SVC" >/dev/null 2>&1 \
      || die "service '$SVC' not found (needs VirtualBox from Oracle's packages). Re-run with --systemd for the fallback."
    # The autostart database in /etc/vbox is writable by group vboxusers only, and the
    # group must be active in THIS session (a fresh usermod needs re-login). Re-exec
    # under the group with sg instead of failing with VERR_ACCESS_DENIED.
    if ! id -nG | tr ' ' '\n' | grep -qx vboxusers; then
      getent group vboxusers | grep -qw "$user" || { log "adding $user to group vboxusers (sudo)"; sudo usermod -aG vboxusers "$user"; }
      [[ -z "${AILAB_SG:-}" ]] || die "group vboxusers is not active for this session; log out and in again, then re-run"
      log "re-running with group vboxusers active"
      exec sg vboxusers -c "AILAB_SG=1 $(printf '%q ' "$0" "$@")"
    fi

    log "configuring VirtualBox autostart for user '$user' (sudo)"
    sudo install -d -m 1775 "$VBOX_DIR"
    sudo chgrp vboxusers "$VBOX_DIR"
    sudo chmod 1775 "$VBOX_DIR"
    # A long-running VBoxSVC may predate the group membership and then cannot write
    # here via the group. A per-user ACL does not depend on the daemon's group list.
    if command -v setfacl >/dev/null; then
      sudo setfacl -m "u:$user:rwx" "$VBOX_DIR"
    else
      warn "setfacl not found (sudo apt install acl). Without it, VBoxSVC needs the vboxusers group: log out/in (with no VMs running) and retry"
    fi
    append_once "$VBOX_DEFAULTS" '^VBOXAUTOSTART_DB=' 'VBOXAUTOSTART_DB=/etc/vbox'
    append_once "$VBOX_DEFAULTS" '^VBOXAUTOSTART_CONFIG=' 'VBOXAUTOSTART_CONFIG=/etc/vbox/autostart.cfg'
    append_once "$VBOX_CFG" '^default_policy' 'default_policy = deny'
    append_once "$VBOX_CFG" "^${user}[[:space:]]*=" "${user} = {" '  allow = true' '}'
    VBoxManage setproperty autostartdbpath "$VBOX_DIR"

    with_vm_off set_flags on
    sudo systemctl enable --now "$SVC"
    log "enabled: '$VM_NAME' starts ${AUTOSTART_DELAY}s after host boot and gets an ACPI shutdown when the host stops"
    ;;

  disable)
    need VBoxManage systemctl sudo
    if [[ -f "$UNIT_PATH" ]]; then
      sudo systemctl disable "$UNIT_NAME" || true
      sudo rm -f "$UNIT_PATH"; sudo systemctl daemon-reload
      log "removed $UNIT_NAME"
    fi
    if vm_exists; then
      with_vm_off set_flags off
      log "VM autostart/autostop flags cleared (host-wide vboxautostart config left untouched)"
    fi
    ;;

  status)
    need VBoxManage systemctl
    printf 'vm      : %s (%s)\n' "$VM_NAME" "$(vm_state || true)"
    VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null | grep -iE '^autost' | sed 's/^/flags   : /' || true
    printf 'service : %s (%s, %s)\n' "$SVC" \
      "$(systemctl is-enabled "$SVC" 2>/dev/null || echo 'not installed')" "$(systemctl is-active "$SVC" 2>/dev/null || echo inactive)"
    [[ -f "$UNIT_PATH" ]] && printf 'unit    : %s (%s)\n' "$UNIT_NAME" "$(systemctl is-active "$UNIT_NAME" 2>/dev/null)"
    ;;

  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
