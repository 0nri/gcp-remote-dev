#!/usr/bin/env bash
# =============================================================================
# GCP Remote Dev VM — Provisioning Script
# Idempotent: safe to run multiple times.
#
# Usage:
#   1. Fill in config.env with your values
#   2. chmod +x provision.sh && ./provision.sh [--access=iap|public] [--tools=agy,claude]
#      Flags override ACCESS_MODE / INSTALL_TOOLS from config.env.
#   3. ./provision.sh --update-keys   # push SSH_KEYS_FILE to an existing VM
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# --- Helpers ---
CURRENT_STEP="startup"
log()  { CURRENT_STEP="$*"; echo ""; echo ">>> $*"; }
info() { echo "    $*"; }
ok()   { echo "    ✅ $*"; }
skip() { echo "    ⏭  Already exists — skipping: $*"; }
die()  { echo ""; echo "❌  ERROR: $*" >&2; exit 1; }

# Any unexpected command failure: say where, and that re-running is safe
# (every step checks for existing resources first). set -E makes the trap fire
# inside $(...) subshells too, so only report from the main shell (once).
trap '(( BASH_SUBSHELL == 0 )) && { echo "" >&2; echo "❌  Failed during: ${CURRENT_STEP} (line ${LINENO})." >&2; echo "    Fix the cause above and re-run ./provision.sh — completed steps are skipped." >&2; }' ERR

# Firewall rules are looked up by name only; make sure an existing rule is
# actually attached to NETWORK, otherwise it would silently not apply.
check_fw_network() {
  local fw_net
  fw_net=$(gcloud compute firewall-rules describe "$1" --project="$PROJECT_ID" \
    --format="value(network.basename())")
  [[ "$fw_net" == "$NETWORK" ]] || die "Firewall rule '$1' exists on network '${fw_net}', not '${NETWORK}'.
    Delete it (gcloud compute firewall-rules delete $1 --project=${PROJECT_ID}) and re-run."
}

# --- Defaults (older config.env files may not define these) ---
ACCESS_MODE="${ACCESS_MODE:-iap}"
INSTALL_TOOLS="${INSTALL_TOOLS:-agy}"
SSH_KEYS_FILE="${SSH_KEYS_FILE:-${SCRIPT_DIR}/authorized_keys}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SUBNET_RANGE="${SUBNET_RANGE:-10.10.0.0/24}"
UPDATE_KEYS=false

# --- CLI flags override config.env ---
for arg in "$@"; do
  case "$arg" in
    --access=*)    ACCESS_MODE="${arg#*=}" ;;
    --tools=*)     INSTALL_TOOLS="${arg#*=}" ;;
    --update-keys) UPDATE_KEYS=true ;;
    -h|--help)     echo "Usage: $0 [--access=iap|public] [--tools=agy,claude] | --update-keys"; exit 0 ;;
    *) die "Unknown argument: $arg (see --help)" ;;
  esac
done

# Public-mode resource names (derived here so existing config.env files keep working)
ADDRESS_NAME="${VM_NAME}-ip"
PUBLIC_FIREWALL_RULE_NAME="allow-public-ssh-${VM_NAME}"
PUBLIC_SSH_TAG="${VM_NAME}-public-ssh"
GENERATED_KEY="${HOME}/.ssh/${VM_NAME}_ed25519"

# --- SSH keys → GCE 'ssh-keys' metadata ---
# The google-guest-agent on the VM syncs 'ssh-keys' metadata into
# ~VM_USER/.ssh/authorized_keys continuously, so keys can be added/revoked
# at any time without SSH access. Format per line: "<user>:<public key>".
SSH_KEYS_TMP="$(mktemp)"
trap 'rm -f "$SSH_KEYS_TMP"' EXIT

