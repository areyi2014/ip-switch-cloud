#!/usr/bin/env bash
#===============================================================================
# ip-switch automated deployment script (macOS / Ubuntu)
# Chinese version: install-zh.sh
#===============================================================================
# Purpose: one-click clone, install dependencies, build, generate the WorkBuddy config, generate the Codex config [create a desktop shortcut]
# Applies to: macOS 14+, Ubuntu 20.04+, Debian 11+
# Prerequisites: git installed, Node.js >= 18 installed
#===============================================================================
set -euo pipefail

# -- Colors ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# -- Defaults -------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://gitee.com/areyi2014/ip-switch.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/ip-switch}"
NODE_MIN_VERSION=18
PROJECT_NAME="ip-switch"

# -- Helper functions ------------------------------------------------------------------
log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }

# -- OS detection ----------------------------------------------------------------------
detect_os() {
    case "$(uname -s)" in
        Darwin)  OS="macos";;
        Linux)   OS="linux";;
        *)
            log_error "Unsupported OS: $(uname -s)"
            log_info  "Supported OS: macOS, Ubuntu/Debian"
            exit 1
            ;;
    esac

    if [ "$OS" = "linux" ]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS="${ID}"  # ubuntu, debian, etc.
        fi
    fi
    log_ok "Detected OS: ${OS}"
}

# -- Check the npm environment -------------------------------------------------------
# Does not depend on the IDE-bundled node (its version directory changes on upgrades, making issues hard to trace).
# Only two paths: (1) system PATH has node+npm -> use the system one directly;
#            (2) otherwise download a standalone Node.js from nodejs.org into a fixed directory
#               ~/.nodejs/node (fixed path, easy to trace, does not pollute the system).
# The selection is recorded in NODE_EXE / NPM_NODE / NPM_CLI,
# shared by npm execution and the MCP configuration.
check_npm() {
    log_step "Checking the npm environment"

    if command -v node &>/dev/null && command -v npm &>/dev/null; then
        NODE_EXE="$(command -v node)"
        log_ok "Using system Node.js: ${NODE_EXE}"
        return 0
    fi

    install_npm_from_official
}

