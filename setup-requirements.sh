#!/usr/bin/env bash
# ARTEX Linux requirements installer.
#
# Installs the runtime dependencies needed to run the ARTEX binary on a fresh
# Linux system (Debian/Ubuntu or RHEL/Fedora). This is the "bare-metal"
# equivalent of what the Dockerfile installs in the container image.
#
# Usage:
#   chmod +x setup-requirements.sh
#   sudo ./setup-requirements.sh            # install everything
#   sudo ./setup-requirements.sh --minimal  # skip optional recon tools
#
# Requirements: root or sudo, x86_64 or aarch64 Linux.
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
NUCLEI_VERSION="v3.11.1"
HTTPX_VERSION="v1.12.0"
SUBFINDER_VERSION="v2.17.0"
KATANA_VERSION="v1.8.0"
FFUF_VERSION="v2.3.0"
DALFOX_VERSION="v3.2.4"
BBOT_VERSION="3.0.2"
NODE_MAJOR=22
PYTHON_MIN="3.10"

# ─── Helpers ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

MINIMAL=false
[[ "${1:-}" == "--minimal" ]] && MINIMAL=true

# ─── Pre-checks ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  GOARCH=amd64; FFUF_ARCH=amd64; DALFOX_ARCH=x86_64  ;;
  aarch64) GOARCH=arm64; FFUF_ARCH=arm64; DALFOX_ARCH=aarch64  ;;
  *) die "Unsupported architecture: $ARCH (need x86_64 or aarch64)" ;;
esac

# ─── Detect distro family ──────────────────────────────────────────────────
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO_FAMILY=""
  case "$ID" in
    debian|ubuntu|kali|linuxmint|pop) DISTRO_FAMILY="debian" ;;
    fedora|rhel|centos|rocky|alma|ol) DISTRO_FAMILY="rhel"   ;;
    *) [[ -n "${ID_LIKE:-}" ]] && {
         [[ "$ID_LIKE" == *debian* ]] && DISTRO_FAMILY="debian"
         [[ "$ID_LIKE" == *rhel*   ]] && DISTRO_FAMILY="rhel"
         [[ "$ID_LIKE" == *fedora* ]] && DISTRO_FAMILY="rhel"
       } ;;
  esac
  [[ -n "$DISTRO_FAMILY" ]] || die "Unsupported distro: $ID ($ID_LIKE). Use Debian/Ubuntu or RHEL/Fedora."
else
  die "Cannot detect Linux distribution (no /etc/os-release)."
fi
info "Detected: $PRETTY_NAME ($DISTRO_FAMILY family), arch=$ARCH"

# ─── 1. System packages ────────────────────────────────────────────────────
info "Installing system packages..."

