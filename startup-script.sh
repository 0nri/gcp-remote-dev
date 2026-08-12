#!/usr/bin/env bash
# =============================================================================
# GCP Remote Dev VM — System Startup Script
# Runs as ROOT on first boot only (sentinel file prevents re-runs on restart).
# Only performs system-level tasks. User-space setup lives in ~/setup-user.sh.
# =============================================================================

set -euo pipefail

LOG_FILE="/var/log/startup-script.log"
SENTINEL_FILE="/etc/remote-dev-setup.done"

log() { echo "[startup $(date '+%Y-%m-%dT%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
# Sentinel check — exit immediately on subsequent VM boots
# =============================================================================
if [[ -f "$SENTINEL_FILE" ]]; then
  log "System already configured (${SENTINEL_FILE} exists). Skipping."
  exit 0
fi

log "======================================================================"
log "Starting VM system setup (first boot)"
log "======================================================================"

# =============================================================================
# 1. Read configuration from GCP instance metadata
# =============================================================================
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
get_meta() {
  curl -sf "${METADATA_URL}/$1" -H "Metadata-Flavor: Google" 2>/dev/null || echo "${2:-}"
}

VM_USER=$(get_meta "vm-user" "user")
PROJECT_ID=$(get_meta "project-id" "")
VERTEX_REGION=$(get_meta "vertex-region" "global")
CLAUDE_MODEL=$(get_meta "claude-model" "claude-opus-4-7")
SSH_PUBLIC_KEY=$(get_meta "ssh-public-key" "")
USER_HOME="/home/${VM_USER}"

log "Config: user=${VM_USER}  project=${PROJECT_ID}  vertex=${VERTEX_REGION}  claude=${CLAUDE_MODEL}"

# =============================================================================
# 2. Wait for metadata server (available before external network is ready)
# =============================================================================
log "Confirming metadata server reachable..."
for i in $(seq 1 12); do
  if curl -sf --connect-timeout 3 "http://metadata.google.internal/" \
      -H "Metadata-Flavor: Google" &>/dev/null; then
    log "  Metadata server reachable."
    break
  fi
  log "  Waiting for metadata server... (${i}/12)"
  sleep 5
done

# =============================================================================
# 3. Wait for apt lock (cloud-init may hold it briefly on first boot)
# =============================================================================
log "Waiting for apt lock..."
for i in $(seq 1 36); do
  if ! fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; then
    log "  apt lock available."
    break
  fi
  log "  apt lock held, waiting 5s... (${i}/36)"
  sleep 5
done

# =============================================================================
# 4. System packages
# =============================================================================
export DEBIAN_FRONTEND=noninteractive

log "Updating system packages..."
apt-get update -y
apt-get upgrade -y

log "Installing base system packages..."
apt-get install -y \
  curl wget git build-essential pkg-config \
  zsh jq unzip vim \
  python3 python3-pip python3-venv \
  make gcc libssl-dev libffi-dev \
  libreadline-dev libbz2-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev \
  liblzma-dev libgdbm-dev libnss3-dev \
  ca-certificates gnupg apt-transport-https \
  software-properties-common
log "Base packages installed."

# =============================================================================
# 5. Automatic security updates (unattended-upgrades)
# =============================================================================
log "Configuring unattended-upgrades..."
apt-get install -y unattended-upgrades

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT_EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades-custom <<'APT_EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APT_EOF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
log "Unattended-upgrades configured (daily security patches, no auto-reboot)."

# =============================================================================
# 6. Create VM user with zsh as default shell
# =============================================================================
log "Setting up user: ${VM_USER}..."
ZSH_BIN="$(which zsh)"

if ! id -u "$VM_USER" &>/dev/null; then
  useradd -m -s "$ZSH_BIN" -G sudo "$VM_USER"
  log "  User ${VM_USER} created with zsh shell."
else
  usermod -s "$ZSH_BIN" "$VM_USER"
  usermod -aG sudo "$VM_USER"
  log "  User ${VM_USER} already exists — updated shell and groups."
fi

# Passwordless sudo for personal dev VM
echo "${VM_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${VM_USER}"
chmod 440 "/etc/sudoers.d/${VM_USER}"
visudo -c -f "/etc/sudoers.d/${VM_USER}"
log "  Passwordless sudo configured and validated."

# Write SSH public key to authorized_keys if provided via metadata
if [[ -n "$SSH_PUBLIC_KEY" ]]; then
  mkdir -p "${USER_HOME}/.ssh"
  chmod 700 "${USER_HOME}/.ssh"
  echo "$SSH_PUBLIC_KEY" >> "${USER_HOME}/.ssh/authorized_keys"
  chmod 600 "${USER_HOME}/.ssh/authorized_keys"
  chown -R "${VM_USER}:${VM_USER}" "${USER_HOME}/.ssh"
  log "  SSH public key written to ${USER_HOME}/.ssh/authorized_keys."
else
  log "  No SSH_PUBLIC_KEY in metadata — use 'gcloud compute ssh ${VM_USER}@${VM_NAME}' to bootstrap key."
fi

# =============================================================================
# 7. Google Cloud CLI (via signed apt repository)
# =============================================================================
log "Installing Google Cloud CLI..."
if ! command -v gcloud &>/dev/null; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update -y
  apt-get install -y google-cloud-cli
  log "  gcloud installed: $(gcloud --version | head -1)"
else
  log "  gcloud already installed — skipping."
fi

# =============================================================================
# 8. Node.js 22 LTS (via signed apt repo — no curl|bash as root)
# =============================================================================
log "Installing Node.js 22 LTS..."
if ! command -v node &>/dev/null; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] \
https://deb.nodesource.com/node_22.x nodistro main" \
    | tee /etc/apt/sources.list.d/nodesource.list
  apt-get update -y
  apt-get install -y nodejs
  log "  Node.js $(node --version) / npm $(npm --version) installed."
else
  log "  Node.js already installed — skipping."
fi

# =============================================================================
# 9. GitHub CLI (via signed apt repository)
# =============================================================================
log "Installing GitHub CLI (gh)..."
if ! command -v gh &>/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list
  apt-get update -y
  apt-get install -y gh
  log "  gh $(gh --version | head -1) installed."
else
  log "  gh already installed — skipping."
fi

# =============================================================================
# 10. AI tool environment variables (Vertex AI config for all users)
# =============================================================================
log "Writing Vertex AI environment variables to /etc/profile.d/ai-tools.sh..."
cat > /etc/profile.d/ai-tools.sh <<EOF
# AI tool configuration — managed by remote-dev setup script
# Do not edit manually; re-run provision.sh to update.

# ── Antigravity CLI (Vertex AI) ──────────────────────────────────────────────
export GOOGLE_CLOUD_PROJECT="${PROJECT_ID}"
export GOOGLE_CLOUD_LOCATION="${VERTEX_REGION}"
export GOOGLE_GENAI_USE_VERTEXAI="true"