build_ssh_keys() {
  # No keys configured anywhere → generate a dedicated key on THIS machine
  # (private key never leaves it) and record its public half in the keys file.
  if ! grep -qsvE '^[[:space:]]*(#|$)' "$SSH_KEYS_FILE" && [[ -z "$SSH_PUBLIC_KEY" ]]; then
    if [[ ! -f "$GENERATED_KEY" ]]; then
      log "No SSH keys configured — generating ${GENERATED_KEY}"
      mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
      ssh-keygen -t ed25519 -f "$GENERATED_KEY" -C "${VM_USER}@${VM_NAME}"
    fi
    # Create a self-documenting keys file on first run; otherwise just append.
    if [[ ! -s "$SSH_KEYS_FILE" ]]; then
      cat > "$SSH_KEYS_FILE" <<EOF
# Public SSH keys allowed to log in to ${VM_NAME} as ${VM_USER} — one line per device.
# After editing, push the change with:  ./provision.sh --update-keys
# To revoke a device, delete its line and run --update-keys again.

# This machine ($(hostname -s)) — private key: ${GENERATED_KEY}
EOF
      cat "${GENERATED_KEY}.pub" >> "$SSH_KEYS_FILE"
      cat >> "$SSH_KEYS_FILE" <<'EOF'

# iPhone/iPad (Termius): Keychain → your key → copy PUBLIC key, paste on the next line
EOF
    else
      cat "${GENERATED_KEY}.pub" >> "$SSH_KEYS_FILE"
    fi
    ok "Added ${GENERATED_KEY}.pub to ${SSH_KEYS_FILE}"
  fi

  : > "$SSH_KEYS_TMP"
  if [[ -f "$SSH_KEYS_FILE" ]]; then
    # Skip blank lines and comments; prefix each key with the VM username.
    grep -vE '^[[:space:]]*(#|$)' "$SSH_KEYS_FILE" | sed "s|^|${VM_USER}:|" >> "$SSH_KEYS_TMP" || true
  fi
  [[ -n "$SSH_PUBLIC_KEY" ]] && echo "${VM_USER}:${SSH_PUBLIC_KEY}" >> "$SSH_KEYS_TMP"
  [[ -s "$SSH_KEYS_TMP" ]] || die "No SSH public keys found (SSH_KEYS_FILE=${SSH_KEYS_FILE})"
  info "SSH keys authorized for ${VM_USER}: $(wc -l < "$SSH_KEYS_TMP" | tr -d ' ')"
}

# =============================================================================
# 0. Validate config
# =============================================================================
[[ "$PROJECT_ID" != "YOUR_PROJECT_ID" ]]        || die "Set PROJECT_ID in config.env"
[[ "$VM_USER"    != "YOUR_USERNAME" ]]           || die "Set VM_USER in config.env"

# --update-keys: replace the VM's ssh-keys metadata with SSH_KEYS_FILE, then exit.
if [[ "$UPDATE_KEYS" == "true" ]]; then
  log "Updating SSH keys on ${VM_NAME}..."
  build_ssh_keys
  gcloud compute instances add-metadata "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --metadata-from-file="ssh-keys=${SSH_KEYS_TMP}"
  ok "SSH keys updated (guest agent syncs them within seconds)."
  exit 0
fi

[[ "$ACCESS_MODE" == "iap" || "$ACCESS_MODE" == "public" ]] \
  || die "ACCESS_MODE must be 'iap' or 'public' (got '$ACCESS_MODE')"
if [[ "$ACCESS_MODE" == "iap" ]]; then
  [[ "$IAP_USER" != "YOUR_EMAIL@example.com" ]] || die "Set IAP_USER in config.env"
fi

# Split INSTALL_TOOLS (comma-separated) into per-tool booleans. Separate
# metadata keys are used because gcloud --metadata treats commas as delimiters.
INSTALL_AGY=false
INSTALL_CLAUDE=false
IFS=',' read -ra _tools <<< "$INSTALL_TOOLS"
for t in "${_tools[@]}"; do
  case "${t// /}" in
    agy)    INSTALL_AGY=true ;;
    claude) INSTALL_CLAUDE=true ;;
    "")     ;;
    *)      die "Unknown tool in INSTALL_TOOLS: '$t' (valid: agy, claude)" ;;
  esac
done

log "GCP Remote Dev VM — Provisioning"
info "Project:         $PROJECT_ID"
info "VM Name:         $VM_NAME"
info "Region / Zone:   $REGION / $ZONE"
info "Network:         $NETWORK / subnet: $SUBNET"
info "Machine type:    $MACHINE_TYPE  |  Disk: ${BOOT_DISK_SIZE}GB ${BOOT_DISK_TYPE}"
info "VM user:         $VM_USER"
info "Service account: $SERVICE_ACCOUNT_EMAIL"
info "Access mode:     $ACCESS_MODE"
[[ "$ACCESS_MODE" == "iap" ]] && info "IAP user:        $IAP_USER"
info "AI tools:        agy=${INSTALL_AGY}  claude=${INSTALL_CLAUDE}"
info "SSH keys file:   $SSH_KEYS_FILE"
info "Claude model:    $CLAUDE_MODEL  |  Vertex region: $VERTEX_REGION"
echo ""
read -rp "Proceed with provisioning? [y/N] " _confirm
[[ "${_confirm}" == "y" || "${_confirm}" == "Y" ]] || { echo "Aborted."; exit 0; }