# -- Download a standalone Node.js (with npm) from nodejs.org into a fixed directory -------
install_npm_from_official() {
    log_warn "System Node.js not found; downloading Node.js 22 LTS from nodejs.org..."

    # Resolve the latest v22.x version (fall back to a fixed LTS on failure)
    local ver=""
    ver=$(curl -fsSL --max-time 30 https://nodejs.org/dist/latest-v22.x/index.json 2>/dev/null |
          sed -n 's/.*"version":"\(v[^"]*\)".*/\1/p' | head -1)
    [ -z "$ver" ] && ver="v22.14.0"

    local dest="$HOME/.nodejs"
    mkdir -p "$dest"

    # Reuse first: if a complete install (with npm) already exists, use it directly; no re-download/delete.
    # Otherwise deletion fails while the MCP process holds node, and repeated reinstalls are pointless.
    case "$(uname -s)" in
        Linux|Darwin)
            if [ -x "$dest/bin/node" ] && [ -f "$dest/lib/node_modules/npm/bin/npm-cli.js" ]; then
                log_info "Existing Node.js detected, reusing: $dest"
                NPM_NODE="$dest/bin/node"
                NPM_CLI="$dest/lib/node_modules/npm/bin/npm-cli.js"
                NODE_EXE="$NPM_NODE"
                return 0
            fi
            ;;
        *)
            if [ -f "$dest/node/node.exe" ] && [ -f "$dest/node/node_modules/npm/bin/npm-cli.js" ]; then
                log_info "Existing Node.js detected, reusing: $dest/node"
                NPM_NODE="$dest/node/node.exe"
                NPM_CLI="$dest/node/node_modules/npm/bin/npm-cli.js"
                NODE_EXE="$NPM_NODE"
                return 0
            fi
            ;;
    esac

    local url tmp
    case "$(uname -s)" in
        Linux)
            case "$(uname -m)" in
                aarch64|arm64) url="https://nodejs.org/dist/${ver}/node-${ver}-linux-arm64.tar.xz" ;;
                *)             url="https://nodejs.org/dist/${ver}/node-${ver}-linux-x64.tar.xz" ;;
            esac
            tmp="$HOME/.nodejs.tmp"
            curl -fL --max-time 120 -o "$tmp" "$url" || { log_error "Download failed: $url"; exit 1; }
            tar -xJf "$tmp" -C "$dest" --strip-components=1
            NPM_NODE="$dest/bin/node"
            NPM_CLI="$dest/lib/node_modules/npm/bin/npm-cli.js"
            ;;
        Darwin)
            case "$(uname -m)" in
                arm64) url="https://nodejs.org/dist/${ver}/node-${ver}-darwin-arm64.tar.gz" ;;
                *)     url="https://nodejs.org/dist/${ver}/node-${ver}-darwin-x64.tar.gz" ;;
            esac
            tmp="$HOME/.nodejs.tmp"
            curl -fL --max-time 120 -o "$tmp" "$url" || { log_error "Download failed: $url"; exit 1; }
            tar -xzf "$tmp" -C "$dest" --strip-components=1
            NPM_NODE="$dest/bin/node"
            NPM_CLI="$dest/lib/node_modules/npm/bin/npm-cli.js"
            ;;
        *)  # Windows(Git Bash): zip
            local arch
            case "$PROCESSOR_ARCHITECTURE" in
                ARM64) arch="arm64" ;;
                *)     arch="x64" ;;
            esac
            url="https://nodejs.org/dist/${ver}/node-${ver}-win-${arch}.zip"
            tmp="$HOME/.nodejs.tmp.zip"
            curl -fL --max-time 120 -o "$tmp" "$url" || { log_error "Download failed: $url"; exit 1; }
            local tmpdir="$HOME/.nodejs.tmp"
            rm -rf "$tmpdir" && mkdir -p "$tmpdir"
            unzip -oq "$tmp" -d "$tmpdir" || { log_error "Extraction failed (install unzip first)"; exit 1; }
            # The zip extracts a node-<ver>-win-<arch>/ subfolder; normalize it to node (stable path, easy to trace)
            local d
            d=$(ls -1dt "$tmpdir"/*/ 2>/dev/null | head -1)
            [ -z "$d" ] && { log_error "Unexpected extraction result"; exit 1; }
            # If the old directory is locked by the MCP process it cannot be deleted -- fail with a clear message instead of silently
            rm -rf "$dest/node" 2>/dev/null
            if [ -d "$dest/node" ]; then
                log_error "Old install directory is locked and cannot be replaced: $dest/node"
                log_info "Exit the Codex / WorkBuddy ip-switch MCP (or kill the process holding node.exe) first, then retry."
                log_info "The installed version keeps working; no functional impact."
                exit 1
            fi
            mv "$d" "$dest/node"
            NPM_NODE="$dest/node/node.exe"
            NPM_CLI="$dest/node/node_modules/npm/bin/npm-cli.js"
            ;;
    esac
    [ -f "$NPM_CLI" ] || { log_error "npm installation failed; install Node.js manually: https://nodejs.org"; exit 1; }
    # Clean up temp files
    rm -f "$HOME/.nodejs.tmp" "$HOME/.nodejs.tmp.zip" 2>/dev/null
    rm -rf "$HOME/.nodejs.tmp" 2>/dev/null
    NODE_EXE="$NPM_NODE"
    log_ok "Installed Node.js ${ver} (npm $("$NPM_NODE" "$NPM_CLI" --version 2>/dev/null)) -> $NPM_NODE"
}

# Run npm: prefer the downloaded node (node <npm-cli.js>), fall back to PATH npm
# Note: npm run lifecycle scripts (node_modules/.bin/*) are executed by sh/cmd and locate node via PATH;
# therefore prepend the downloaded node dir to PATH to avoid errors when the system PATH has no node.
run_npm() {
    if [ -n "$NPM_CLI" ]; then
        local node_dir
        node_dir=$(dirname "$NPM_NODE")
        case ":$PATH:" in
            *":$node_dir:"*) ;;
            *) export PATH="${node_dir}:${PATH}" ;;
        esac
        "$NPM_NODE" "$NPM_CLI" "$@"
    else
        npm "$@"
    fi
}

# -- Check git ------------------------------------------------------------------------
check_git() {
    log_step "Checking the Git environment"

    # Option 1: already on PATH
    if command -v git &>/dev/null; then
        log_ok "git $(git --version | awk '{print $3}') ($(command -v git))"
        return
    fi

    log_warn "git not detected; installing automatically..."

    # -- CPU architecture ------------------------------------------------------------
    local arch
    arch=$(uname -m)
    log_info "Detected CPU architecture: ${arch}"

    # -- Option 2: installed but not on PATH ------------------------------------------
    local known_paths=(
        "/usr/local/bin/git"
        "/opt/homebrew/bin/git"
        "/usr/local/git/bin/git"
        "/opt/git/bin/git"
    )
    for kp in "${known_paths[@]}"; do
        if [ -x "$kp" ]; then
            local found_dir
            found_dir=$(dirname "$kp")
            log_info "Existing Git detected: ${found_dir}; repairing PATH..."
            export PATH="${found_dir}:${PATH}"
            log_ok "git $(git --version | awk '{print $3}') (${kp})"
            return
        fi
    done

    # -- Option 3: install via a package manager --------------------------------------
    case "$OS" in
        ubuntu|debian)
            log_info "Installing git via apt..."
            # Try switching to the Aliyun mirror for speed
            if [ -f /etc/apt/sources.list ] && ! grep -q "mirrors.aliyun.com" /etc/apt/sources.list 2>/dev/null; then
                log_info "Consider switching to a CN mirror for speed: sudo sed -i 's|archive.ubuntu.com|mirrors.aliyun.com|g' /etc/apt/sources.list"
            fi
            if command -v sudo &>/dev/null; then
                sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git
            else
                apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git
            fi
            ;;
        macos)
            if command -v brew &>/dev/null; then
                log_info "Installing git via Homebrew..."
                brew install git --quiet
            elif command -v xcode-select &>/dev/null; then
                log_info "Installing Command Line Tools (includes git) via xcode-select..."
                xcode-select --install 2>/dev/null || true
                log_warn "xcode-select opened an installer dialog; finish it manually and rerun the script"
                exit 1
            else
                log_error "No package manager found; install git manually"
                log_info  "  macOS:  xcode-select --install"
                exit 1
            fi
            ;;
        *)
            log_error "git not detected; install it manually"
            log_info  "  https://git-scm.com/downloads"
            exit 1
            ;;
    esac

    # -- Post-install verification ----------------------------------------------------
    if command -v git &>/dev/null; then
        log_ok "git installed: $(git --version)"
    else
        log_error "git installation failed; install it manually"
        log_info  "  macOS:  xcode-select --install or brew install git"
        log_info  "  Ubuntu: sudo apt-get install -y git"
        log_info  "  https://git-scm.com/downloads"
        exit 1
    fi
}

# -- Clone the repository --------------------------------------------------------------
clone_repo() {
    log_step "Cloning the project repository"

    if [ -d "$INSTALL_DIR/.git" ]; then
        log_warn "Target directory exists; running git pull to update..."
        cd "$INSTALL_DIR"
        git fetch origin "$BRANCH"
        git checkout "$BRANCH"
        git pull origin "$BRANCH"
        log_ok "Project updated: $INSTALL_DIR"
        return
    fi

    # Confirm the install directory
    log_info "Repository URL: ${REPO_URL}"
    log_info "Target branch: ${BRANCH}"
    log_info "Install directory: ${INSTALL_DIR}"
    echo ""
    read -r -p "Install to this directory? Press Enter to confirm, or type a new path: " user_dir
    if [ -n "$user_dir" ]; then
        INSTALL_DIR="$user_dir"
        log_info "Install directory updated: ${INSTALL_DIR}"
    fi

    # DNS warm-up
    local repo_host
    repo_host=$(echo "$REPO_URL" | sed -E 's|^https?://||;s|^git@||;s|:.*||;s|/.*||')
    log_info "Warming up DNS: ping ${repo_host} ..."
    if ! ping -c 1 -W 3 "$repo_host" >/dev/null 2>&1; then
        log_error "Cannot resolve the repository host: ${repo_host}"
        log_info  "Check your network connection and DNS settings"
        exit 1
    fi
    log_ok "Host reachable: ${repo_host}"

    # Retry the clone up to 3 times
    local max_retries=3
    local clone_ok=false

    for attempt in $(seq 1 $max_retries); do
        if [ "$attempt" -gt 1 ]; then
            rm -rf "$INSTALL_DIR" 2>/dev/null
            log_info "Retry clone attempt ${attempt} / ${max_retries}..."
            sleep 3
        else
            log_info "Cloning: ${REPO_URL} (branch: ${BRANCH})"
        fi

        # git's progress (Receiving objects etc.) goes to stderr; 2>&1 streams it straight to the terminal
        git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>&1 && {
            clone_ok=true
            break
        }

        log_warn "Clone failed (attempt ${attempt} / ${max_retries})"
    done

    if ! $clone_ok; then
        echo ""
        log_error "Clone failed (retried ${max_retries} times)"
        log_info ""
        log_info "Please check:"
        log_info "  1. The repository URL is correct: ${REPO_URL}"
        log_info "  2. Your network connection"
        log_info "  3. For a private repo, configure an SSH key first"
        log_info ""
        log_info "Manual steps:"
        log_info "  git clone ${REPO_URL} ${INSTALL_DIR}"
        exit 1
    fi
    log_ok "Clone succeeded: ${INSTALL_DIR}"
}

# -- Install dependencies --------------------------------------------------------------
install_deps() {
    log_step "Installing npm dependencies"

    cd "$INSTALL_DIR"

    if [ ! -f package.json ]; then
        log_error "package.json not found; unexpected project layout"
        exit 1
    fi

    log_info "Installing dependencies, please wait..."
    if run_npm install --loglevel=error; then
        log_ok "Dependencies installed"
    else
        log_error "Dependency installation failed"
        log_info  "Try clearing the cache and retrying: cd ${INSTALL_DIR} && rm -rf node_modules && npm install"
        exit 1
    fi
}

# -- Build TypeScript ------------------------------------------------------------------
build_project() {
    log_step "Building TypeScript"

    cd "$INSTALL_DIR"

    # Clear Electron env interference (may be set by the WorkBuddy environment)
    local env_prefix=""
    if [ -n "${ELECTRON_RUN_AS_NODE:-}" ]; then
        log_warn "ELECTRON_RUN_AS_NODE detected; temporarily cleared for the build"
        env_prefix="env -u ELECTRON_RUN_AS_NODE -u NODE_OPTIONS"
    fi

    log_info "Building..."
    if $env_prefix run_npm run build 2>&1; then
        log_ok "Build completed"
    else
        log_error "Build failed"
        if [ -n "$NPM_CLI" ]; then
            log_info "Manual build: cd ${INSTALL_DIR} && env -u ELECTRON_RUN_AS_NODE \"$NPM_NODE\" \"$NPM_CLI\" run build"
        else
            log_info "Manual build: cd ${INSTALL_DIR} && env -u ELECTRON_RUN_AS_NODE npm run build"
        fi
        exit 1
    fi

    # Verify the build output
    if [ -f "$INSTALL_DIR/dist/index.js" ]; then
        log_ok "Verified: dist/index.js generated"
    else
        log_error "Build output missing: dist/index.js does not exist"
        exit 1
    fi
}

# -- Detect MCP client platforms -----------------------------------------------------
detect_mcp_platform() {
    log_step "Detecting MCP client platforms"

    DETECTED_WB=false
    DETECTED_CODEX=false

    # WorkBuddy: check for the directory or mcp.json
    if [ -d "$HOME/.workbuddy" ]; then
        DETECTED_WB=true
        log_ok "WorkBuddy detected ($HOME/.workbuddy)"
    fi

    # Codex: check for the directory or binary
    if [ -d "$HOME/.codex" ] || command -v codex &>/dev/null; then
        DETECTED_CODEX=true
        log_ok "Codex detected ($HOME/.codex)"
    fi

    if ! $DETECTED_WB && ! $DETECTED_CODEX; then
        log_warn "Neither WorkBuddy nor Codex detected; printing a generic MCP config"
    fi
}

# -- Write the MCP config (merge into the existing one; node serializes it as standard JSON) --------
write_mcp_config_file() {
    local target_dir="$1"
    local node_exe="$2"
    local dist_js="$3"
    local target_path="${target_dir}/mcp.json"

    mkdir -p "$target_dir"

    # Merge + serialization are delegated to node: guarantees standard JSON (2-space indent, properly escaped paths)
    "$node_exe" -e '
const fs = require("fs");
const target = process.argv[1];
const entry = {
  command: process.argv[2],
  args: [process.argv[3]]
};
let config = {};
try {
  if (fs.existsSync(target)) {
    config = JSON.parse(fs.readFileSync(target, "utf8"));
  }
} catch (e) {
  config = {};
}
config.mcpServers = config.mcpServers || {};
config.mcpServers["ip-switch"] = entry;
fs.writeFileSync(target, JSON.stringify(config, null, 2) + "\n", "utf8");
' "$target_path" "$node_exe" "$dist_js" || {
        log_error "Failed to write the MCP config: ${target_path}"
        exit 1
    }
}

# -- Generate the WorkBuddy config -----------------------------------------------------------
generate_wb_config() {
    log_step "Generating the WorkBuddy config"

    # Consistently use the selected Node.js (system or official download; neither is IDE-bundled, both have fixed paths)
    local default_node node_exe
    node_exe="${NODE_EXE:-}"
    [ -z "$node_exe" ] && node_exe="$(command -v node 2>/dev/null)"
    if [ -z "$node_exe" ]; then
        # Try common paths
        for p in /usr/local/bin/node /opt/homebrew/bin/node /usr/bin/node; do
            if [ -x "$p" ]; then node_exe="$p"; break; fi
        done
    fi

    local dist_js="${INSTALL_DIR}/dist/index.js"
    local written=false

    # Write directly into the platform's mcp.json (using the selected Node.js)
    if $DETECTED_WB; then
        write_mcp_config_file "$HOME/.workbuddy" "$node_exe" "$dist_js"
        log_ok "MCP config written: ~/.workbuddy/mcp.json"
        log_info "Click 'Trust' for ip-switch in the WorkBuddy connector management page to enable it"
        written=true
    fi

    if $DETECTED_CODEX; then
        write_mcp_config_file "$HOME/.codex" "$node_exe" "$dist_js"
        log_ok "MCP config written: ~/.codex/mcp.json"
        log_info "Restart Codex for the config to take effect"
        written=true
    fi

    if ! $written; then
        local json_content
        json_content=$(cat <<EOF_CONFIG
{
  "mcpServers": {
    "ip-switch": {
      "command": "${node_exe}",
      "args": ["${dist_js}"]
    }
  }
}
EOF_CONFIG
)
        log_warn "WorkBuddy or Codex platform directory not detected"
        echo ""
        echo "${CYAN}MCP config content:${NC}"
        echo "$json_content"
        echo ""
        log_info  "Manually add the config above to the corresponding client's mcp.json"
    fi
}



# -- Generate the Codex MCP direct config (INSTALL_DIR/.mcp.json) --------------------------------
# Split out of install_codex_toml as a standalone function:
#   (1) probe/validate Node.js (prefer $NODE_EXE, fall back to node on PATH)
#   (2) validate that the build output INSTALL_DIR/dist/index.js exists
#   (3) generate INSTALL_DIR/.mcp.json (full paths, overwriting the fragile command:"node" version shipped in the repo)
# Also store the final node / dist paths in global variables for install_codex_toml to reuse.
install_codex_mcp() {
    log_step "Generating the Codex MCP direct config (.mcp.json)"

    local dist_js="${INSTALL_DIR}/dist/index.js"
    local codex_node="${NODE_EXE:-}"
    [ -z "$codex_node" ] && codex_node="$(command -v node 2>/dev/null)"
    if [ -z "$codex_node" ]; then
        log_error "Node.js not found; cannot generate the Codex MCP config"
        exit 1
    fi

    # 1. Validate that the build output exists
    if [ ! -f "$dist_js" ]; then
        log_error "Build output missing: ${dist_js}; build first"
        exit 1
    fi

    # 2. Generate INSTALL_DIR/.mcp.json (full paths, overwriting the fragile command:"node" version shipped in the repo)
    cat > "${INSTALL_DIR}/.mcp.json" <<EOF
{
  "mcpServers": {
    "ip-switch": {
      "command": "${codex_node}",
      "args": ["${dist_js}"],
      "cwd": "${INSTALL_DIR}",
      "startup_timeout_sec": 30,
      "tool_timeout_sec": 300
    }
  }
}
EOF
    log_ok "MCP config generated: ${INSTALL_DIR}/.mcp.json"

    # 3. Expose for the later TOML config layer (global variables, visible across functions)
    CODEX_MCP_DIST="$dist_js"
    CODEX_MCP_NODE="$codex_node"
}

# -- Install the Codex user-level config (the only stable globally-visible channel) --
# Responsibility: register ip-switch into the user-level ~/.codex/config.toml
#       （[marketplaces.local] + [plugins."ip-switch@local"] + [mcp_servers.ip-switch]）。
# This is the single data source for desktop Codex's "plugin list / MCP list" -- the global UI only reads the user-level config,
# never project-level or Profile configs; CC Switch does not manage these tables, so writes are safe and survive restarts.
# Older versions additionally generated (1) a project-level .codex/config.toml and (2) a Profile ip-switch.config.toml,
# but neither adds value to the actual desktop flow (project-level never enters the global list and its trust entries are easily wiped
# by CC Switch; Profile only works with codex --profile, is not loaded by desktop, and its separate-file mechanism is unverified). Removed; user-level registration is the single source of truth.
install_codex_toml() {
    log_step "Installing the Codex user-level config (the only stable globally-visible channel)"

    # The only stable channel = registration in the user-level ~/.codex/config.toml (marketplaces + plugins + mcp).
    # Desktop's "plugin list / MCP list" reads only this; CC Switch does not manage these tables, so it is safe.
    local codex_dir="$HOME/.codex"
    append_codex_user_config "$codex_dir/config.toml"
}

# -- Ensure the user-level Codex config.toml registers the local marketplace, plugin, and ip-switch MCP (globally visible) ------
# Key distinction (this was the root cause of the previous version's "plugin list empty after reinstall"):
#   - model is managed by CC Switch -> do not write it to the user-level config.toml
#   - marketplaces / plugins are not managed by CC Switch (no matching SSOT table) -> safe to write at user level,
#     and only written here does desktop Codex discover ip-switch when opened in ANY workspace.
#   - [mcp_servers.ip-switch] belongs to the CC Switch-managed tier A (regenerated on restart), but this function
#     idempotently appends the section using $CODEX_MCP_NODE / $CODEX_MCP_DIST / $INSTALL_DIR
#     already resolved by install_codex_mcp:
#       - if CC Switch already wrote it -> grep matches -> skip (avoids duplicate TOML tables)
#       - if CC Switch is not running -> the section is absent -> the script writes it, keeping ip-switch visible in the MCP list
#     This way the user-level registration no longer depends on whether CC Switch is running.
#   (If a project-level .codex/config.toml declaration is added manually later, it is only loaded in workspace scope,
#    not when Codex is opened normally; global visibility always comes from the user-level registration.)
# Only detect missing items and append; no backup/restore.
append_codex_user_config() {
    local codex_config="$1"
    if [ ! -f "$codex_config" ]; then
        log_info "${codex_config} not found; skipping marketplace/plugin/MCP registration (created automatically on the first codex run)"
        return 0
    fi
    # Normalize the market dir to a Windows path (in Git Bash $HOME is /c/Users/...)
    local market_dir="$HOME/.codex/marketplaces/local"
    case "$market_dir" in
        /[a-z]/*)
            local drive="${market_dir:1:1}"
            local rest="${market_dir:2}"
            rest="${rest//\//\\}"
            market_dir="${drive}:${rest}"
            ;;
    esac
    local appended=""
    if ! grep -qF '[marketplaces.local]' "$codex_config"; then
        appended="${appended}"$'\n'"[marketplaces.local]"
        appended="${appended}"$'\n'"source_type = \"local\""
        appended="${appended}"$'\n'"source = '${market_dir}'"
    fi
    if ! grep -qF '[plugins."ip-switch@local"]' "$codex_config"; then
        appended="${appended}"$'\n'"[plugins.\"ip-switch@local\"]"
        appended="${appended}"$'\n'"enabled = true"
    fi
    # Idempotently append [mcp_servers.ip-switch]: uses the node/dist paths already resolved by install_codex_mcp
    if ! grep -qF '[mcp_servers.ip-switch]' "$codex_config"; then
        local mcp_node="$CODEX_MCP_NODE"
        local mcp_dist="$CODEX_MCP_DIST"
        local mcp_cwd="$INSTALL_DIR"
        if [ -n "$mcp_node" ] && [ -n "$mcp_dist" ] && [ -n "$mcp_cwd" ]; then
            appended="${appended}"$'\n'"[mcp_servers.ip-switch]"
            appended="${appended}"$'\n'"command = '${mcp_node}'"
            appended="${appended}"$'\n'"args = ['${mcp_dist}']"
            appended="${appended}"$'\n'"cwd = '${mcp_cwd}'"
            appended="${appended}"$'\n'"startup_timeout_sec = 30"
            appended="${appended}"$'\n'"enabled = true"
        else
            log_warn "Node/dist paths missing (prerequisite steps incomplete); skipping the user-level [mcp_servers.ip-switch] registration"
        fi
    fi
    if [ -z "$appended" ]; then
        log_info "The ip-switch marketplace, plugin, and MCP are already in the user-level config.toml; skipping"
        return 0
    fi
    printf '%s\n' "$appended" >> "$codex_config"
    log_ok "Registered the ip-switch marketplace, plugin, and mcp_servers into the user-level config.toml (globally visible; the mcp section is written by the script, no longer depending on CC Switch)"
}

# -- Create the desktop shortcut ---------------------------------------------------------
# Split out of install_codex_toml as a standalone function:
#   (1) copy the codex_app.vbs launcher (Windows-only; on Linux a codex_app.sh is generated instead)
#   (2) copy the codex.ico icon file
#   (3) generate codex_app.sh (starts the ip-switch service and launches the codex app with INSTALL_DIR as workspace)
#   (4) create a .desktop shortcut
install_codex_shotcut() {
    log_step "Creating the desktop shortcut"

    # Desktop dir: prefer xdg-user-dir (Linux), fall back to ~/Desktop (macOS/default)
    local desktop_dir=""
    if command -v xdg-user-dir >/dev/null 2>&1; then
        desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null)"
    fi
    [ -n "$desktop_dir" ] || desktop_dir="$HOME/Desktop"

    # Copy the launcher script (source is the script's own directory; vbs is Windows-only, on Linux a codex_app.sh is generated instead)
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    local vbs_path="$INSTALL_DIR/codex_app.vbs"
    if [ -f "$script_dir/codex_app.vbs" ]; then
        cp -f "$script_dir/codex_app.vbs" "$vbs_path" 2>/dev/null && chmod +x "$vbs_path" 2>/dev/null
        log_ok "Copied codex_app.vbs to ${vbs_path}"
    elif [ ! -f "$vbs_path" ]; then
        log_warn "codex_app.vbs not found"
    fi

    # Copy the icon file
    local icon_path="$INSTALL_DIR/codex.ico"
    if [ -f "$script_dir/codex.ico" ]; then
        cp -f "$script_dir/codex.ico" "$icon_path" 2>/dev/null
        log_ok "Copied codex.ico to ${icon_path}"
    elif [ ! -f "$icon_path" ]; then
        log_warn "codex.ico not found; the default icon will be used"
    fi

    # Generate the Linux/macOS launcher (equivalent of codex_app.vbs: start the ip-switch service, then launch Codex)
    # The desktop app cannot receive a -c override (parameters are lost on protocol launch), so launch with INSTALL_DIR as the workspace.
# Global visibility is handled by the user-level ~/.codex/config.toml (written by append_codex_user_config),
# no longer by a project-level .codex/config.toml in the workspace (that file is no longer generated).
    local launcher="$INSTALL_DIR/codex_app.sh"
    cat > "$launcher" <<EOF
#!/bin/bash
# Codex launcher (Linux/macOS) - starts the ip-switch service and launches Codex with this directory as workspace
# ip-switch's global visibility comes from the user-level ~/.codex/config.toml (registered by the install script); no project-level config needed in the workspace
cd "$INSTALL_DIR" 2>/dev/null || exit 1
if ! pgrep -f "node .*ip-switch" >/dev/null 2>&1; then
    nohup node dist/index.js >/dev/null 2>&1 &
fi
sleep 2
exec codex app "$INSTALL_DIR"
EOF
    chmod +x "$launcher"
    log_ok "Launcher script generated: ${launcher}"

    # Create the desktop shortcut
    local desktop_file="$desktop_dir/Codex with ip-switch.desktop"
    mkdir -p "$desktop_dir" 2>/dev/null || true
    cat > "$desktop_file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Codex with ip-switch
Comment=Launch Codex and auto-load the ip-switch MCP service
Exec=${launcher}
Path=${INSTALL_DIR}
Icon=${icon_path}
Terminal=false
Categories=Development;Utility;
EOF
    chmod +x "$desktop_file"
    log_ok "Desktop shortcut created: ${desktop_file}"
}

# -- Install the Codex plugin marketplace so ip-switch is discoverable in the plugin page/marketplace ------
install_codex_marketplace() {
    log_step "Installing the Codex plugin marketplace (ip-switch)"

    local codex_root="$HOME/.codex"
    local market_dir="$codex_root/marketplaces/local"
    local market_plugin_dir="$market_dir/plugins/ip-switch/.codex-plugin"

    # 1. Marketplace manifest marketplace.json (modeled on Codex's built-in openai-bundled format)
    #    Note: the plugin package only carries the manifests + .mcp.json; no bundled skill copy anymore --
    #    the skill is provided by the standalone ~/.codex/skills/ip-switch/ channel, avoiding dual-channel duplication
    mkdir -p "$market_dir/.agents/plugins" "$market_plugin_dir"
    cp "$INSTALL_DIR/.mcp.json" "$market_dir/plugins/ip-switch/.mcp.json"
    cat > "$market_dir/.agents/plugins/marketplace.json" <<'EOF_MARKET'
{
  "name": "local",
  "interface": {
    "displayName": "IP Switch"
  },
  "plugins": [
    {
      "name": "ip-switch",
      "source": {
        "source": "local",
        "path": "./plugins/ip-switch"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Developer Tools"
    }
  ]
}
EOF_MARKET

    # 2. In-market plugin manifest plugin.json (mcpServers points to the package's .mcp.json)
    cat > "$market_plugin_dir/plugin.json" <<EOF_PLUGIN
{
  "name": "ip-switch",
  "version": "1.0.0",
  "description": "Multi-cloud public IP switch MCP server with Cloudflare DNS auto-update",
  "author": {
    "name": "areyi2014",
    "url": "https://github.com/areyi2014/ip-switch"
  },
  "homepage": "https://github.com/areyi2014/ip-switch",
  "repository": "https://github.com/areyi2014/ip-switch.git",
  "license": "MIT",
  "keywords": [
    "mcp",
    "ip-switch",
    "cloud",
    "aws",
    "azure",
    "oci",
    "vultr",
    "cloudflare",
    "dns"
  ],
  "mcpServers": "./.mcp.json",
  "interface": {
    "displayName": "IP Switch",
    "shortDescription": "Multi-cloud IP switch & DNS update",
    "longDescription": "Switch the public IP of cloud instances across AWS / Azure / Oracle OCI / Vultr and automatically update Cloudflare DNS A records. Exposes 13 MCP tools for one-click IP rotation, instance management, and DNS sync.",
    "developerName": "areyi2014",
    "category": "Developer Tools",
    "capabilities": [
      "Cloud",
      "Network"
    ],
    "websiteURL": "https://github.com/areyi2014/ip-switch",
    "defaultPrompt": [
      "Add an AWS profile in the IP Switch UI",
      "Use IP Switch to rotate the public IP of a cloud instance and update its Cloudflare DNS record.",
      "Use IP Switch to query instance info or list instances in a cloud region."
    ]
  }
}
EOF_PLUGIN
    log_ok "Marketplace manifest written: ${market_dir}/.agents/plugins/marketplace.json"
    log_ok "Plugin manifest written: ${market_plugin_dir}/plugin.json"

    # 3. This function only writes the manifest files (marketplace.json / plugin.json).
    #    The [marketplaces.local] + [plugins."ip-switch@local"] + [mcp_servers.ip-switch] registration in config.toml
    #    is handled by append_codex_user_config (user-level, the only stable channel), not here.
    log_ok "Codex plugin manifests written (the config.toml registration is done by append_codex_user_config)"

    # 5. Verify
    if [ -f "$market_dir/.agents/plugins/marketplace.json" ] && [ -f "$market_plugin_dir/plugin.json" ]; then
        log_ok "Codex plugin marketplace installed: ${market_dir}"
        log_info "After restarting Codex, IP Switch appears in the plugin page/marketplace"
    else
        log_error "Marketplace installation incomplete; check ${market_dir}"
        exit 1
    fi
}

# -- Install the ip-switch skill (WorkBuddy / Codex / any AI agent can open the config page) ----
# Responsibilities:
#   1. Flatten SKILL.md / skill.json (project root) + scripts/ (icon + scripts) into
#      ~/.workbuddy/skills/ip-switch/ (auto-discovered by WorkBuddy)
#   2. Create the <install-dir>/data/ runtime directory (replacing the old ~/.ip-switch/)
#   3. Write INSTALL_DIR into the user-level copy's scripts/.install-path.txt (bootstrap anchor)
#   4. Write <install-dir>/data/install-dir.txt (runtime config, used by --status)
#   5. Mark scripts executable (+x on .sh / .mjs / .ps1 so the Codex CLI can invoke them)
# Design:
#   - Idempotent: overwrites on rerun (run again after git pull to get the new version)
#   - Unconditional install: installs even when WorkBuddy is not detected, so users can run it manually from a terminal (Codex has no skill mechanism)
#   - Also write to ~/.codex/skills/ (if that directory exists) -- ready to use if Codex supports skills later
install_skill() {
    log_step "Installing the ip-switch skill (AI-agent config page launcher)"

    local scripts_src="$INSTALL_DIR/scripts"
    if [ ! -d "$scripts_src" ]; then
        log_warn "Skill scripts directory not found: ${scripts_src} (skipping the skill install)"
        return 0
    fi

    # 1. Create the <install-dir>/data/ runtime directory (replacing the old ~/.ip-switch/)
    mkdir -p "$INSTALL_DIR/data"
    # In Git Bash /c/Users/foo -> C:\Users\foo (a more stable Windows path, easier to trace)
    local marker_dir_unix="$INSTALL_DIR"
    case "$marker_dir_unix" in
        /[a-z]/*)
            local _drive _rest
            _drive="${marker_dir_unix:1:1}"
            _rest="${marker_dir_unix:2}"
            _rest="${_rest//\//\\}"
            marker_dir_unix="${_drive}:${_rest}"
            ;;
    esac
    printf '%s\n' "$marker_dir_unix" > "$INSTALL_DIR/data/install-dir.txt"
    log_ok "install-dir marker written: ${INSTALL_DIR}/data/install-dir.txt -> ${marker_dir_unix}"

    # 2. Copy to the target location (WorkBuddy discovers via a flat scan of ~/.workbuddy/skills/<name>/)
    #    Sources: project-root SKILL.md / skill.json + scripts/ + references/ (multilingual docs)
    #    Target layout:
    #       ~/.workbuddy/skills/ip-switch/
    #       ├── SKILL.md
    #       ├── skill.json
    #       ├── .install-path.txt        <- bootstrap anchor (contains the absolute INSTALL_DIR path)
    #       ├── scripts/                 <- kept as a subdirectory (not flattened)
    #       │   ├── _icon.svg
    #       │   ├── open-ui.mjs
    #       │   ├── open-ui.sh
    #       │   └── open-ui.ps1
    #       └── references/              <- multilingual docs (zh.md etc.), loaded on demand
    local dest="$HOME/.workbuddy/skills/ip-switch"
    mkdir -p "$dest/scripts"

    # 2a. Root skill metadata (SKILL.md / skill.json) -> target root
    for f in SKILL.md skill.json; do
        if [ -f "$INSTALL_DIR/$f" ]; then
            if ! cp -f "$INSTALL_DIR/$f" "$dest/" 2>/dev/null; then
                log_error "Failed to copy $f: $INSTALL_DIR/$f -> $dest"
                return 1
            fi
        else
            log_warn "Root file not found: $INSTALL_DIR/$f (skipping)"
        fi
    done

    # 2b. The whole scripts/ subdirectory -> the target scripts/ subdirectory (name preserved)
    if cp -R "$scripts_src/." "$dest/scripts/" 2>/dev/null; then
        log_ok "Skill installed: ${dest} (with scripts/ subdirectory)"
    else
        log_error "Failed to copy scripts: $scripts_src -> $dest/scripts"
        return 1
    fi

    # 2b-2. references/ subdirectory (multilingual docs, e.g. zh.md) -> the target references/ subdirectory
    local refs_src="$INSTALL_DIR/references"
    if [ -d "$refs_src" ]; then
        mkdir -p "$dest/references"
        if cp -R "$refs_src/." "$dest/references/" 2>/dev/null; then
            log_ok "Skill multilingual docs installed: ${dest}/references/"
        else
            log_warn "Failed to copy references: $refs_src -> $dest/references (skipping; no functional impact)"
        fi
    fi

    # 2c. Bootstrap anchor: write the absolute INSTALL_DIR path under the user-level copy's scripts/
    #    open-ui.mjs reads this file first at startup to locate the ip-switch project
    #    Placed under scripts/ (next to open-ui.mjs) to avoid confusion
    printf '%s\n' "$marker_dir_unix" > "$dest/scripts/.install-path.txt"
    log_ok "Bootstrap anchor written: ${dest}/scripts/.install-path.txt"

    # 3. Mark the scripts in scripts/ executable (required on macOS/Linux/Git Bash)
    find "$dest/scripts" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.mjs" -o -name "*.ps1" \) -exec chmod +x {} \;
    log_ok "Executable bit set: ${dest}/scripts/"

    # 4. If ~/.codex/skills already exists (Codex may support skills later), copy a mirror there too
    #    Only copy when the directory already exists, avoiding creating it for non-Codex users
    if [ -d "$HOME/.codex/skills" ]; then
        local codex_dest="$HOME/.codex/skills/ip-switch"
        mkdir -p "$codex_dest/scripts"
        for f in SKILL.md skill.json; do
            [ -f "$INSTALL_DIR/$f" ] && cp -f "$INSTALL_DIR/$f" "$codex_dest/" 2>/dev/null
        done
        cp -R "$scripts_src/." "$codex_dest/scripts/" 2>/dev/null
        # The Codex mirror also carries the references/ multilingual docs
        if [ -d "$INSTALL_DIR/references" ]; then
            mkdir -p "$codex_dest/references"
            cp -R "$INSTALL_DIR/references/." "$codex_dest/references/" 2>/dev/null
        fi
            # The Codex mirror copy also needs the bootstrap anchor (placed under scripts/)
            printf '%s\n' "$marker_dir_unix" > "$codex_dest/scripts/.install-path.txt"
            find "$codex_dest/scripts" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.mjs" -o -name "*.ps1" \) -exec chmod +x {} \; 2>/dev/null
            log_ok "Mirrored to Codex: ${codex_dest}/scripts/ (takes effect if Codex enables skills)"
    fi

    log_info "How AI agents open it:"
    log_info "  WorkBuddy: say \"Open the ip-switch config page\", \"Add an AWS account\", etc. in the chat"
    log_info "  Any terminal: node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs [aws|azure|oci|vultr]"
}

# -- Post-install summary ------------------------------------------------------------------
print_success() {
    # Show paths for the actually installed platforms (WorkBuddy has no plugin dir, only mcp.json)
    local wb_config="$HOME/.workbuddy/mcp.json"
    local codex_market_dir="$HOME/.codex/marketplaces/local"
    local browser_cmd
    if [ "$OS" = "macos" ]; then
        browser_cmd="open [URL shown after the server starts]"
    else
        browser_cmd="xdg-open [URL shown after the server starts]"
    fi

    local mcp_hint=""
    if $DETECTED_WB && $DETECTED_CODEX; then
        mcp_hint="  # Use via MCP tools (just chat in WorkBuddy/Codex)"
    elif $DETECTED_WB; then
        mcp_hint="  # Use via MCP tools (just chat in WorkBuddy)"
    elif $DETECTED_CODEX; then
        mcp_hint="  # Use via MCP tools (just chat in Codex)"
    else
        mcp_hint="  # After configuring the MCP client, use these commands via chat"
    fi

    # Dynamically build the "install locations" and "uninstall commands" (only show installed platforms)
    local install_locations=""
    if $DETECTED_WB; then
        install_locations="${install_locations}WorkBuddy MCP config: ${wb_config}
"
    fi
    if $DETECTED_CODEX; then
        install_locations="${install_locations}Codex marketplace manifest: ${codex_market_dir}
Codex user-level registration: ~/.codex/config.toml (globally visible, written by append_codex_user_config)
"
    fi
    # Skill path (installed unconditionally; shown in the native format of the current OS)
    local skill_path_win skill_path_unix
    skill_path_unix="$HOME/.workbuddy/skills/ip-switch"
    case "$skill_path_unix" in
        /[a-z]/*)
            local _drive="${skill_path_unix:1:1}"
            local _rest="${skill_path_unix:2}"
            _rest="${_rest//\//\\}"
            skill_path_win="${_drive}:${_rest}"
            ;;
        *) skill_path_win="$skill_path_unix" ;;
    esac
    install_locations="${install_locations}ip-switch skill: ${skill_path_unix}
                       (auto-discovered by WorkBuddy; from any terminal: node ${skill_path_unix}/scripts/open-ui.mjs)
"

    local uninstall_cmds=""
    if $DETECTED_WB; then
        uninstall_cmds="${uninstall_cmds}  rm -f ${wb_config}            # remove the WorkBuddy MCP config
"
    fi
    if $DETECTED_CODEX; then
        uninstall_cmds="${uninstall_cmds}  rm -rf ${codex_market_dir}       # remove the Codex marketplace manifests
"
    fi
    # Skill uninstall command
    uninstall_cmds="${uninstall_cmds}  rm -rf ${skill_path_unix}      # remove the ip-switch skill
"

    cat <<EOF

${GREEN}╔══════════════════════════════════════════════════════════╗
║          ip-switch installed successfully!    ║
╚══════════════════════════════════════════════════════════╝${NC}

${install_locations}UI server:  node ${INSTALL_DIR}/ui/server.cjs
UI URL:     printed to the terminal when the server starts

${YELLOW}Usage:${NC}
  # Start the UI config server (optional)
  node ${INSTALL_DIR}/ui/server.cjs

  # Open the config page in a browser
  ${browser_cmd}

${mcp_hint}
  - List profiles:  "List my cloud server profiles"
  - Rotate IPs:     "Rotate the IPs of all configured servers"
  - Add a profile:  "I want to add an AWS profile"

${YELLOW}Manual update:${NC}
  cd ${INSTALL_DIR} && git pull && npm install && npm run build

${YELLOW}Uninstall:${NC}
${uninstall_cmds}  rm -rf ${INSTALL_DIR}      # remove the source (optional; wipes the data/ subdirectory too)
  rm -rf ${INSTALL_DIR}/data         # remove runtime data only (keep the source)

${YELLOW}Restart the client:${NC}
EOF
    if $DETECTED_WB; then
        echo "  Restart WorkBuddy for the MCP config to take effect"
    fi
    if $DETECTED_CODEX; then
        echo "  Restart Codex to see IP Switch in the plugin page"
    fi
    echo ""
}

# -- Main flow ---------------------------------------------------------------------------
main() {
    echo ""
    echo "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo "${GREEN}║   ip-switch automated deployment script v1.0              ║${NC}"
    echo "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    detect_os
    check_npm
    check_git
    detect_mcp_platform
    clone_repo
    install_deps
    build_project
    if $DETECTED_WB; then
        generate_wb_config
    fi
    if $DETECTED_CODEX; then
        install_codex_mcp
        install_codex_toml
        install_codex_shotcut
        install_codex_marketplace
    fi
    # Skill install: a unified config-page launcher across WorkBuddy / Codex / any AI agent
    # Unconditional install (installs even when WorkBuddy is not detected; users can run it from a terminal)
    install_skill
    print_success

    log_ok "Deployment complete!"
}

# -- Command-line argument parsing -------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --repo-url)
            REPO_URL="$2"; shift 2;;
        --branch)
            BRANCH="$2"; shift 2;;
        --install-dir)
            INSTALL_DIR="$2"; shift 2;;
        --skip-build)
            SKIP_BUILD=true; shift;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --repo-url URL     Repository URL (default: gitee)"
            echo "  --branch NAME      Branch name (default: main)"
            echo "  --install-dir DIR  Install directory (default: ~/ip-switch)"
            echo "  --skip-build       Skip the build step"
            echo "  -h, --help         Show help"
            exit 0;;
        *)
            log_error "Unknown argument: $1"; exit 1;;
    esac
done

main