# ── Claude Code (Vertex AI) ───────────────────────────────────────────────────
export ANTHROPIC_VERTEX_PROJECT_ID="${PROJECT_ID}"
export CLOUD_ML_REGION="${VERTEX_REGION}"
export CLAUDE_CODE_USE_VERTEX="1"
export CLAUDE_MODEL="${CLAUDE_MODEL}"
EOF
chmod 644 /etc/profile.d/ai-tools.sh
log "  Vertex AI env vars configured for all users."

# =============================================================================
# 11. Write setup-user.sh to VM user's home (runs as VM_USER on first SSH login)
# =============================================================================
log "Writing ${USER_HOME}/setup-user.sh..."

cat > "${USER_HOME}/setup-user.sh" << 'SETUP_USER_EOF'
#!/usr/bin/env bash
# =============================================================================
# Dev Environment Setup — runs as VM_USER (non-root), once on first SSH login.
# Usage: bash ~/setup-user.sh
# =============================================================================

set -euo pipefail

DONE_FILE="$HOME/.setup-done"
log() { echo "[setup $(date '+%H:%M:%S')] $*"; }

if [[ -f "$DONE_FILE" ]]; then
  echo "Dev environment already configured. Nothing to do."
  echo "(Delete ~/.setup-done to re-run)"
  exit 0
fi

log "Starting dev environment setup for $(whoami)..."
log "This will take approximately 5-10 minutes."
echo ""

# =============================================================================
# 1. Claude Code (installed as user — limits blast radius of curl|bash)
# =============================================================================
log "Installing Claude Code..."
if ! command -v claude &>/dev/null && [[ ! -f "$HOME/.local/bin/claude" ]]; then
  curl -fsSL https://claude.ai/install.sh | bash
  log "  Claude Code installed."
else
  log "  Claude Code already installed — skipping."
fi

# Add ~/.local/bin to PATH for this session if needed
if [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

# =============================================================================
# 2. Antigravity CLI (installed as user — limits blast radius of curl|bash)
# =============================================================================
log "Installing Antigravity CLI..."
if ! command -v agy &>/dev/null && [[ ! -f "$HOME/.local/bin/agy" ]]; then
  curl -fsSL https://antigravity.google/cli/install.sh | bash
  log "  Antigravity CLI installed."
else
  log "  Antigravity CLI already installed — skipping."
fi

# =============================================================================
# 3. Oh My Zsh (no shell change — shell already set to zsh via useradd)
# =============================================================================
log "Installing Oh My Zsh..."
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  log "  Oh My Zsh installed."
else
  log "  Oh My Zsh already installed — skipping."
fi

OMZ_CUSTOM="$HOME/.oh-my-zsh/custom"

# =============================================================================
# 4. Powerlevel10k theme
# =============================================================================
log "Installing Powerlevel10k..."
if [[ ! -d "${OMZ_CUSTOM}/themes/powerlevel10k" ]]; then
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    "${OMZ_CUSTOM}/themes/powerlevel10k"
  log "  Powerlevel10k installed."
else
  log "  Powerlevel10k already installed — skipping."
fi

# =============================================================================
# 5. zsh-autosuggestions
# =============================================================================
log "Installing zsh-autosuggestions..."
if [[ ! -d "${OMZ_CUSTOM}/plugins/zsh-autosuggestions" ]]; then
  git clone https://github.com/zsh-users/zsh-autosuggestions \
    "${OMZ_CUSTOM}/plugins/zsh-autosuggestions"
  log "  zsh-autosuggestions installed."
else
  log "  zsh-autosuggestions already installed — skipping."
fi

# =============================================================================
# 6. zsh-syntax-highlighting
# =============================================================================
log "Installing zsh-syntax-highlighting..."
if [[ ! -d "${OMZ_CUSTOM}/plugins/zsh-syntax-highlighting" ]]; then
  git clone https://github.com/zsh-users/zsh-syntax-highlighting \
    "${OMZ_CUSTOM}/plugins/zsh-syntax-highlighting"
  log "  zsh-syntax-highlighting installed."
else
  log "  zsh-syntax-highlighting already installed — skipping."
fi

# =============================================================================
# 7. pyenv + pyenv-virtualenv
# =============================================================================
log "Installing pyenv..."
if [[ ! -d "$HOME/.pyenv" ]]; then
  git clone https://github.com/pyenv/pyenv.git "$HOME/.pyenv"
  git clone https://github.com/pyenv/pyenv-virtualenv.git \
    "$HOME/.pyenv/plugins/pyenv-virtualenv"
  log "  pyenv + pyenv-virtualenv installed."
else
  log "  pyenv already installed — skipping."
fi

# =============================================================================
# 8. Write full .zshrc
# =============================================================================
log "Writing ~/.zshrc..."
cat > "$HOME/.zshrc" << 'ZSHRC_EOF'
# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Theme — Powerlevel10k
ZSH_THEME="powerlevel10k/powerlevel10k"

# Plugins
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
  poetry
  gcloud
)

source $ZSH/oh-my-zsh.sh

# ── pyenv ─────────────────────────────────────────────────────────────────────
export PYENV_ROOT="$HOME/.pyenv"
command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
if command -v pyenv virtualenv-init >/dev/null; then
  eval "$(pyenv virtualenv-init -)"
fi

# ── Claude Code (installed to ~/.local/bin) ────────────────────────────────
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"

# ── AI tool environment (Vertex AI) ───────────────────────────────────────────
[[ -f /etc/profile.d/ai-tools.sh ]] && source /etc/profile.d/ai-tools.sh

# ── Powerlevel10k config ──────────────────────────────────────────────────────
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
ZSHRC_EOF

log "  .zshrc written."

# =============================================================================
# 9. Write .p10k.zsh (verbatim config from Mac)
# =============================================================================
log "Writing ~/.p10k.zsh..."
cat > "$HOME/.p10k.zsh" << 'P10K_EOF'
# Generated by Powerlevel10k configuration wizard on 2025-12-30 at 20:52 HKT.
# Based on romkatv/powerlevel10k/config/p10k-lean.zsh, checksum 37983.
# Wizard options: compatible, unicode, lean, 1 line, sparse, concise,
# instant_prompt=verbose.
# Type `p10k configure` to generate another config.
#
# Config for Powerlevel10k with lean prompt style. Type `p10k configure` to generate
# your own config based on it.
#
# Tip: Looking for a nice color? Here's a one-liner to print colormap.
#
#   for i in {0..255}; do print -Pn "%K{$i}  %k%F{$i}${(l:3::0:)i}%f " ${${(M)$((i%6)):#3}:+$'\n'}; done