if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  # Core utilities
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget git jq unzip vim ripgrep \
    dnsutils iputils-ping netcat-openbsd whois nmap \
    build-essential libffi-dev libssl-dev

  # Python 3 (system or deadsnakes)
  if ! command -v python3 &>/dev/null || ! python3 -c "import sys; assert sys.version_info >= (3,10)" 2>/dev/null; then
    apt-get install -y --no-install-recommends python3 python3-venv python3-pip
  fi

  # Node.js from NodeSource
  if ! command -v node &>/dev/null || [[ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt "$NODE_MAJOR" ]]; then
    info "Installing Node.js ${NODE_MAJOR}.x..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y --no-install-recommends nodejs
  fi

  # PostgreSQL client (for pg_isready healthchecks when running standalone postgres)
  apt-get install -y --no-install-recommends postgresql-client || true

  rm -rf /var/lib/apt/lists/*

elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  # dnf or yum
  PKG="dnf"
  command -v dnf &>/dev/null || PKG="yum"

  $PKG install -y epel-release 2>/dev/null || true
  $PKG install -y \
    ca-certificates curl wget git jq unzip vim ripgrep \
    bind-utils iputils nmap-ncat whois nmap \
    gcc libffi-devel openssl-devel \
    python3 python3-pip python3-devel

  # Node.js from NodeSource
  if ! command -v node &>/dev/null || [[ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt "$NODE_MAJOR" ]]; then
    info "Installing Node.js ${NODE_MAJOR}.x..."
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    $PKG install -y nodejs
  fi

  $PKG install -y postgresql || true
fi

info "System packages installed."
info "  Python: $(python3 --version 2>&1)"
info "  Node:   $(node --version 2>&1)"
info "  nmap:   $(nmap --version 2>&1 | head -1)"

# ─── 2. Security recon tools (optional with --minimal) ─────────────────────
if [[ "$MINIMAL" == true ]]; then
  warn "Skipping optional recon tools (--minimal). Workers will have limited tooling."
else
  info "Installing security recon tools..."

  TOOL_DIR="/usr/local/bin"
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  # Helper: download ProjectDiscovery zip releases
  pd_fetch() {
    local repo="$1" ver="$2" name="$3"
    local nov="${ver#v}"
    local url="https://github.com/${repo}/releases/download/${ver}/${name}_${nov}_linux_${GOARCH}.zip"
    info "  Fetching $name $ver..."
    curl -fsSL "$url" -o "$TMP_DIR/t.zip"
    unzip -o -q "$TMP_DIR/t.zip" -d "$TMP_DIR/td"
    find "$TMP_DIR/td" -type f -name "$name" -exec install -m 0755 {} "$TOOL_DIR/" \;
    rm -rf "$TMP_DIR/t.zip" "$TMP_DIR/td"
  }

  # Helper: download tar.gz releases
  tar_fetch() {
    local url="$1" name="$2"
    info "  Fetching $name..."
    curl -fsSL "$url" -o "$TMP_DIR/t.tgz"
    mkdir -p "$TMP_DIR/td"
    tar -xzf "$TMP_DIR/t.tgz" -C "$TMP_DIR/td"
    find "$TMP_DIR/td" -type f -name "$name" -exec install -m 0755 {} "$TOOL_DIR/" \;
    rm -rf "$TMP_DIR/t.tgz" "$TMP_DIR/td"
  }

  # ProjectDiscovery tools
  pd_fetch projectdiscovery/nuclei   "$NUCLEI_VERSION"   nuclei
  pd_fetch projectdiscovery/httpx    "$HTTPX_VERSION"    httpx
  pd_fetch projectdiscovery/subfinder "$SUBFINDER_VERSION" subfinder
  pd_fetch projectdiscovery/katana   "$KATANA_VERSION"   katana

  # ffuf
  tar_fetch "https://github.com/ffuf/ffuf/releases/download/${FFUF_VERSION}/ffuf_${FFUF_VERSION#v}_linux_${FFUF_ARCH}.tar.gz" ffuf

  # dalfox
  tar_fetch "https://github.com/hahwul/dalfox/releases/download/${DALFOX_VERSION}/dalfox-${DALFOX_VERSION}-linux-${DALFOX_ARCH}-musl.tar.gz" dalfox

  # sqlmap (Python checkout)
  if [[ ! -d /opt/sqlmap ]]; then
    info "  Cloning sqlmap..."
    git clone --depth 1 https://github.com/sqlmapproject/sqlmap /opt/sqlmap
    ln -sf /opt/sqlmap/sqlmap.py "$TOOL_DIR/sqlmap"
  else
    info "  sqlmap already installed at /opt/sqlmap"
  fi

  # bbot (in its own venv)
  if ! command -v bbot &>/dev/null; then
    info "  Installing bbot ${BBOT_VERSION}..."
    python3 -m venv /opt/bbot
    /opt/bbot/bin/pip install --no-cache-dir "bbot==${BBOT_VERSION}"
    ln -sf /opt/bbot/bin/bbot "$TOOL_DIR/bbot"
    # Pre-install module dependencies so scans don't need pip at runtime
    bbot -y --install-all-deps || true
  else
    info "  bbot already installed"
  fi

  # Verify
  info "Verifying recon tools..."
  for tool in nuclei httpx subfinder katana ffuf dalfox sqlmap bbot; do
    if command -v "$tool" &>/dev/null; then
      info "  ✓ $tool"
    else
      warn "  ✗ $tool (not found — may need manual install)"
    fi
  done
fi

# ─── 3. Playwright + Chromium (browser automation for workers) ──────────────
info "Installing Playwright MCP and Chromium..."
npm install -g @playwright/mcp@latest @playwright/cli@latest playwright@latest 2>/dev/null || {
  warn "npm global install failed — trying with --unsafe-perm"
  npm install -g --unsafe-perm @playwright/mcp@latest @playwright/cli@latest playwright@latest
}

# Install chromium with system deps
playwright install --with-deps chromium || {
  warn "Playwright chromium install had issues — browser MCP may not work"
}

# ─── 4. Create app directory structure ──────────────────────────────────────
info "Setting up ARTEX directory structure..."
mkdir -p /app/{data,keys,skills}

# ─── 5. PostgreSQL reminder ────────────────────────────────────────────────
echo ""
info "═══════════════════════════════════════════════════════════════"
info " ARTEX requirements installed successfully!"
info "═══════════════════════════════════════════════════════════════"
echo ""
info "Next steps:"
info "  1. Install PostgreSQL 16+ (if not using external/Docker PG):"
if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  info "       sudo apt install postgresql-16"
elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  info "       sudo dnf install postgresql-server postgresql"
fi
info ""
info "  2. Download the ARTEX binary from GitHub Releases:"
info "       curl -fsSL https://github.com/tuanta0/artex/releases/latest/download/artex-linux-${GOARCH}.zip -o artex.zip"
info "       unzip artex.zip -d /app"
info "       chmod +x /app/artex"
info ""
info "  3. Set environment variables (or .env file):"
info "       export ARTEX_PG_DSN='postgres://artex:PASSWORD@localhost:5432/artex?sslmode=disable'"
info "       export ANTHROPIC_API_KEY='sk-ant-...'"
info ""
info "  4. Run ARTEX:"
info "       /app/artex"
info "       # Web UI: http://localhost:8787"
echo ""
if [[ "$MINIMAL" == true ]]; then
  warn "Minimal mode: recon tools not installed."
  warn "Run again without --minimal for full pentest capabilities."
fi
