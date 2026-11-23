# ailab - hardened IaC workspace VM on VirtualBox

A single Debian 13 VM that Claude Code uses over SSH as its workspace. Code is
written in the VM, pushed to GitHub, built by GitHub Actions, and applied
manually by an operator elsewhere.

## Host requirements

VirtualBox 7.x (`VBoxManage`), VT-x enabled, ~10 GB free disk, ~4.5 GB free RAM.

```bash
sudo apt install qemu-utils genisoimage curl openssh-client   # Debian/Ubuntu host
```

## Scripts

| Script | What it does |
|---|---|
| `./ailab-setup.sh` | Downloads + verifies the Debian image, creates and hardens the VM, installs tools, takes the `clean` snapshot, starts it. ~10-20 min on old hardware. |
| `./ailab-reset.sh [-y] [--force]` | Restores the `clean` snapshot (everything inside the lab is lost). Refuses if the lab holds git work not yet pushed, unless `--force`. |
| `./ailab-destroy.sh [-y] [--force] [--keep-cache]` | Deletes VM, disks, snapshots, SSH key, known_hosts and cached image. |
| `./ailab-addkey.sh <pubkey>` | Authorizes a client machine's SSH key for the `claude` user and bakes it into the `clean` snapshot (resets the lab once). |
| `./ailab-autostart.sh enable\|disable\|status` | Start the VM at host boot and ACPI-shutdown it at host shutdown, using VirtualBox's `vboxautostart` service. `enable --systemd` is a fallback unit for hosts without that service. |
| `ailab.conf` | CPU/RAM/disk, ports, users, tool versions. Override in `ailab.local.conf`. |

`./ailab-setup.sh --render <dir>` only writes the cloud-init files (no VirtualBox needed) for review.

## Design

- **Sizing:** 2 vCPU, 4 GB RAM, 40 GB dynamic disk, headless, virtio NIC, zram swap, no guest additions.
- **Access:** NAT with SSH forwarded to `127.0.0.1:3333` on the VM host only; nothing is exposed on the LAN.
  Claude Code runs on a *different* machine and reaches the VM by jumping through the VM host (`ProxyJump`), see below.
- **Users:** `claude` (workspace, **no sudo**) and `ailab` (admin, sudo, maintenance only, used from the VM host).
  The host-generated key `~/.ailab/id_ed25519` stays on the VM host; clients get their own keys.
- **Hardening:** key-only SSH, no root, `AllowUsers`, no agent/X11 forwarding, ufw default-deny (22 only),
  sysctl hardening, unattended security upgrades, locked passwords. fail2ban is deliberately omitted: behind NAT all
  logins come from the host (10.0.2.2) and it would ban the only legitimate client.
- **Tools:** git, gh, OpenTofu, tflint, ansible-core, ansible-lint, pre-commit, shellcheck, jq, make, tmux, ripgrep, pipx.
  OpenTofu and tflint come from official releases with SHA256 verification (pin via `TOFU_VERSION` / `TFLINT_VERSION`).

## Connecting Claude Code (runs on another machine)

```
Claude Code machine --ssh--> VM host (VirtualBox) --loopback:3333--> ailab VM
```

1. On the Claude Code machine: `ssh-keygen -t ed25519 -f ~/.ssh/ailab_client`
2. Copy `ailab_client.pub` to the VM host and authorize it (this resets the lab to clean once, then re-snapshots):
   `./ailab-addkey.sh ailab_client.pub`
   (Alternatively put the public key in `~/.ailab/client_keys.pub` *before* `ailab-setup.sh`.)
3. On the Claude Code machine, `~/.ssh/config`:

```
Host ailab-host
  HostName <address of the VM host>
  User <your user on the VM host>

Host ailab
  HostName 127.0.0.1          # resolved on the VM host, hits the loopback port-forward
  Port 3333
  User claude
  ProxyJump ailab-host
  IdentityFile ~/.ssh/ailab_client
  IdentitiesOnly yes
```

4. Check `ssh ailab`, then use `ailab` as the SSH host in Claude Code. The VM host's sshd must allow TCP forwarding (the default).

