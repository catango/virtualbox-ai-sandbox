#!/usr/bin/env bash
# ailab-setup.sh - build the hardened ailab VM on VirtualBox.
#
#   ./ailab-setup.sh            create VM, provision it, take the "clean" snapshot
#   ./ailab-setup.sh --render D write cloud-init user-data/meta-data to dir D and
#                               stop (no VirtualBox needed; for review/testing)
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RENDER_DIR=""
if [[ "${1:-}" == "--render" ]]; then RENDER_DIR="${2:?usage: --render <dir>}"; fi

# ---------------------------------------------------------------- preflight --
if [[ -z "$RENDER_DIR" ]]; then
  need VBoxManage qemu-img curl ssh ssh-keygen sha512sum ss
  ISO_TOOL=""
  for t in genisoimage xorriso mkisofs; do command -v "$t" >/dev/null && { ISO_TOOL="$t"; break; }; done
  [[ -n "$ISO_TOOL" ]] || die "need genisoimage, xorriso or mkisofs (sudo apt install genisoimage)"

  vm_exists && die "VM '$VM_NAME' already exists. Use ailab-reset.sh to restore it or ailab-destroy.sh to remove it."
  [[ -z "$(ss -Htln "sport = :$SSH_PORT")" ]] || die "host port $SSH_PORT is already in use (change SSH_PORT in ailab.conf)"

  grep -qE '\b(vmx|svm)\b' /proc/cpuinfo || warn "no VT-x/AMD-V flag in /proc/cpuinfo: enable virtualization in BIOS, VM will be very slow or fail"
  avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  ((avail_mb > VM_RAM_MB + 1536)) || warn "only ${avail_mb} MB RAM available on host, VM wants ${VM_RAM_MB} MB: lower VM_RAM_MB in ailab.conf"
fi

mkdir -p "$STATE_DIR" "$CACHE_DIR" "$VM_BASE"
touch "$STATE_DIR/.ailab-state"   # marker: destroy only deletes directories carrying it
chmod 700 "$STATE_DIR"

# ------------------------------------------------------------------ SSH key --
if [[ ! -f "$SSH_KEY" ]]; then
  log "generating SSH key $SSH_KEY (no passphrase: Claude Code connects unattended)"
  ssh-keygen -q -t ed25519 -N '' -C "ailab-host-key" -f "$SSH_KEY"
fi
PUBKEY="$(cat "$SSH_KEY.pub")"

