# GCP Remote Dev VM

Quickly provisions a GCP Compute Engine VM for remote development. One VM serves every SSH client: VS Code Remote-SSH, a desktop terminal, or [Termius on iOS](TERMIUS_IOS.md) (for example, to start or resume an `agy` session from your phone). Two access modes are supported:

- **`iap` (default)** — the VM has no public IP; access is exclusively through [Identity-Aware Proxy (IAP)](https://cloud.google.com/iap) tunneling, with Cloud NAT for outbound traffic. Desktop clients with `gcloud` only.
- **`public`** — the VM gets a reserved static external IP and accepts direct SSH (key-only) and Mosh. Required for mobile clients such as Termius.

Antigravity CLI (installed by default) and, optionally, Claude Code are pre-configured to authenticate via the VM's GCP service account (no API keys needed).

## What Gets Provisioned

**GCP infrastructure** (via `provision.sh`):
- Service account with minimal IAM roles (Vertex AI user, log writer, metric writer)
- `iap` mode: Cloud Router + Cloud NAT for outbound internet, a firewall rule allowing SSH only from the IAP CIDR (`35.235.240.0/20`), and IAP tunnel access for `IAP_USER`
- `public` mode: a reserved static external IP (`<VM_NAME>-ip`) and a firewall rule allowing `tcp:22` (SSH) and `udp:60000-60010` (Mosh) from `0.0.0.0/0`, scoped by network tag (`<VM_NAME>-public-ssh`) to this VM only
- Ubuntu 24.04 LTS VM (Shielded VM) with the startup script attached; SSH public keys are delivered via `ssh-keys` instance metadata

**VM system setup** (via `startup-script.sh`, runs as root on first boot):
- System packages, unattended security upgrades
- Google Cloud CLI, Node.js 22 LTS, GitHub CLI, mosh, tmux (+ `en_US.UTF-8` locale for Mosh clients)
- sshd hardening (key-only, no root login, only `VM_USER` may log in); fail2ban in `public` mode
- Vertex AI environment variables for all users (`/etc/profile.d/ai-tools.sh`)

**User dev environment** (via `~/setup-user.sh`, run once after first SSH login):
- Antigravity CLI (`agy`) and/or Claude Code CLI — per `INSTALL_TOOLS` (default: `agy` only)
- Oh My Zsh + Powerlevel10k theme + plugins (autosuggestions, syntax-highlighting)
- pyenv + pyenv-virtualenv

## Prerequisites

- [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed and authenticated (`gcloud auth login`)
- A GCP VPC network and subnet (if the network doesn't exist, the script can create it; see Preflight below)
- Sufficient IAM permissions to create VMs, service accounts, firewall rules, Cloud NAT, and static IPs

## Quick Start

### 1. Configure

```bash
cp config.env.example config.env
```

`config.env` is split into sections. Sections 1–5 apply to every VM. Section 6 is read only in `iap` mode, so **public mode needs fewer settings**.

| Section | Variable | Required? | Description |
|---|---|---|---|
| 1. Project | `PROJECT_ID` | ✅ | Your GCP project ID |
| | `REGION` / `ZONE` | default | Where the VM is provisioned (`us-west1` / `us-west1-b`) |
| 2. VM | `VM_USER` | ✅ | Linux username to create on the VM |
| | `VM_NAME`, `MACHINE_TYPE`, `BOOT_DISK_*`, `SERVICE_ACCOUNT_NAME` | default | VM shape and identity |
| 3. Network | `NETWORK` / `SUBNET` | ✅ | VPC network and its subnet in `REGION` |
| | `SUBNET_RANGE` | default | CIDR used only if the script creates `NETWORK` |
| | `ACCESS_MODE` | default `iap` | `iap` or `public` (see top of this README) |
| 4. SSH keys | `SSH_KEYS_FILE` | default | File of per-device public keys (`./authorized_keys`); auto-created on first run |
| 5. AI tools | `INSTALL_TOOLS` | default `agy` | `agy`, `claude`, or `agy,claude` |
| | `VERTEX_REGION`, `CLAUDE_MODEL` | default | Vertex AI settings |
| 6. IAP only | `IAP_USER` | ✅ in `iap` mode | GCP user granted IAP tunnel access; ignored in `public` mode |

So a public-mode VM needs only `PROJECT_ID`, `VM_USER`, `NETWORK`, `SUBNET`, and `ACCESS_MODE="public"` (or the `--access=public` flag).

### 2. Provision

```bash
chmod +x provision.sh
./provision.sh                                  # uses config.env values
./provision.sh --access=public                  # override ACCESS_MODE
./provision.sh --tools=agy,claude               # override INSTALL_TOOLS
```

The script is idempotent — safe to run multiple times. It does not modify an existing VM; to switch access modes, delete the VM and re-run.

**Preflight & failures.** Before creating anything, the script checks that `ZONE` is in `REGION`, that `MACHINE_TYPE` exists there, and that `SUBNET` belongs to `NETWORK`:

- `NETWORK` missing → it lists existing networks and offers to create a custom VPC plus `SUBNET` (`SUBNET_RANGE`, Private Google Access on).
- `NETWORK` exists but `SUBNET` doesn't (or is in another network) → it prints that network's subnets in `REGION` and exits. It never adds subnets to an existing network.
- Existing firewall rule with the expected name but on a different network → exits with a delete command.
- Any other failure prints the step that failed. Fix the cause and re-run; finished steps are skipped.

Shared VPC (host-project networks) isn't supported.

To add a tool after provisioning, set the metadata flag, then re-run the user setup on the VM:

```bash
gcloud compute instances add-metadata remote-dev --zone=us-west1-b --metadata=install-claude=true
# on the VM:
rm ~/.setup-done && bash ~/setup-user.sh
```

### 3. Wait for the startup script (~10 min)

Monitor progress from your local machine:

```bash
gcloud compute instances get-serial-port-output remote-dev \
  --zone=us-west1-b --project=YOUR_PROJECT_ID | grep '\[startup\]'
```

### 4. SSH keys + client setup

Each client device has **its own key pair**, generated on that device. Only the public keys go into `SSH_KEYS_FILE` (`./authorized_keys`, gitignored). They're delivered as `ssh-keys` instance metadata, and the VM's guest agent keeps `~/.ssh/authorized_keys` in sync with that metadata. Private keys never leave the device that created them.

Typical setup is two devices, your Mac and your iPhone:

1. **Mac (automatic):** on the first `./provision.sh`, if `authorized_keys` is empty, the script generates `~/.ssh/<VM_NAME>_ed25519` and creates the file:
   ```text
   # Public SSH keys allowed to log in to remote-dev as dev — one line per device.
   # After editing, push the change with:  ./provision.sh --update-keys
   # To revoke a device, delete its line and run --update-keys again.

   # This machine (my-mac) — private key: ~/.ssh/remote-dev_ed25519
   ssh-ed25519 AAAA... dev@remote-dev

   # iPhone/iPad (Termius): Keychain → your key → copy PUBLIC key, paste on the next line
   ```
2. **iPhone:** generate a key in Termius, then AirDrop or paste its public key into that last slot. If the VM already exists, run:
   ```bash
   ./provision.sh --update-keys    # takes effect within seconds, no reboot or SSH needed
   ```
   Full steps are in [`TERMIUS_IOS.md`](TERMIUS_IOS.md).

Add another device the same way. To revoke one (e.g. a lost phone), delete its line and run `--update-keys` again. To reuse an existing key instead of generating one, put its `.pub` line in `authorized_keys` before the first run. The format is the same as `~/.ssh/authorized_keys`: `<type> <base64> [comment]`, without `user:` prefixes or key options.

Then set up your client:
- **Desktop / VS Code:** follow [`ssh-config-example.txt`](ssh-config-example.txt): `~/.ssh/config` entry, MesloLGS NF font, GitHub agent forwarding, VS Code Remote SSH. `provision.sh` also prints a ready-to-paste `~/.ssh/config` block.
- **Termius on iOS** (public mode): follow [`TERMIUS_IOS.md`](TERMIUS_IOS.md).

### 5. First SSH login — complete user setup

```bash
bash ~/setup-user.sh   # runs once; takes ~5-10 minutes
exec zsh               # switch to the configured shell
```

Tip: run long-lived work (e.g. `agy`) inside `tmux new -A -s main`. You can then detach, and reattach later from any client, including your phone.

## Security Notes

- `iap` mode (default): the VM has **no public IP**; SSH is only reachable via IAP tunnel
- `public` mode: `tcp:22` and `udp:60000-60010` are open to the internet for this VM only (tag-scoped firewall rule); fail2ban bans IPs after 5 failed logins in 10 minutes (1h ban)
- sshd (all modes): public-key auth only, no root login, `AllowUsers <VM_USER>`, `MaxAuthTries 3` — use `IdentitiesOnly yes` in client configs so the right key is offered first
- One key per device; private keys never leave the device that generated them; revoke a device by removing its line and running `--update-keys`
- All third-party apt/npm repositories are added via signed GPG keys (no `curl | bash` as root)
- Vertex AI authentication uses the VM's service account — no API keys or credentials stored on the VM

## Cleanup (public mode)

The reserved static IP is billed while reserved and is **not** deleted with the VM:

```bash
gcloud compute addresses delete remote-dev-ip --region=us-west1 --project=YOUR_PROJECT_ID
gcloud compute firewall-rules delete allow-public-ssh-remote-dev --project=YOUR_PROJECT_ID
```

## Files

| File | Description |
|------|-------------|
| `config.env.example` | Template — copy to `config.env` and fill in your values |
| `provision.sh` | Creates GCP infrastructure and the VM; `--update-keys` pushes SSH key changes |
| `startup-script.sh` | Runs as root on first boot; sets up system packages and user environment |
| `ssh-config-example.txt` | Desktop client setup guide (SSH config, font, GitHub forwarding, VS Code) |
| `TERMIUS_IOS.md` | Termius on iPhone/iPad setup guide (keys, Mosh, tmux) |
| `authorized_keys` | Your per-device SSH public keys (gitignored; created on first run) |