Notes: the Claude Code machine needs a login on the VM host (key-based) but never the VM's admin key. After
`ailab-destroy.sh` + `ailab-setup.sh` the VM gets new host keys, so run `ssh-keygen -R "[127.0.0.1]:3333"` on the client.

## Admin login (from the VM host)

The `ailab` user has passwordless sudo and is for maintenance only (e.g. `sudo apt-get upgrade`). Log in from the
VM host (the Debian machine running VirtualBox) with the key that setup created:

```bash
ssh -i ~/.ailab/id_ed25519 -p 3333 -o IdentitiesOnly=yes -o UserKnownHostsFile=~/.ailab/known_hosts ailab@127.0.0.1
```

Or add this to `~/.ssh/config` on the VM host and use `ssh ailab-admin`:

```
Host ailab-admin
  HostName 127.0.0.1
  Port 3333
  User ailab
  IdentityFile ~/.ailab/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ailab/known_hosts
```

- The port is `SSH_PORT` in `ailab.conf` (default 3333). For day-to-day work use the `claude` user (no sudo).
- Password login is disabled for both users; only keys work.
- The admin key never leaves the VM host. From another machine, log in to the VM host first.
- If SSH is unreachable, `VBoxManage startvm ailab --type gui` opens the console for boot diagnostics
  (there is no password to log in with).
- Changes made as `ailab` are lost on `ailab-reset.sh`, like everything else in the VM.

## Workflow

Inside the lab (as `claude`):

```bash
ailab-newproject my-infra myorg/my-infra
```

This scaffolds `~/work/my-infra` (`tofu/`, `ansible/`, workflows, pre-commit, .gitignore), creates a **repo-scoped
deploy key**, and prints the public key. You add it once on GitHub (Settings -> Deploy keys, allow write), then push.

- `ci.yml` - on push/PR: shellcheck, `tofu fmt/validate`, tflint, ansible-lint. Read-only token.
- `release.yml` - on `v*` tag or manual dispatch: validate, build a reproducible tarball + `SHA256SUMS`,
  attach build-provenance attestation, publish a GitHub release. **No cloud credentials in GitHub, nothing is applied.**
- Operator, in another environment: `tools/operator-fetch.sh v1.0.0` downloads the release, checks the checksum and
  `gh attestation verify`, unpacks it, and prints the `tofu plan/apply` / `ansible-playbook` steps to run by hand.

## Things to know

- **Reset wipes deploy keys too.** Re-run `ailab-newproject` (or re-clone) after a reset. All durable work lives on GitHub.
- The snapshot is a stale OS; unattended-upgrades catches up after reset, run `sudo apt-get upgrade` as `ailab` if you want it current right away
  (or re-run setup to refresh the snapshot).
- The deploy-key-per-repo approach cannot create repositories; create the empty repo on GitHub first.
- Workflows reference actions by major tag (`@v4`). For stricter supply-chain control pin to commit SHAs (e.g. with Dependabot).
- Git identity in the VM comes from `GIT_USER_NAME` / `GIT_USER_EMAIL` in `ailab.conf` (default: a noreply address).

## Autostart / autoshutdown

```bash
./ailab-autostart.sh enable    # one-time, needs sudo; VM restarts briefly to change its settings
./ailab-autostart.sh status
```

This uses VirtualBox's native mechanism: the VM gets `--autostart-enabled on --autostop-type acpishutdown`
(delay `AUTOSTART_DELAY` in `ailab.conf`), and the host's `vboxautostart-service` starts it at boot and sends
an ACPI shutdown at host shutdown. `enable` configures `/etc/default/virtualbox`, `/etc/vbox/autostart.cfg`
and the `autostartdbpath` for your user, and requires membership in the `vboxusers` group.

- The flags live in the VM settings, which a snapshot restore reverts, so setup/reset/addkey re-apply them.
- Check autostop once: `sudo systemctl stop vboxautostart-service` should shut the VM down cleanly.
- Hosts using the distro-packaged VirtualBox usually lack `vboxautostart-service`: use `enable --systemd`.