build_ssh_keys

# =============================================================================
# 1. Configure gcloud project
# =============================================================================
log "Setting active project..."
gcloud config set project "$PROJECT_ID" --quiet
ok "Active project: $PROJECT_ID"

# =============================================================================
# 2. Enable required APIs
# =============================================================================
log "Enabling required APIs..."
gcloud services enable \
  compute.googleapis.com \
  iap.googleapis.com \
  aiplatform.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet
ok "APIs enabled."

# =============================================================================
# 2b. Preflight — validate location/network BEFORE creating anything
# =============================================================================
log "Preflight checks..."
_zone_region=$(gcloud compute zones describe "$ZONE" --project="$PROJECT_ID" \
  --format="value(region.basename())" 2>/dev/null) || die "Zone '${ZONE}' not found."
[[ "$_zone_region" == "$REGION" ]] || die "ZONE '${ZONE}' is in region '${_zone_region}', not REGION '${REGION}'."
gcloud compute machine-types describe "$MACHINE_TYPE" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null \
  || die "Machine type '${MACHINE_TYPE}' is not available in ${ZONE}."
ok "Zone ${ZONE} (region ${REGION}), machine type ${MACHINE_TYPE}."

if ! gcloud compute networks describe "$NETWORK" --project="$PROJECT_ID" &>/dev/null; then
  # Brand-new network: nothing can conflict, so offer to create it + the subnet.
  info "Network '${NETWORK}' does not exist. Existing networks:"
  gcloud compute networks list --project="$PROJECT_ID" --format="value(name)" | sed 's/^/      /'
  read -rp "    Create custom VPC '${NETWORK}' with subnet '${SUBNET}' (${SUBNET_RANGE}) in ${REGION}? [y/N] " _mk
  [[ "${_mk}" == "y" || "${_mk}" == "Y" ]] || die "Set NETWORK/SUBNET in config.env to an existing network, or allow creation."
  gcloud compute networks create "$NETWORK" --subnet-mode=custom --project="$PROJECT_ID"
  gcloud compute networks subnets create "$SUBNET" \
    --network="$NETWORK" --region="$REGION" --range="$SUBNET_RANGE" \
    --enable-private-ip-google-access --project="$PROJECT_ID"
  ok "Created network ${NETWORK} + subnet ${SUBNET} (${SUBNET_RANGE})."
else
  # Existing network: never add subnets to it (ranges may overlap peering/VPN
  # routes we can't see) — validate and list valid choices instead.
  _subnet_net=$(gcloud compute networks subnets describe "$SUBNET" --region="$REGION" \
    --project="$PROJECT_ID" --format="value(network.basename())" 2>/dev/null || true)
  if [[ "$_subnet_net" != "$NETWORK" ]]; then
    echo "" >&2
    if [[ -z "$_subnet_net" ]]; then
      echo "❌  Subnet '${SUBNET}' not found in ${REGION}." >&2
    else
      echo "❌  Subnet '${SUBNET}' belongs to network '${_subnet_net}', not '${NETWORK}'." >&2
    fi
    echo "    Subnets of network '${NETWORK}' in ${REGION}:" >&2
    gcloud compute networks subnets list --project="$PROJECT_ID" \
      --network="$NETWORK" --regions="$REGION" \
      --format="value(name,ipCidrRange)" | sed 's/^/      /' >&2
    exit 1
  fi
  ok "Network ${NETWORK} / subnet ${SUBNET} found."
fi

# =============================================================================
# 3. Service account
# =============================================================================
log "Service account: $SERVICE_ACCOUNT_NAME"
if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" \
    --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
    --display-name="Remote Dev VM — ${VM_NAME}" \
    --project="$PROJECT_ID"
  ok "Service account created."
else
  skip "$SERVICE_ACCOUNT_EMAIL"
fi

log "Binding IAM roles..."
for role in \
  "roles/aiplatform.user" \
  "roles/logging.logWriter" \
  "roles/monitoring.metricWriter"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
  info "  Bound: $role"
done
ok "IAM roles bound."

