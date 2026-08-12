# GCP Remote Dev VM

Quickly provisions a private GCP Compute Engine for remote development via SSH and VS Code. The VM has no public IP — access is exclusively through [Identity-Aware Proxy (IAP)](https://cloud.google.com/iap) tunneling. Antigravity CLI and Claude Code are pre-configured to authenticate via the VM's GCP service account (no API keys needed).

## What Gets Provisioned

**GCP infrastructure** (via `provision.sh`):
- Service account with minimal IAM roles (Vertex AI user, log writer, metric writer)
- Cloud Router + Cloud NAT for outbound internet (no public IP on the VM)
- Firewall rule allowing SSH only from IAP CIDR (`35.235.240.0/20`)
- Ubuntu 24.04 LTS VM (Shielded VM) with the startup script attached

**VM system setup** (via `startup-script.sh`, runs as root on first boot):
- System packages, unattended security upgrades
- Google Cloud CLI, Node.js 22 LTS, GitHub CLI
- Vertex AI environment variables for all users (`/etc/profile.d/ai-tools.sh`)

**User dev environment** (via `~/setup-user.sh`, run once after first SSH login):
- Claude Code CLI
- Antigravity CLI (`agy`)
- Oh My Zsh + Powerlevel10k theme + plugins (autosuggestions, syntax-highlighting)
- pyenv + pyenv-virtualenv

## Prerequisites

- [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed and authenticated (`gcloud auth login`)
- An existing GCP VPC network and subnet
- Sufficient IAM permissions to create VMs, service accounts, firewall rules, and Cloud NAT

## Quick Start

### 1. Configure

```bash
cp config.env.example config.env
# Edit config.env — fill in PROJECT_ID, VM_USER, NETWORK, SUBNET, IAP_USER
```

Key values to set in `config.env`:

| Variable | Description |
|----------|-------------|
| `PROJECT_ID` | Your GCP project ID |
| `VM_USER` | Linux username to create on the VM |
| `NETWORK` | Your VPC network name |
| `SUBNET` | Subnet name in `REGION` |
| `IAP_USER` | GCP user/group email to grant IAP tunnel access |
| `SSH_PUBLIC_KEY` | Optional — paste contents of your public key to skip bootstrap (see Step 4) |
| `CLAUDE_MODEL` | Claude model name (via Vertex AI) |

### 2. Provision

```bash
chmod +x provision.sh
./provision.sh
```

The script is idempotent — safe to run multiple times.

### 3. Wait for the startup script (~10 min)

Monitor progress from your local machine:

```bash
gcloud compute instances get-serial-port-output remote-dev \
  --zone=us-west1-b --project=YOUR_PROJECT_ID | grep '\[startup\]'
```

### 4. Bootstrap SSH key + set up the client

**First-time only — authorize your SSH key on the VM** (skip if you set `SSH_PUBLIC_KEY` in config.env):

```bash
gcloud compute ssh <VM_USER>@remote-dev \
  --tunnel-through-iap --zone=us-west1-b --project=YOUR_PROJECT_ID
```

This uploads `~/.ssh/google_compute_engine` to the VM's `authorized_keys`. After this, plain `ssh remote-dev` works via `~/.ssh/config`.

Then follow **`ssh-config-example.txt`** for the full client setup, including:
- Adding the IAP proxy entry (with `IdentityFile`) to `~/.ssh/config`
- Installing the MesloLGS NF font (required for Powerlevel10k)
- Configuring GitHub SSH agent forwarding
- Connecting via VS Code Remote SSH

### 5. First SSH login — complete user setup

```bash
bash ~/setup-user.sh   # runs once; takes ~5-10 minutes
exec zsh               # switch to the configured shell
```

## Security Notes

- The VM has **no public IP**; SSH is only reachable via IAP tunnel
- All third-party apt/npm repositories are added via signed GPG keys (no `curl | bash` as root)
- Vertex AI authentication uses the VM's service account — no API keys or credentials stored on the VM
- `SSH_PUBLIC_KEY` is optional — if not set, use `gcloud compute ssh` once to bootstrap key access

## Files

| File | Description |
|------|-------------|
| `config.env.example` | Template — copy to `config.env` and fill in your values |
| `provision.sh` | Creates GCP infrastructure and the VM |
| `startup-script.sh` | Runs as root on first boot; sets up system packages and user environment |
| `ssh-config-example.txt` | Client setup guide (SSH config, font, GitHub forwarding) |
