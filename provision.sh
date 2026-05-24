#!/usr/bin/env bash
# =============================================================================
# GCP Remote Dev VM — Provisioning Script
# Idempotent: safe to run multiple times.
#
# Usage:
#   1. Fill in config.env with your values
#   2. chmod +x provision.sh && ./provision.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# --- Helpers ---
log()  { echo ""; echo ">>> $*"; }
info() { echo "    $*"; }
ok()   { echo "    ✅ $*"; }
skip() { echo "    ⏭  Already exists — skipping: $*"; }
die()  { echo ""; echo "❌  ERROR: $*" >&2; exit 1; }

# =============================================================================
# 0. Validate config
# =============================================================================
[[ "$PROJECT_ID" != "YOUR_PROJECT_ID" ]]        || die "Set PROJECT_ID in config.env"
[[ "$IAP_USER"   != "YOUR_EMAIL@example.com" ]] || die "Set IAP_USER in config.env"
[[ "$VM_USER"    != "YOUR_USERNAME" ]]           || die "Set VM_USER in config.env"

log "GCP Remote Dev VM — Provisioning"
info "Project:         $PROJECT_ID"
info "VM Name:         $VM_NAME"
info "Region / Zone:   $REGION / $ZONE"
info "Network:         $NETWORK / subnet: $SUBNET"
info "Machine type:    $MACHINE_TYPE  |  Disk: ${BOOT_DISK_SIZE}GB ${BOOT_DISK_TYPE}"
info "VM user:         $VM_USER"
info "Service account: $SERVICE_ACCOUNT_EMAIL"
info "IAP user:        $IAP_USER"
info "Claude model:    $CLAUDE_MODEL  |  Vertex region: $VERTEX_REGION"
echo ""
read -rp "Proceed with provisioning? [y/N] " _confirm
[[ "${_confirm}" == "y" || "${_confirm}" == "Y" ]] || { echo "Aborted."; exit 0; }

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
    --quiet 2>/dev/null
  info "  Bound: $role"
done
ok "IAM roles bound."

# =============================================================================
# 4. Cloud Router (prerequisite for Cloud NAT)
# =============================================================================
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

# =============================================================================
# 5. Cloud NAT (outbound internet for the private VM)
# =============================================================================
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

# =============================================================================
# 6. Firewall rule — allow SSH only from IAP CIDR
# =============================================================================
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
    --no-address \
    --boot-disk-size="${BOOT_DISK_SIZE}GB" \
    --boot-disk-type="$BOOT_DISK_TYPE" \
    --image-family="ubuntu-2404-lts-amd64" \
    --image-project="ubuntu-os-cloud" \
    --service-account="$SERVICE_ACCOUNT_EMAIL" \
    --scopes="cloud-platform" \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --metadata="vm-user=${VM_USER},project-id=${PROJECT_ID},vertex-region=${VERTEX_REGION},claude-model=${CLAUDE_MODEL},ssh-public-key=${SSH_PUBLIC_KEY},enable-oslogin=false" \
    --metadata-from-file="startup-script=${SCRIPT_DIR}/startup-script.sh" \
    --project="$PROJECT_ID"
  ok "VM created. Startup script runs in background (~10 min). See progress:"
  info "  gcloud compute instances get-serial-port-output ${VM_NAME} --zone=${ZONE} --project=${PROJECT_ID} | grep '\\[startup\\]'"
else
  skip "$VM_NAME (zone: $ZONE)"
fi

# =============================================================================
# 8. Grant IAP tunnel access
# =============================================================================
log "IAP tunnel access: $IAP_USER"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:${IAP_USER}" \
  --role="roles/iap.tunnelResourceAccessor" \
  --condition=None \
  --quiet 2>/dev/null
ok "IAP tunnel access granted."

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
echo "2. Bootstrap SSH key (first time only):"
if [[ -n "$SSH_PUBLIC_KEY" ]]; then
echo "   SSH_PUBLIC_KEY was set — your key is already in authorized_keys."
else
echo "   Run once to upload your SSH key to the VM:"
echo "   gcloud compute ssh ${VM_NAME} --tunnel-through-iap --zone=${ZONE} --project=${PROJECT_ID}"
fi
echo ""
echo "3. Add the following to ~/.ssh/config on each client machine:"
echo "   (See ssh-config-example.txt for the full client setup guide)"
echo ""
echo "   Host ${VM_NAME}"
echo "     HostName ${VM_NAME}"
echo "     User ${VM_USER}"
echo "     IdentityFile ~/.ssh/google_compute_engine"
echo "     ForwardAgent yes"
echo "     ProxyCommand gcloud compute start-iap-tunnel %h %p \\"
echo "       --listen-on-stdin --zone=${ZONE} --project=${PROJECT_ID}"
echo "     StrictHostKeyChecking no"
echo "     UserKnownHostsFile /dev/null"
echo ""
echo "4. In VS Code: Remote Explorer → SSH → ${VM_NAME}"
echo ""