if [[ "$ACCESS_MODE" == "iap" ]]; then
  # ===========================================================================
  # 4. Cloud Router (prerequisite for Cloud NAT) — IAP mode only
  # ===========================================================================
  log "Cloud Router: $ROUTER_NAME"
  if ! gcloud compute routers describe "$ROUTER_NAME" \
      --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute routers create "$ROUTER_NAME" \
      --network="$NETWORK" \
      --region="$REGION" \
      --project="$PROJECT_ID"
    ok "Cloud Router created."
  else
    skip "$ROUTER_NAME"
  fi

  # ===========================================================================
  # 5. Cloud NAT (outbound internet for the private VM) — IAP mode only
  # ===========================================================================
  log "Cloud NAT: $NAT_GW_NAME"
  if ! gcloud compute routers nats describe "$NAT_GW_NAME" \
      --router="$ROUTER_NAME" \
      --region="$REGION" \
      --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute routers nats create "$NAT_GW_NAME" \
      --router="$ROUTER_NAME" \
      --region="$REGION" \
      --auto-allocate-nat-external-ips \
      --nat-all-subnet-ip-ranges \
      --project="$PROJECT_ID"
    ok "Cloud NAT created."
  else
    skip "$NAT_GW_NAME"
  fi

  # ===========================================================================
  # 6. Firewall rule — allow SSH only from IAP CIDR
  # ===========================================================================
  log "Firewall rule: $FIREWALL_RULE_NAME"
  if ! gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" \
      --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
      --network="$NETWORK" \
      --direction=INGRESS \
      --priority=1000 \
      --action=ALLOW \
      --rules=tcp:22 \
      --source-ranges="35.235.240.0/20" \
      --description="Allow SSH from IAP tunnels (${NETWORK})" \
      --project="$PROJECT_ID"
    ok "Firewall rule created (IAP CIDR → port 22)."
  else
    skip "$FIREWALL_RULE_NAME"
    check_fw_network "$FIREWALL_RULE_NAME"
  fi

  NET_FLAGS=(--no-address)
else
  # ===========================================================================
  # 6. Firewall rule — public SSH, scoped by target tag to this VM only
  # ===========================================================================
  log "Firewall rule: $PUBLIC_FIREWALL_RULE_NAME"
  if ! gcloud compute firewall-rules describe "$PUBLIC_FIREWALL_RULE_NAME" \
      --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute firewall-rules create "$PUBLIC_FIREWALL_RULE_NAME" \
      --network="$NETWORK" \
      --direction=INGRESS \
      --priority=1000 \
      --action=ALLOW \
      --rules=tcp:22,udp:60000-60010 \
      --source-ranges="0.0.0.0/0" \
      --target-tags="$PUBLIC_SSH_TAG" \
      --description="Allow public SSH + Mosh to ${VM_NAME} (tag: ${PUBLIC_SSH_TAG})" \
      --project="$PROJECT_ID"
    ok "Firewall rule created (0.0.0.0/0 → tcp:22 + udp:60000-60010, tag ${PUBLIC_SSH_TAG} only)."
  else
    skip "$PUBLIC_FIREWALL_RULE_NAME"
    check_fw_network "$PUBLIC_FIREWALL_RULE_NAME"
  fi

  # ===========================================================================
  # 6b. Reserved static external IP — public mode only
  # ===========================================================================
  log "Static external IP: $ADDRESS_NAME"
  if ! gcloud compute addresses describe "$ADDRESS_NAME" \
      --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute addresses create "$ADDRESS_NAME" \
      --region="$REGION" \
      --project="$PROJECT_ID"
    ok "Static IP reserved."
  else
    skip "$ADDRESS_NAME"
  fi
  EXTERNAL_IP=$(gcloud compute addresses describe "$ADDRESS_NAME" \
    --region="$REGION" --project="$PROJECT_ID" --format="value(address)")
  info "External IP: $EXTERNAL_IP"

  NET_FLAGS=(--address="$EXTERNAL_IP" --tags="$PUBLIC_SSH_TAG")
fi