# Extra client keys (e.g. the machine running Claude Code), one public key per line.
# Authorized for the workspace user only. Managed by ailab-addkey.sh.
CLIENT_KEYS=""
if [[ -f "$CLIENT_KEYS_FILE" ]]; then
  while IFS= read -r k; do
    [[ "$k" =~ ^(ssh-|ecdsa-|sk-) && "$k" != *\"* ]] && CLIENT_KEYS+="      - \"$k\""$'\n'
  done <"$CLIENT_KEYS_FILE"
fi

# -------------------------------------------------------- render cloud-init --
if [[ -n "$RENDER_DIR" ]]; then WORK="$RENDER_DIR"; mkdir -p "$WORK"
else WORK="$(mktemp -d "$STATE_DIR/build.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT; fi
UD="$WORK/user-data"

# add_file <dest> <mode> [append]   (content on stdin, shipped base64 encoded)
add_file() {
  {
    echo "  - path: $1"
    echo "    permissions: '$2'"
    echo "    owner: root:root"
    [[ "${3:-}" == append ]] && echo "    append: true"
    echo "    encoding: b64"
    echo "    content: $(base64 -w0)"
  } >>"$UD"
}

log "rendering cloud-init config"
cat >"$UD" <<EOF
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true
timezone: $TIMEZONE
ssh_pwauth: false
disable_root: true
package_update: true
package_upgrade: true

users:
  - name: $WORK_USER
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - "$PUBKEY"
${CLIENT_KEYS}  - name: $ADMIN_USER
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "$PUBKEY"

packages:
  - git
  - gh
  - ansible-core
  - ansible-lint
  - pre-commit
  - shellcheck
  - jq
  - curl
  - unzip
  - make
  - tmux
  - ripgrep
  - rsync
  - python3-venv
  - python3-pip
  - pipx
  - ufw
  - unattended-upgrades
  - systemd-zram-generator

write_files:
EOF

sed -e "s/__WORK_USER__/$WORK_USER/g" -e "s/__ADMIN_USER__/$ADMIN_USER/g" \
  "$AILAB_DIR/vm/sshd-hardening.conf.tpl" | add_file /etc/ssh/sshd_config.d/00-ailab.conf 0644
add_file /etc/sysctl.d/99-ailab.conf 0644            <"$AILAB_DIR/vm/sysctl-hardening.conf"
add_file /usr/local/sbin/ailab-provision 0755        <"$AILAB_DIR/vm/provision.sh"
add_file /usr/local/bin/ailab-newproject 0755        <"$AILAB_DIR/vm/newproject.sh"
add_file /usr/local/bin/ailab-check-unpushed 0755    <"$AILAB_DIR/vm/check-unpushed.sh"
for f in ci.yml release.yml operator-fetch.sh pre-commit-config.yaml gitignore; do
  add_file "/opt/ailab/templates/$f" 0644 <"$AILAB_DIR/vm/templates/$f"
done
printf 'TOFU_VERSION="%s"\nTFLINT_VERSION="%s"\n' "$TOFU_VERSION" "$TFLINT_VERSION" \
  | add_file /etc/ailab/versions.env 0644
printf 'TF_PLUGIN_CACHE_DIR=/var/cache/tofu-plugins\n' \
  | add_file /etc/environment 0644 append
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' \
  | add_file /etc/apt/apt.conf.d/20auto-upgrades 0644
printf '[zram0]\nzram-size = ram / 2\n' \
  | add_file /etc/systemd/zram-generator.conf 0644
printf '[user]\n\tname = %s\n\temail = %s\n[init]\n\tdefaultBranch = main\n[pull]\n\tff = only\n' "$GIT_USER_NAME" "$GIT_USER_EMAIL" \
  | add_file /etc/gitconfig 0644

cat >>"$UD" <<EOF

runcmd:
  - [passwd, -l, root]
  - [sysctl, --system]
  - [install, -d, -o, $WORK_USER, -g, $WORK_USER, -m, "0755", /var/cache/tofu-plugins]
  - [install, -d, -o, $WORK_USER, -g, $WORK_USER, -m, "0755", /home/$WORK_USER/work]
  - [/usr/local/sbin/ailab-provision]
  - [ufw, default, deny, incoming]
  - [ufw, default, allow, outgoing]
  - [ufw, allow, 22/tcp]
  - [ufw, --force, enable]
  - [sh, -c, "sshd -t && systemctl restart ssh"]
EOF

printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$VM_NAME" "$(date +%s)" "$VM_NAME" >"$WORK/meta-data"

if [[ -n "$RENDER_DIR" ]]; then
  log "rendered to $RENDER_DIR (user-data, meta-data). Nothing else done."
  exit 0
fi

# ------------------------------------------------------------- base image ---
log "fetching base image checksum"
sums="$(curl -fsSL "$IMG_BASE_URL/SHA512SUMS")"
want="$(awk -v n="$IMG_NAME" '$2 == n {print $1}' <<<"$sums")"
[[ -n "$want" ]] || die "$IMG_NAME not found in $IMG_BASE_URL/SHA512SUMS"

IMG="$CACHE_DIR/$IMG_NAME"
if [[ ! -f "$IMG" ]] || [[ "$(sha512sum "$IMG" | awk '{print $1}')" != "$want" ]]; then
  log "downloading $IMG_NAME"
  curl -fL --retry 3 -o "$IMG.part" "$IMG_BASE_URL/$IMG_NAME"
  [[ "$(sha512sum "$IMG.part" | awk '{print $1}')" == "$want" ]] || { rm -f "$IMG.part"; die "checksum mismatch for $IMG_NAME"; }
  mv "$IMG.part" "$IMG"
else
  log "using cached $IMG_NAME (checksum ok)"
fi

# --------------------------------------------------------------- create VM --
VM_DIR="$VM_BASE/$VM_NAME"
log "creating VM '$VM_NAME' ($VM_CPUS vCPU, $VM_RAM_MB MB RAM, $VM_DISK_MB MB disk)"
VBoxManage createvm --name "$VM_NAME" --basefolder "$VM_BASE" --ostype Debian_64 --register >/dev/null
# From here on a failure leaves a half-built VM; tell the operator how to clean up.
trap 'rm -rf "$WORK"; warn "setup failed. Inspect with: VBoxManage startvm $VM_NAME --type gui ; or remove with: $AILAB_DIR/ailab-destroy.sh -y"' ERR

DISK="$VM_DIR/$VM_NAME.vdi"
qemu-img convert -f qcow2 -O raw "$IMG" "$WORK/disk.raw"
VBoxManage convertfromraw "$WORK/disk.raw" "$DISK" --format VDI >/dev/null
rm -f "$WORK/disk.raw"
VBoxManage modifymedium disk "$DISK" --resize "$VM_DISK_MB"

VBoxManage modifyvm "$VM_NAME" \
  --cpus "$VM_CPUS" --memory "$VM_RAM_MB" --vram 8 --graphicscontroller vmsvga \
  --ioapic on --rtcuseutc on --paravirtprovider kvm \
  --boot1 disk --boot2 none --boot3 none --boot4 none \
  --nic1 nat --nictype1 virtio --cableconnected1 on \
  --natpf1 "ssh,tcp,$SSH_BIND,$SSH_PORT,,22"

VBoxManage storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci --portcount 2
VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 --type hdd \
  --medium "$DISK" --nonrotational on --discard on

case "$ISO_TOOL" in
  xorriso) xorriso -as mkisofs -quiet -o "$WORK/seed.iso" -V cidata -J -r "$UD" "$WORK/meta-data" ;;
  *)       "$ISO_TOOL" -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock "$UD" "$WORK/meta-data" ;;