# Temporarily change options.
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob

  # Unset all configuration options. This allows you to apply configuration changes without
  # restarting zsh. Edit ~/.p10k.zsh and type `source ~/.p10k.zsh`.
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  # Zsh >= 5.1 is required.
  [[ $ZSH_VERSION == (5.<1->*|<6->.*) ]] || return

  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    # os_icon               # os identifier
    dir                     # current directory
    vcs                     # git status
    prompt_char             # prompt symbol
  )

  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status                  # exit code of the last command
    command_execution_time  # duration of the last command
    background_jobs         # presence of background jobs
    direnv                  # direnv status (https://direnv.net/)
    asdf                    # asdf version manager (https://github.com/asdf-vm/asdf)
    virtualenv              # python virtual environment (https://docs.python.org/3/library/venv.html)
    anaconda                # conda environment (https://conda.io/)
    pyenv                   # python environment (https://github.com/pyenv/pyenv)
    goenv                   # go environment (https://github.com/syndbg/goenv)
    nodenv                  # node.js version from nodenv (https://github.com/nodenv/nodenv)
    nvm                     # node.js version from nvm (https://github.com/nvm-sh/nvm)
    nodeenv                 # node.js environment (https://github.com/ekalinin/nodeenv)
    # node_version          # node.js version
    # go_version            # go version (https://golang.org)
    # rust_version          # rustc version (https://www.rust-lang.org)
    # dotnet_version        # .NET version (https://dotnet.microsoft.com)
    # php_version           # php version (https://www.php.net/)
    # laravel_version       # laravel php framework version (https://laravel.com/)
    # java_version          # java version (https://www.java.com/)
    # package               # name@version from package.json (https://docs.npmjs.com/files/package.json)
    rbenv                   # ruby version from rbenv (https://github.com/rbenv/rbenv)
    rvm                     # ruby version from rvm (https://rvm.io)
    fvm                     # flutter version management (https://github.com/leoafarias/fvm)
    luaenv                  # lua version from luaenv (https://github.com/cehoffman/luaenv)
    jenv                    # java version from jenv (https://github.com/jenv/jenv)
    plenv                   # perl version from plenv (https://github.com/tokuhirom/plenv)
    perlbrew                # perl version from perlbrew (https://github.com/gugod/App-perlbrew)
    phpenv                  # php version from phpenv (https://github.com/phpenv/phpenv)
    scalaenv                # scala version from scalaenv (https://github.com/scalaenv/scalaenv)
    haskell_stack           # haskell version from stack (https://haskellstack.org/)
    kubecontext             # current kubernetes context (https://kubernetes.io/)
    terraform               # terraform workspace (https://www.terraform.io)
    # terraform_version     # terraform version (https://www.terraform.io)
    aws                     # aws profile (https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-profiles.html)
    aws_eb_env              # aws elastic beanstalk environment (https://aws.amazon.com/elasticbeanstalk/)
    azure                   # azure account name (https://docs.microsoft.com/en-us/cli/azure)
    gcloud                  # google cloud cli account and project (https://cloud.google.com/)
    google_app_cred         # google application credentials (https://cloud.google.com/docs/authentication/production)
    toolbox                 # toolbox name (https://github.com/containers/toolbox)
    context                 # user@hostname
    nordvpn                 # nordvpn connection status, linux only (https://nordvpn.com/)
    ranger                  # ranger shell (https://github.com/ranger/ranger)
    yazi                    # yazi shell (https://github.com/sxyazi/yazi)
    nnn                     # nnn shell (https://github.com/jarun/nnn)
    lf                      # lf shell (https://github.com/gokcehan/lf)
    xplr                    # xplr shell (https://github.com/sayanarijit/xplr)
    vim_shell               # vim shell indicator (:sh)
    midnight_commander      # midnight commander shell (https://midnight-commander.org/)
    nix_shell               # nix shell (https://nixos.org/nixos/nix-pills/developing-with-nix-shell.html)
    chezmoi_shell           # chezmoi shell (https://www.chezmoi.io/)
    # vpn_ip                # virtual private network indicator
    # load                  # CPU load
    # disk_usage            # disk usage
    # ram                   # free RAM
    # swap                  # used swap
    todo                    # todo items (https://github.com/todotxt/todo.txt-cli)
    timewarrior             # timewarrior tracking status (https://timewarrior.net/)
    taskwarrior             # taskwarrior task count (https://taskwarrior.org/)
    per_directory_history   # Oh My Zsh per-directory-history local/global indicator
    # cpu_arch              # CPU architecture
    # time                  # current time
    # ip                    # ip address and bandwidth usage for a specified network interface
    # public_ip             # public IP address
    # proxy                 # system-wide http/https/ftp proxy
    # battery               # internal battery
    # wifi                  # wifi speed
    # example               # example user-defined segment (see prompt_example function below)
  )

  typeset -g POWERLEVEL9K_MODE=compatible
  typeset -g POWERLEVEL9K_ICON_PADDING=none
  typeset -g POWERLEVEL9K_BACKGROUND=
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_{LEFT,RIGHT}_WHITESPACE=
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_SUBSEGMENT_SEPARATOR=' '
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_SEGMENT_SEPARATOR=
  typeset -g POWERLEVEL9K_ICON_BEFORE_CONTENT=true
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX=
  typeset -g POWERLEVEL9K_MULTILINE_NEWLINE_PROMPT_PREFIX=
  typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX=
  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_SUFFIX=
  typeset -g POWERLEVEL9K_MULTILINE_NEWLINE_PROMPT_SUFFIX=
  typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_SUFFIX=
  typeset -g POWERLEVEL9K_LEFT_PROMPT_FIRST_SEGMENT_START_SYMBOL=
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_LAST_SEGMENT_END_SYMBOL=
  typeset -g POWERLEVEL9K_SHOW_RULER=false
  typeset -g POWERLEVEL9K_RULER_CHAR='─'
  typeset -g POWERLEVEL9K_RULER_FOREGROUND=242
  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_CHAR=' '
  if [[ $POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_CHAR != ' ' ]]; then
    typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_FOREGROUND=242
    typeset -g POWERLEVEL9K_LEFT_PROMPT_LAST_SEGMENT_END_SYMBOL=' '
    typeset -g POWERLEVEL9K_RIGHT_PROMPT_FIRST_SEGMENT_START_SYMBOL=' '
    typeset -g POWERLEVEL9K_EMPTY_LINE_LEFT_PROMPT_FIRST_SEGMENT_END_SYMBOL='%{%}'
    typeset -g POWERLEVEL9K_EMPTY_LINE_RIGHT_PROMPT_FIRST_SEGMENT_START_SYMBOL='%{%}'
  fi

  #################################[ os_icon: os identifier ]##################################
  typeset -g POWERLEVEL9K_OS_ICON_FOREGROUND=

  ################################[ prompt_char: prompt symbol ]################################
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=76
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='❯'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='❮'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIVIS_CONTENT_EXPANSION='V'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIOWR_CONTENT_EXPANSION='▶'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OVERWRITE_STATE=true
  typeset -g POWERLEVEL9K_PROMPT_CHAR_LEFT_PROMPT_LAST_SEGMENT_END_SYMBOL=''
  typeset -g POWERLEVEL9K_PROMPT_CHAR_LEFT_PROMPT_FIRST_SEGMENT_START_SYMBOL=

  ##################################[ dir: current directory ]##################################
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=31
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
  typeset -g POWERLEVEL9K_SHORTEN_DELIMITER=
  typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=103
  typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=39
  typeset -g POWERLEVEL9K_DIR_ANCHOR_BOLD=true
  local anchor_files=(
    .bzr .citc .git .hg .node-version .python-version .go-version .ruby-version
    .lua-version .java-version .perl-version .php-version .tool-versions .mise.toml
    .shorten_folder_marker .svn .terraform CVS Cargo.toml composer.json go.mod
    package.json stack.yaml
  )
  typeset -g POWERLEVEL9K_SHORTEN_FOLDER_MARKER="(${(j:|:)anchor_files})"
  typeset -g POWERLEVEL9K_DIR_TRUNCATE_BEFORE_MARKER=false
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=1
  typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=80
  typeset -g POWERLEVEL9K_DIR_MIN_COMMAND_COLUMNS=40
  typeset -g POWERLEVEL9K_DIR_MIN_COMMAND_COLUMNS_PCT=50
  typeset -g POWERLEVEL9K_DIR_HYPERLINK=false
  typeset -g POWERLEVEL9K_DIR_SHOW_WRITABLE=v3
  typeset -g POWERLEVEL9K_LOCK_ICON='∅'
  typeset -g POWERLEVEL9K_DIR_CLASSES=()

  #####################################[ vcs: git status ]######################################
  typeset -g POWERLEVEL9K_VCS_BRANCH_ICON=
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_ICON='?'

  function my_git_formatter() {
    emulate -L zsh
    if [[ -n $P9K_CONTENT ]]; then
      typeset -g my_git_format=$P9K_CONTENT
      return
    fi
    if (( $1 )); then
      local       meta='%f'
      local      clean='%76F'
      local   modified='%178F'
      local  untracked='%39F'
      local conflicted='%196F'
    else
      local       meta='%244F'
      local      clean='%244F'
      local   modified='%244F'
      local  untracked='%244F'
      local conflicted='%244F'
    fi
    local res
    if [[ -n $VCS_STATUS_LOCAL_BRANCH ]]; then
      local branch=${(V)VCS_STATUS_LOCAL_BRANCH}
      (( $#branch > 32 )) && branch[13,-13]="…"
      res+="${clean}${(g::)POWERLEVEL9K_VCS_BRANCH_ICON}${branch//\%/%%}"
    fi
    if [[ -n $VCS_STATUS_TAG && -z $VCS_STATUS_LOCAL_BRANCH ]]; then
      local tag=${(V)VCS_STATUS_TAG}
      (( $#tag > 32 )) && tag[13,-13]="…"
      res+="${meta}#${clean}${tag//\%/%%}"
    fi
    [[ -z $VCS_STATUS_LOCAL_BRANCH && -z $VCS_STATUS_TAG ]] && \
      res+="${meta}@${clean}${VCS_STATUS_COMMIT[1,8]}"
    if [[ -n ${VCS_STATUS_REMOTE_BRANCH:#$VCS_STATUS_LOCAL_BRANCH} ]]; then
      res+="${meta}:${clean}${(V)VCS_STATUS_REMOTE_BRANCH//\%/%%}"
    fi
    if [[ $VCS_STATUS_COMMIT_SUMMARY == (|*[^[:alnum:]])(wip|WIP)(|[^[:alnum:]]*) ]]; then
      res+=" ${modified}wip"
    fi
    if (( VCS_STATUS_COMMITS_AHEAD || VCS_STATUS_COMMITS_BEHIND )); then
      (( VCS_STATUS_COMMITS_BEHIND )) && res+=" ${clean}⇣${VCS_STATUS_COMMITS_BEHIND}"
      (( VCS_STATUS_COMMITS_AHEAD && !VCS_STATUS_COMMITS_BEHIND )) && res+=" "
      (( VCS_STATUS_COMMITS_AHEAD  )) && res+="${clean}⇡${VCS_STATUS_COMMITS_AHEAD}"
    elif [[ -n $VCS_STATUS_REMOTE_BRANCH ]]; then
      :
    fi
    (( VCS_STATUS_PUSH_COMMITS_BEHIND )) && res+=" ${clean}⇠${VCS_STATUS_PUSH_COMMITS_BEHIND}"
    (( VCS_STATUS_PUSH_COMMITS_AHEAD && !VCS_STATUS_PUSH_COMMITS_BEHIND )) && res+=" "
    (( VCS_STATUS_PUSH_COMMITS_AHEAD  )) && res+="${clean}⇢${VCS_STATUS_PUSH_COMMITS_AHEAD}"
    (( VCS_STATUS_STASHES        )) && res+=" ${clean}*${VCS_STATUS_STASHES}"
    [[ -n $VCS_STATUS_ACTION     ]] && res+=" ${conflicted}${VCS_STATUS_ACTION}"
    (( VCS_STATUS_NUM_CONFLICTED )) && res+=" ${conflicted}~${VCS_STATUS_NUM_CONFLICTED}"
    (( VCS_STATUS_NUM_STAGED     )) && res+=" ${modified}+${VCS_STATUS_NUM_STAGED}"
    (( VCS_STATUS_NUM_UNSTAGED   )) && res+=" ${modified}!${VCS_STATUS_NUM_UNSTAGED}"
    (( VCS_STATUS_NUM_UNTRACKED  )) && res+=" ${untracked}${(g::)POWERLEVEL9K_VCS_UNTRACKED_ICON}${VCS_STATUS_NUM_UNTRACKED}"
    (( VCS_STATUS_HAS_UNSTAGED == -1 )) && res+=" ${modified}─"
    typeset -g my_git_format=$res
  }
  functions -M my_git_formatter 2>/dev/null

  typeset -g POWERLEVEL9K_VCS_MAX_INDEX_SIZE_DIRTY=-1
  typeset -g POWERLEVEL9K_VCS_DISABLED_WORKDIR_PATTERN='~'
  typeset -g POWERLEVEL9K_VCS_DISABLE_GITSTATUS_FORMATTING=true
  typeset -g POWERLEVEL9K_VCS_CONTENT_EXPANSION='${$((my_git_formatter(1)))+${my_git_format}}'
  typeset -g POWERLEVEL9K_VCS_LOADING_CONTENT_EXPANSION='${$((my_git_formatter(0)))+${my_git_format}}'
  typeset -g POWERLEVEL9K_VCS_{STAGED,UNSTAGED,UNTRACKED,CONFLICTED,COMMITS_AHEAD,COMMITS_BEHIND}_MAX_NUM=-1
  typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=76
  typeset -g POWERLEVEL9K_VCS_LOADING_VISUAL_IDENTIFIER_COLOR=244
  typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_EXPANSION=
  typeset -g POWERLEVEL9K_VCS_BACKENDS=(git)
  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=76
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=76
  typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=178

  ##########################[ status: exit code of the last command ]###########################
  typeset -g POWERLEVEL9K_STATUS_EXTENDED_STATES=true
  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=70
  typeset -g POWERLEVEL9K_STATUS_OK_VISUAL_IDENTIFIER_EXPANSION='✔'
  typeset -g POWERLEVEL9K_STATUS_OK_PIPE=true
  typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=70
  typeset -g POWERLEVEL9K_STATUS_OK_PIPE_VISUAL_IDENTIFIER_EXPANSION='✔'
  typeset -g POWERLEVEL9K_STATUS_ERROR=false
  typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=160
  typeset -g POWERLEVEL9K_STATUS_ERROR_VISUAL_IDENTIFIER_EXPANSION='х'
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=160
  typeset -g POWERLEVEL9K_STATUS_VERBOSE_SIGNAME=false
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_VISUAL_IDENTIFIER_EXPANSION='х'
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=160
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_VISUAL_IDENTIFIER_EXPANSION='х'

  ###################[ command_execution_time: duration of the last command ]###################
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_PRECISION=0
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=101
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FORMAT='d h m s'
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_VISUAL_IDENTIFIER_EXPANSION=

  #######################[ background_jobs: presence of background jobs ]#######################
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_VERBOSE=false
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_FOREGROUND=70
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_VISUAL_IDENTIFIER_EXPANSION='≡'

  #######################[ direnv: direnv status (https://direnv.net/) ]########################
  typeset -g POWERLEVEL9K_DIRENV_FOREGROUND=178

  ###############[ asdf: asdf version manager (https://github.com/asdf-vm/asdf) ]###############
  typeset -g POWERLEVEL9K_ASDF_FOREGROUND=66
  typeset -g POWERLEVEL9K_ASDF_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_ASDF_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_ASDF_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_ASDF_SHOW_ON_UPGLOB=
  typeset -g POWERLEVEL9K_ASDF_RUBY_FOREGROUND=168
  typeset -g POWERLEVEL9K_ASDF_PYTHON_FOREGROUND=37
  typeset -g POWERLEVEL9K_ASDF_GOLANG_FOREGROUND=37
  typeset -g POWERLEVEL9K_ASDF_NODEJS_FOREGROUND=70
  typeset -g POWERLEVEL9K_ASDF_RUST_FOREGROUND=37
  typeset -g POWERLEVEL9K_ASDF_DOTNET_CORE_FOREGROUND=134
  typeset -g POWERLEVEL9K_ASDF_FLUTTER_FOREGROUND=38
  typeset -g POWERLEVEL9K_ASDF_LUA_FOREGROUND=32
  typeset -g POWERLEVEL9K_ASDF_JAVA_FOREGROUND=32
  typeset -g POWERLEVEL9K_ASDF_PERL_FOREGROUND=67
  typeset -g POWERLEVEL9K_ASDF_ERLANG_FOREGROUND=125
  typeset -g POWERLEVEL9K_ASDF_ELIXIR_FOREGROUND=129
  typeset -g POWERLEVEL9K_ASDF_POSTGRES_FOREGROUND=31
  typeset -g POWERLEVEL9K_ASDF_PHP_FOREGROUND=99
  typeset -g POWERLEVEL9K_ASDF_HASKELL_FOREGROUND=172
  typeset -g POWERLEVEL9K_ASDF_JULIA_FOREGROUND=70

  ##########[ nordvpn: nordvpn connection status, linux only (https://nordvpn.com/) ]###########
  typeset -g POWERLEVEL9K_NORDVPN_FOREGROUND=39
  typeset -g POWERLEVEL9K_NORDVPN_{DISCONNECTED,CONNECTING,DISCONNECTING}_CONTENT_EXPANSION=
  typeset -g POWERLEVEL9K_NORDVPN_{DISCONNECTED,CONNECTING,DISCONNECTING}_VISUAL_IDENTIFIER_EXPANSION=
  typeset -g POWERLEVEL9K_NORDVPN_VISUAL_IDENTIFIER_EXPANSION='nord'

  #################[ ranger: ranger shell (https://github.com/ranger/ranger) ]##################
  typeset -g POWERLEVEL9K_RANGER_FOREGROUND=178
  typeset -g POWERLEVEL9K_RANGER_VISUAL_IDENTIFIER_EXPANSION='▲'

  ####################[ yazi: yazi shell (https://github.com/sxyazi/yazi) ]#####################
  typeset -g POWERLEVEL9K_YAZI_FOREGROUND=178
  typeset -g POWERLEVEL9K_YAZI_VISUAL_IDENTIFIER_EXPANSION='▲'

  ######################[ nnn: nnn shell (https://github.com/jarun/nnn) ]#######################
  typeset -g POWERLEVEL9K_NNN_FOREGROUND=72

  ######################[ lf: lf shell (https://github.com/gokcehan/lf) ]#######################
  typeset -g POWERLEVEL9K_LF_FOREGROUND=72

  ##################[ xplr: xplr shell (https://github.com/sayanarijit/xplr) ]##################
  typeset -g POWERLEVEL9K_XPLR_FOREGROUND=72

  ###########################[ vim_shell: vim shell indicator (:sh) ]###########################
  typeset -g POWERLEVEL9K_VIM_SHELL_FOREGROUND=34

  ######[ midnight_commander: midnight commander shell (https://midnight-commander.org/) ]######
  typeset -g POWERLEVEL9K_MIDNIGHT_COMMANDER_FOREGROUND=178

  #[ nix_shell: nix shell (https://nixos.org/nixos/nix-pills/developing-with-nix-shell.html) ]##
  typeset -g POWERLEVEL9K_NIX_SHELL_FOREGROUND=74

  ##################[ chezmoi_shell: chezmoi shell (https://www.chezmoi.io/) ]##################
  typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=33

  ##################################[ disk_usage: disk usage ]##################################
  typeset -g POWERLEVEL9K_DISK_USAGE_NORMAL_FOREGROUND=35
  typeset -g POWERLEVEL9K_DISK_USAGE_WARNING_FOREGROUND=220
  typeset -g POWERLEVEL9K_DISK_USAGE_CRITICAL_FOREGROUND=160
  typeset -g POWERLEVEL9K_DISK_USAGE_WARNING_LEVEL=90
  typeset -g POWERLEVEL9K_DISK_USAGE_CRITICAL_LEVEL=95
  typeset -g POWERLEVEL9K_DISK_USAGE_ONLY_WARNING=false

  ######################################[ ram: free RAM ]#######################################
  typeset -g POWERLEVEL9K_RAM_FOREGROUND=66

  #####################################[ swap: used swap ]######################################
  typeset -g POWERLEVEL9K_SWAP_FOREGROUND=96

  ######################################[ load: CPU load ]######################################
  typeset -g POWERLEVEL9K_LOAD_WHICH=5
  typeset -g POWERLEVEL9K_LOAD_NORMAL_FOREGROUND=66
  typeset -g POWERLEVEL9K_LOAD_WARNING_FOREGROUND=178
  typeset -g POWERLEVEL9K_LOAD_CRITICAL_FOREGROUND=166

  ################[ todo: todo items (https://github.com/todotxt/todo.txt-cli) ]################
  typeset -g POWERLEVEL9K_TODO_FOREGROUND=110
  typeset -g POWERLEVEL9K_TODO_HIDE_ZERO_TOTAL=true
  typeset -g POWERLEVEL9K_TODO_HIDE_ZERO_FILTERED=false

  ###########[ timewarrior: timewarrior tracking status (https://timewarrior.net/) ]############
  typeset -g POWERLEVEL9K_TIMEWARRIOR_FOREGROUND=110
  typeset -g POWERLEVEL9K_TIMEWARRIOR_CONTENT_EXPANSION='${P9K_CONTENT:0:24}${${P9K_CONTENT:24}:+…}'

  ##############[ taskwarrior: taskwarrior task count (https://taskwarrior.org/) ]##############
  typeset -g POWERLEVEL9K_TASKWARRIOR_FOREGROUND=74

  ######[ per_directory_history: Oh My Zsh per-directory-history local/global indicator ]#######
  typeset -g POWERLEVEL9K_PER_DIRECTORY_HISTORY_LOCAL_FOREGROUND=135
  typeset -g POWERLEVEL9K_PER_DIRECTORY_HISTORY_GLOBAL_FOREGROUND=130

  ################################[ cpu_arch: CPU architecture ]################################
  typeset -g POWERLEVEL9K_CPU_ARCH_FOREGROUND=172

  ##################################[ context: user@hostname ]##################################
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_FOREGROUND=178
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_FOREGROUND=180
  typeset -g POWERLEVEL9K_CONTEXT_FOREGROUND=180
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_TEMPLATE='%B%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_TEMPLATE='%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_TEMPLATE='%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_{DEFAULT,SUDO}_{CONTENT,VISUAL_IDENTIFIER}_EXPANSION=

  ###[ virtualenv: python virtual environment (https://docs.python.org/3/library/venv.html) ]###
  typeset -g POWERLEVEL9K_VIRTUALENV_FOREGROUND=37
  typeset -g POWERLEVEL9K_VIRTUALENV_SHOW_PYTHON_VERSION=false
  typeset -g POWERLEVEL9K_VIRTUALENV_SHOW_WITH_PYENV=false
  typeset -g POWERLEVEL9K_VIRTUALENV_{LEFT,RIGHT}_DELIMITER=

  #####################[ anaconda: conda environment (https://conda.io/) ]######################
  typeset -g POWERLEVEL9K_ANACONDA_FOREGROUND=37
  typeset -g POWERLEVEL9K_ANACONDA_CONTENT_EXPANSION='${${${${CONDA_PROMPT_MODIFIER#\(}% }%\)}:-${CONDA_PREFIX:t}}'

  ################[ pyenv: python environment (https://github.com/pyenv/pyenv) ]################
  typeset -g POWERLEVEL9K_PYENV_FOREGROUND=37
  typeset -g POWERLEVEL9K_PYENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_PYENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_PYENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_PYENV_CONTENT_EXPANSION='${P9K_CONTENT}${${P9K_CONTENT:#$P9K_PYENV_PYTHON_VERSION(|/*)}:+ $P9K_PYENV_PYTHON_VERSION}'

  ################[ goenv: go environment (https://github.com/syndbg/goenv) ]################
  typeset -g POWERLEVEL9K_GOENV_FOREGROUND=37
  typeset -g POWERLEVEL9K_GOENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_GOENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_GOENV_SHOW_SYSTEM=true

  ##########[ nodenv: node.js version from nodenv (https://github.com/nodenv/nodenv) ]##########
  typeset -g POWERLEVEL9K_NODENV_FOREGROUND=70
  typeset -g POWERLEVEL9K_NODENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_NODENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_NODENV_SHOW_SYSTEM=true

  ##############[ nvm: node.js version from nvm (https://github.com/nvm-sh/nvm) ]###############
  typeset -g POWERLEVEL9K_NVM_FOREGROUND=70
  typeset -g POWERLEVEL9K_NVM_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_NVM_SHOW_SYSTEM=true

  ############[ nodeenv: node.js environment (https://github.com/ekalinin/nodeenv) ]############
  typeset -g POWERLEVEL9K_NODEENV_FOREGROUND=70
  typeset -g POWERLEVEL9K_NODEENV_SHOW_NODE_VERSION=false
  typeset -g POWERLEVEL9K_NODEENV_{LEFT,RIGHT}_DELIMITER=

  ##############################[ node_version: node.js version ]###############################
  typeset -g POWERLEVEL9K_NODE_VERSION_FOREGROUND=70
  typeset -g POWERLEVEL9K_NODE_VERSION_PROJECT_ONLY=true

  #######################[ go_version: go version (https://golang.org) ]########################
  typeset -g POWERLEVEL9K_GO_VERSION_FOREGROUND=37
  typeset -g POWERLEVEL9K_GO_VERSION_PROJECT_ONLY=true

  #################[ rust_version: rustc version (https://www.rust-lang.org) ]##################
  typeset -g POWERLEVEL9K_RUST_VERSION_FOREGROUND=37
  typeset -g POWERLEVEL9K_RUST_VERSION_PROJECT_ONLY=true

  ###############[ dotnet_version: .NET version (https://dotnet.microsoft.com) ]################
  typeset -g POWERLEVEL9K_DOTNET_VERSION_FOREGROUND=134
  typeset -g POWERLEVEL9K_DOTNET_VERSION_PROJECT_ONLY=true

  #####################[ php_version: php version (https://www.php.net/) ]######################
  typeset -g POWERLEVEL9K_PHP_VERSION_FOREGROUND=99
  typeset -g POWERLEVEL9K_PHP_VERSION_PROJECT_ONLY=true

  ##########[ laravel_version: laravel php framework version (https://laravel.com/) ]###########
  typeset -g POWERLEVEL9K_LARAVEL_VERSION_FOREGROUND=161

  ####################[ java_version: java version (https://www.java.com/) ]####################
  typeset -g POWERLEVEL9K_JAVA_VERSION_FOREGROUND=32
  typeset -g POWERLEVEL9K_JAVA_VERSION_PROJECT_ONLY=true
  typeset -g POWERLEVEL9K_JAVA_VERSION_FULL=false

  ###[ package: name@version from package.json (https://docs.npmjs.com/files/package.json) ]####
  typeset -g POWERLEVEL9K_PACKAGE_FOREGROUND=117

  #############[ rbenv: ruby version from rbenv (https://github.com/rbenv/rbenv) ]##############
  typeset -g POWERLEVEL9K_RBENV_FOREGROUND=168
  typeset -g POWERLEVEL9K_RBENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_RBENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_RBENV_SHOW_SYSTEM=true

  #######################[ rvm: ruby version from rvm (https://rvm.io) ]########################
  typeset -g POWERLEVEL9K_RVM_FOREGROUND=168
  typeset -g POWERLEVEL9K_RVM_SHOW_GEMSET=false
  typeset -g POWERLEVEL9K_RVM_SHOW_PREFIX=false

  ###########[ fvm: flutter version management (https://github.com/leoafarias/fvm) ]############
  typeset -g POWERLEVEL9K_FVM_FOREGROUND=38

  ##########[ luaenv: lua version from luaenv (https://github.com/cehoffman/luaenv) ]###########
  typeset -g POWERLEVEL9K_LUAENV_FOREGROUND=32
  typeset -g POWERLEVEL9K_LUAENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_LUAENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_LUAENV_SHOW_SYSTEM=true

  ###############[ jenv: java version from jenv (https://github.com/jenv/jenv) ]################
  typeset -g POWERLEVEL9K_JENV_FOREGROUND=32
  typeset -g POWERLEVEL9K_JENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_JENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_JENV_SHOW_SYSTEM=true

  ###########[ plenv: perl version from plenv (https://github.com/tokuhirom/plenv) ]############
  typeset -g POWERLEVEL9K_PLENV_FOREGROUND=67
  typeset -g POWERLEVEL9K_PLENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_PLENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_PLENV_SHOW_SYSTEM=true

  ###########[ perlbrew: perl version from perlbrew (https://github.com/gugod/App-perlbrew) ]############
  typeset -g POWERLEVEL9K_PERLBREW_FOREGROUND=67
  typeset -g POWERLEVEL9K_PERLBREW_PROJECT_ONLY=true
  typeset -g POWERLEVEL9K_PERLBREW_SHOW_PREFIX=false

  ############[ phpenv: php version from phpenv (https://github.com/phpenv/phpenv) ]############
  typeset -g POWERLEVEL9K_PHPENV_FOREGROUND=99
  typeset -g POWERLEVEL9K_PHPENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_PHPENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_PHPENV_SHOW_SYSTEM=true

  #######[ scalaenv: scala version from scalaenv (https://github.com/scalaenv/scalaenv) ]#######
  typeset -g POWERLEVEL9K_SCALAENV_FOREGROUND=160
  typeset -g POWERLEVEL9K_SCALAENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_SCALAENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_SCALAENV_SHOW_SYSTEM=true

  ##########[ haskell_stack: haskell version from stack (https://haskellstack.org/) ]###########
  typeset -g POWERLEVEL9K_HASKELL_STACK_FOREGROUND=172
  typeset -g POWERLEVEL9K_HASKELL_STACK_SOURCES=(shell local)
  typeset -g POWERLEVEL9K_HASKELL_STACK_ALWAYS_SHOW=true

  #############[ kubecontext: current kubernetes context (https://kubernetes.io/) ]#############
  typeset -g POWERLEVEL9K_KUBECONTEXT_SHOW_ON_COMMAND='kubectl|helm|kubens|kubectx|oc|istioctl|kogito|k9s|helmfile|flux|fluxctl|stern|kubeseal|skaffold|kubent|kubecolor|cmctl|sparkctl'
  typeset -g POWERLEVEL9K_KUBECONTEXT_CLASSES=('*' DEFAULT)
  typeset -g POWERLEVEL9K_KUBECONTEXT_DEFAULT_FOREGROUND=134
  typeset -g POWERLEVEL9K_KUBECONTEXT_DEFAULT_VISUAL_IDENTIFIER_EXPANSION='○'
  typeset -g POWERLEVEL9K_KUBECONTEXT_DEFAULT_CONTENT_EXPANSION=
  POWERLEVEL9K_KUBECONTEXT_DEFAULT_CONTENT_EXPANSION+='${P9K_KUBECONTEXT_CLOUD_CLUSTER:-${P9K_KUBECONTEXT_NAME}}'
  POWERLEVEL9K_KUBECONTEXT_DEFAULT_CONTENT_EXPANSION+='${${:-/$P9K_KUBECONTEXT_NAMESPACE}:#/default}'

  ################[ terraform: terraform workspace (https://www.terraform.io) ]#################
  typeset -g POWERLEVEL9K_TERRAFORM_SHOW_DEFAULT=false
  typeset -g POWERLEVEL9K_TERRAFORM_CLASSES=('*' OTHER)
  typeset -g POWERLEVEL9K_TERRAFORM_OTHER_FOREGROUND=38

  #############[ terraform_version: terraform version (https://www.terraform.io) ]##############
  typeset -g POWERLEVEL9K_TERRAFORM_VERSION_FOREGROUND=38

  #[ aws: aws profile (https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-profiles.html) ]#
  typeset -g POWERLEVEL9K_AWS_SHOW_ON_COMMAND='aws|awless|cdk|terraform|pulumi|terragrunt'
  typeset -g POWERLEVEL9K_AWS_CLASSES=('*' DEFAULT)
  typeset -g POWERLEVEL9K_AWS_DEFAULT_FOREGROUND=208
  typeset -g POWERLEVEL9K_AWS_CONTENT_EXPANSION='${P9K_AWS_PROFILE//\%/%%}${P9K_AWS_REGION:+ ${P9K_AWS_REGION//\%/%%}}'

  #[ aws_eb_env: aws elastic beanstalk environment (https://aws.amazon.com/elasticbeanstalk/) ]#
  typeset -g POWERLEVEL9K_AWS_EB_ENV_FOREGROUND=70
  typeset -g POWERLEVEL9K_AWS_EB_ENV_VISUAL_IDENTIFIER_EXPANSION='eb'

  ##########[ azure: azure account name (https://docs.microsoft.com/en-us/cli/azure) ]##########
  typeset -g POWERLEVEL9K_AZURE_SHOW_ON_COMMAND='az|terraform|pulumi|terragrunt'
  typeset -g POWERLEVEL9K_AZURE_CLASSES=('*' OTHER)
  typeset -g POWERLEVEL9K_AZURE_OTHER_FOREGROUND=32

  ##########[ gcloud: google cloud account and project (https://cloud.google.com/) ]###########
  typeset -g POWERLEVEL9K_GCLOUD_SHOW_ON_COMMAND='gcloud|gcs|gsutil'
  typeset -g POWERLEVEL9K_GCLOUD_FOREGROUND=32
  typeset -g POWERLEVEL9K_GCLOUD_PARTIAL_CONTENT_EXPANSION='${P9K_GCLOUD_PROJECT_ID//\%/%%}'
  typeset -g POWERLEVEL9K_GCLOUD_COMPLETE_CONTENT_EXPANSION='${P9K_GCLOUD_PROJECT_NAME//\%/%%}'
  typeset -g POWERLEVEL9K_GCLOUD_REFRESH_PROJECT_NAME_SECONDS=60

  #[ google_app_cred: google application credentials (https://cloud.google.com/docs/authentication/production) ]#
  typeset -g POWERLEVEL9K_GOOGLE_APP_CRED_SHOW_ON_COMMAND='terraform|pulumi|terragrunt'
  typeset -g POWERLEVEL9K_GOOGLE_APP_CRED_CLASSES=('*' DEFAULT)
  typeset -g POWERLEVEL9K_GOOGLE_APP_CRED_DEFAULT_FOREGROUND=32
  typeset -g POWERLEVEL9K_GOOGLE_APP_CRED_DEFAULT_CONTENT_EXPANSION='${P9K_GOOGLE_APP_CRED_PROJECT_ID//\%/%%}'

  ##############[ toolbox: toolbox name (https://github.com/containers/toolbox) ]###############
  typeset -g POWERLEVEL9K_TOOLBOX_FOREGROUND=178
  typeset -g POWERLEVEL9K_TOOLBOX_CONTENT_EXPANSION='${P9K_TOOLBOX_NAME:#fedora-toolbox-*}'

  ###############################[ public_ip: public IP address ]###############################
  typeset -g POWERLEVEL9K_PUBLIC_IP_FOREGROUND=94

  ########################[ vpn_ip: virtual private network indicator ]#########################
  typeset -g POWERLEVEL9K_VPN_IP_FOREGROUND=81
  typeset -g POWERLEVEL9K_VPN_IP_CONTENT_EXPANSION=
  typeset -g POWERLEVEL9K_VPN_IP_INTERFACE='(gpd|wg|(.*tun)|tailscale)[0-9]*|(zt.*)'
  typeset -g POWERLEVEL9K_VPN_IP_SHOW_ALL=false

  ###########[ ip: ip address and bandwidth usage for a specified network interface ]###########
  typeset -g POWERLEVEL9K_IP_FOREGROUND=38
  typeset -g POWERLEVEL9K_IP_CONTENT_EXPANSION='$P9K_IP_IP${P9K_IP_RX_RATE:+ %70F⇣$P9K_IP_RX_RATE}${P9K_IP_TX_RATE:+ %215F⇡$P9K_IP_TX_RATE}'
  typeset -g POWERLEVEL9K_IP_INTERFACE='[ew].*'

  #########################[ proxy: system-wide http/https/ftp proxy ]##########################
  typeset -g POWERLEVEL9K_PROXY_FOREGROUND=68

  ################################[ battery: internal battery ]#################################
  typeset -g POWERLEVEL9K_BATTERY_LOW_THRESHOLD=20
  typeset -g POWERLEVEL9K_BATTERY_LOW_FOREGROUND=160
  typeset -g POWERLEVEL9K_BATTERY_{CHARGING,CHARGED}_FOREGROUND=70
  typeset -g POWERLEVEL9K_BATTERY_DISCONNECTED_FOREGROUND=178
  typeset -g POWERLEVEL9K_BATTERY_STAGES=('%K{232}▁' '%K{232}▂' '%K{232}▃' '%K{232}▄' '%K{232}▅' '%K{232}▆' '%K{232}▇' '%K{232}█')
  typeset -g POWERLEVEL9K_BATTERY_VERBOSE=false

  #####################################[ wifi: wifi speed ]#####################################
  typeset -g POWERLEVEL9K_WIFI_FOREGROUND=68

  ####################################[ time: current time ]####################################
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=66
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M:%S}'
  typeset -g POWERLEVEL9K_TIME_UPDATE_ON_COMMAND=false
  typeset -g POWERLEVEL9K_TIME_VISUAL_IDENTIFIER_EXPANSION=

  function prompt_example() {
    p10k segment -f 208 -i '⭐' -t 'hello, %n'
  }
  function instant_prompt_example() {
    prompt_example
  }

  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=off
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose
  typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true
  (( ! $+functions[p10k] )) || p10k reload
}

typeset -g POWERLEVEL9K_CONFIG_FILE=${${(%):-%x}:a}
(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
P10K_EOF

log "  .p10k.zsh written."

# =============================================================================
# Done
# =============================================================================
touch "$DONE_FILE"
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  ✅ Dev environment setup complete!                                 ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  Tools installed:                                                    ║"
if command -v claude &>/dev/null || [[ -f "$HOME/.local/bin/claude" ]]; then
  echo "║  • Claude Code:     ready                                           ║"
fi
if command -v agy &>/dev/null || [[ -f "$HOME/.local/bin/agy" ]]; then
  echo "║  • Antigravity CLI: ready                                           ║"
fi
echo "║  • pyenv:           ready (use 'pyenv install <version>')           ║"
echo "║  • Oh My Zsh + Powerlevel10k: ready                                 ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  Start your full shell:  exec zsh                                   ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
SETUP_USER_EOF

chmod 750 "${USER_HOME}/setup-user.sh"
chown "${VM_USER}:${VM_USER}" "${USER_HOME}/setup-user.sh"
log "  setup-user.sh written to ${USER_HOME}/setup-user.sh"

# =============================================================================
# 12. Write minimal bootstrap .zshrc (replaced by setup-user.sh)
# =============================================================================
log "Writing bootstrap .zshrc..."
cat > "${USER_HOME}/.zshrc" << 'BOOTSTRAP_ZSHRC_EOF'
# Bootstrap .zshrc — replaced automatically after running ~/setup-user.sh

if [[ ! -f "$HOME/.setup-done" ]]; then
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════════════╗"
  echo "  ║  First-time dev environment setup required (~5-10 minutes)      ║"
  echo "  ║                                                                  ║"
  echo "  ║  Run:  bash ~/setup-user.sh                                     ║"
  echo "  ╚══════════════════════════════════════════════════════════════════╝"
  echo ""
fi

# Load AI tool environment even before full setup
[[ -f /etc/profile.d/ai-tools.sh ]] && source /etc/profile.d/ai-tools.sh
BOOTSTRAP_ZSHRC_EOF

chown "${VM_USER}:${VM_USER}" "${USER_HOME}/.zshrc"
log "  Bootstrap .zshrc written."

# =============================================================================
# Done — write sentinel file (prevents re-run on subsequent boots)
# =============================================================================
log "======================================================================"
log "✅ System setup complete!"
log "   Installed: gcloud, node $(node --version), gh"
log "   AI tools (user-space): claude, antigravity-cli — run setup-user.sh"
log "   Vertex AI env vars: /etc/profile.d/ai-tools.sh"
log "   User ${VM_USER}: created with zsh + passwordless sudo"
log "   Next step: SSH in as ${VM_USER} and run:  bash ~/setup-user.sh"
log "======================================================================"

touch "$SENTINEL_FILE"
log "Sentinel written: ${SENTINEL_FILE} — startup script will skip on next boot."