# =============================================================================
# 7. VM instance
# =============================================================================
log "VM instance: $VM_NAME"
if ! gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --network="$NETWORK" \
    --subnet="$SUBNET" \
    "${NET_FLAGS[@]}" \
    --boot-disk-size="${BOOT_DISK_SIZE}GB" \
    --boot-disk-type="$BOOT_DISK_TYPE" \
    --image-family="ubuntu-2404-lts-amd64" \
    --image-project="ubuntu-os-cloud" \
    --service-account="$SERVICE_ACCOUNT_EMAIL" \
    --scopes="cloud-platform" \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --metadata="vm-user=${VM_USER},project-id=${PROJECT_ID},vertex-region=${VERTEX_REGION},claude-model=${CLAUDE_MODEL},install-agy=${INSTALL_AGY},install-claude=${INSTALL_CLAUDE},access-mode=${ACCESS_MODE},enable-oslogin=false,enable-guest-attributes=TRUE" \
    --metadata-from-file="startup-script=${SCRIPT_DIR}/startup-script.sh,ssh-keys=${SSH_KEYS_TMP}" \
    --project="$PROJECT_ID"
  ok "VM created. Startup script runs in background (~10 min) — see Next steps below."
else
  skip "$VM_NAME (zone: $ZONE)"
  info "    (SSH key changes are not applied to existing VMs — use ./provision.sh --update-keys)"
  # Existing VMs are not modified — warn if their network setup doesn't match ACCESS_MODE.
  _nat_ip=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
  if [[ "$ACCESS_MODE" == "iap" && -n "$_nat_ip" ]] || \
     [[ "$ACCESS_MODE" == "public" && -z "$_nat_ip" ]]; then
    info "⚠️  WARNING: existing VM does not match ACCESS_MODE=${ACCESS_MODE} (external IP: '${_nat_ip:-none}')."
    info "    Delete and re-provision the VM to switch access modes."
  fi
fi

# =============================================================================
# 8. Grant IAP tunnel access — IAP mode only
# =============================================================================
if [[ "$ACCESS_MODE" == "iap" ]]; then
  log "IAP tunnel access: $IAP_USER"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="user:${IAP_USER}" \
    --role="roles/iap.tunnelResourceAccessor" \
    --condition=None \
    --quiet >/dev/null
  ok "IAP tunnel access granted."
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo "======================================================================"
echo "✅  Provisioning complete!"
echo "======================================================================"
echo ""
echo "Next steps:"
echo ""
echo "1. Wait ~10 minutes for the startup script to finish."
echo "   Monitor progress:"
echo "   gcloud compute instances get-serial-port-output ${VM_NAME} \\"
echo "     --zone=${ZONE} --project=${PROJECT_ID} | grep '\\[startup\\]'"
echo ""
echo "2. SSH keys: every public key in ${SSH_KEYS_FILE} is authorized for ${VM_USER}."
echo "   To add a device later (e.g. Termius on iOS), append its public key there and run:"
echo "   ./provision.sh --update-keys"
echo ""
if [[ -f "$GENERATED_KEY" ]]; then
  _identity="$GENERATED_KEY"
else
  _identity="<path to the private key matching one in ${SSH_KEYS_FILE}>"
fi
echo "3. Add the following to ~/.ssh/config on each client machine:"
echo "   (See ssh-config-example.txt for the full client setup guide)"
echo ""
echo "   Host ${VM_NAME}"
if [[ "$ACCESS_MODE" == "iap" ]]; then
echo "     HostName ${VM_NAME}"
echo "     User ${VM_USER}"
echo "     IdentityFile ${_identity}"
echo "     IdentitiesOnly yes"
echo "     ForwardAgent yes"
echo "     ProxyCommand gcloud compute start-iap-tunnel %h %p \\"
echo "       --listen-on-stdin --zone=${ZONE} --project=${PROJECT_ID}"
echo "     StrictHostKeyChecking no"
echo "     UserKnownHostsFile /dev/null"
else
echo "     HostName ${EXTERNAL_IP}"
echo "     User ${VM_USER}"
echo "     IdentityFile ${_identity}"
echo "     IdentitiesOnly yes"
echo "     ForwardAgent yes"
echo ""
echo "   Mosh (UDP 60000-60010) is open:  mosh ${VM_NAME}"
echo "   iPhone/iPad: see TERMIUS_IOS.md"
echo ""
echo "   Note: the static IP '${ADDRESS_NAME}' is billed while reserved and is NOT"
echo "   deleted with the VM. To release it:"
echo "   gcloud compute addresses delete ${ADDRESS_NAME} --region=${REGION} --project=${PROJECT_ID}"
fi
echo ""
echo "4. In VS Code: Remote Explorer → SSH → ${VM_NAME}"
echo ""