esac
VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$WORK/seed.iso"

# ---------------------------------------------------------- first boot ------
log "first boot (cloud-init installs and hardens; expect 5-15 min on older hardware)"
vm_start
wait_for_ssh 600

rc=0
for _ in 1 2 3; do
  rc=0; ssh_vm "$ADMIN_USER" 'sudo cloud-init status --wait' || rc=$?
  ((rc == 255)) || break          # 255 = connection dropped (sshd restart), retry
  wait_for_ssh 120
done
case "$rc" in
  0) ;;
  2) warn "cloud-init finished with recoverable errors; verifying tools" ;;
  *) die "cloud-init failed (rc=$rc). Check: ssh -i $SSH_KEY -p $SSH_PORT $ADMIN_USER@$SSH_BIND 'sudo cloud-init status --long; sudo tail -50 /var/log/cloud-init-output.log'" ;;
esac

log "verifying toolchain and hardening"
ssh_vm "$WORK_USER" 'git --version && gh --version | head -1 && tofu version | head -1 && tflint --version | head -1 && ansible --version | head -1 && ansible-lint --version | head -1 && pre-commit --version && shellcheck --version | sed -n 2p' \
  || die "toolchain verification failed (see /var/log/cloud-init-output.log in the VM)"
ssh_vm "$ADMIN_USER" 'sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin) " && sudo ufw status | head -3'
ssh_vm "$WORK_USER" 'sudo -n true' 2>/dev/null && die "'$WORK_USER' unexpectedly has sudo"

# ------------------------------------------------- finalize + snapshot ------
log "cleaning guest and shutting down for the '$SNAPSHOT_NAME' snapshot"
ssh_vm "$ADMIN_USER" 'sudo apt-get clean && sudo fstrim -a; sudo journalctl --rotate >/dev/null 2>&1; sudo journalctl --vacuum-time=1s >/dev/null 2>&1; sudo systemctl poweroff' || true
for _ in $(seq 1 30); do [[ "$(vm_state)" == "poweroff" ]] && break; sleep 2; done
[[ "$(vm_state)" == "poweroff" ]] || { VBoxManage controlvm "$VM_NAME" poweroff; sleep 3; }

VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 1 --device 0 --type dvddrive --medium none
vm_apply_autostart
VBoxManage snapshot "$VM_NAME" take "$SNAPSHOT_NAME" --description "Freshly provisioned ailab"
vm_start
wait_for_ssh 180
trap - ERR

cat <<EOF

ailab is ready (snapshot '$SNAPSHOT_NAME' taken).

  Workspace user : ssh -i $SSH_KEY -p $SSH_PORT $WORK_USER@$SSH_BIND
  Admin user     : ssh -i $SSH_KEY -p $SSH_PORT $ADMIN_USER@$SSH_BIND   (sudo; maintenance only)

The VM is only reachable on this host's loopback ($SSH_BIND:$SSH_PORT). Claude Code runs on
another machine, so it reaches the VM by jumping through this host.

1. On the client machine, create a dedicated key and authorize it here:
     client:  ssh-keygen -t ed25519 -f ~/.ssh/ailab_client
     here:    $AILAB_DIR/ailab-addkey.sh /path/to/ailab_client.pub
2. Client ~/.ssh/config (use 'ailab' as the SSH host in Claude Code):

     Host ailab-host
       HostName <address of this host>
       User <your user on this host>

     Host ailab
       HostName $SSH_BIND        # resolved on this host: hits the loopback port-forward
       Port $SSH_PORT
       User $WORK_USER
       ProxyJump ailab-host
       IdentityFile ~/.ssh/ailab_client
       IdentitiesOnly yes

   (Keys already in $CLIENT_KEYS_FILE at setup time are authorized automatically.)

First project, inside the lab:   ailab-newproject <name> <github-owner/repo>
Back to clean state:             $AILAB_DIR/ailab-reset.sh
Remove everything:               $AILAB_DIR/ailab-destroy.sh
EOF
