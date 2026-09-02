#!/usr/bin/env bash
#===============================================================================
# ip-switch 自动部署脚本 (macOS / Ubuntu)
#===============================================================================
# 用途: 一键克隆、安装依赖、编译、生成 workbuddy 配置、生成 codex 配置[创建桌面图标]
# 适用: macOS 14+, Ubuntu 20.04+, Debian 11+
# 前提: git 已安装, Node.js >= 18 已安装
#===============================================================================
set -euo pipefail

# ── 颜色 ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 默认值 ───────────────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-https://gitee.com/areyi2014/ip-switch.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/ip-switch}"
NODE_MIN_VERSION=18
PROJECT_NAME="ip-switch"

# ── 辅助函数 ─────────────────────────────────────────────────────────────────
log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }

# ── OS 检测 ──────────────────────────────────────────────────────────────────
detect_os() {
    case "$(uname -s)" in
        Darwin)  OS="macos";;
        Linux)   OS="linux";;
        *)
            log_error "不支持的操作系统: $(uname -s)"
            log_info  "支持的操作系统: macOS, Ubuntu/Debian"
            exit 1
            ;;
    esac

    if [ "$OS" = "linux" ]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS="${ID}"  # ubuntu, debian, etc.
        fi
    fi
    log_ok "检测到操作系统: ${OS}"
}

# ── 检查 npm 环境 ─────────────────────────────────────────────────────────
# 不依赖 IDE 捆绑的 node（版本目录会随升级变化，难以排查）。
# 仅两条路径: ① 系统 PATH 有 node+npm → 直接用系统的；
#            ② 否则从 nodejs.org 官方下载独立 Node.js 到固定目录
#               ~/.ip-switch-node/node（路径固定、可排查，不污染系统）。
# 选定结果统一记录到 NODE_EXE / NPM_NODE / NPM_CLI，
# 供 npm 执行与 MCP 配置共用。
check_npm() {
    log_step "检查 npm 环境"

    if command -v node &>/dev/null && command -v npm &>/dev/null; then
        NODE_EXE="$(command -v node)"
        log_ok "使用系统 Node.js: ${NODE_EXE}"
        return 0
    fi

    install_npm_from_official
}

# ── 从 nodejs.org 官方下载独立 Node.js(含 npm) 到固定目录 ────────────────
install_npm_from_official() {
    log_warn "未找到系统 Node.js，正在从 nodejs.org 下载 Node.js 22 LTS..."

    # 解析最新 v22.x 版本号（失败时用固定 LTS 兜底）
    local ver=""
    ver=$(curl -fsSL --max-time 30 https://nodejs.org/dist/latest-v22.x/index.json 2>/dev/null |
          sed -n 's/.*"version":"\(v[^"]*\)".*/\1/p' | head -1)
    [ -z "$ver" ] && ver="v22.14.0"

    local dest="$HOME/.ip-switch-node"
    mkdir -p "$dest"
    local url tmp
    case "$(uname -s)" in
        Linux)
            case "$(uname -m)" in
                aarch64|arm64) url="https://nodejs.org/dist/${ver}/node-${ver}-linux-arm64.tar.xz" ;;
                *)             url="https://nodejs.org/dist/${ver}/node-${ver}-linux-x64.tar.xz" ;;
            esac
            tmp="$HOME/.ip-switch-node.tmp"
            curl -fL --max-time 120 -o "$tmp" "$url" || { log_error "下载失败: $url"; exit 1; }
            tar -xJf "$tmp" -C "$dest" --strip-components=1
            NPM_NODE="$dest/bin/node"
            NPM_CLI="$dest/lib/node_modules/npm/bin/npm-cli.js"
            ;;
        Darwin)
            case "$(uname -m)" in
                arm64) url="https://nodejs.org/dist/${ver}/node-${ver}-darwin-arm64.tar.gz" ;;
                *)     url="https://nodejs.org/dist/${ver}/node-${ver}-darwin-x64.tar.gz" ;;
            esac
            tmp="$HOME/.ip-switch-node.tmp"
            curl -fL --max-time 120 -o "$tmp" "$url" || { log_error "下载失败: $url"; exit 1; }
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
            tmp="$HOME/.ip-switch-node.tmp.zip"
            curl -fL --max-time 120 -o "$tmp" "$url" || { log_error "下载失败: $url"; exit 1; }
            local tmpdir="$HOME/.ip-switch-node.tmp"
            rm -rf "$tmpdir" && mkdir -p "$tmpdir"
            unzip -oq "$tmp" -d "$tmpdir" || { log_error "解压失败(需安装 unzip)"; exit 1; }
            # zip 解压出 node-<ver>-win-<arch>/ 子目录，统一固定为 node（路径稳定，便于排查）
            local d
            d=$(ls -1dt "$tmpdir"/*/ 2>/dev/null | head -1)
            rm -rf "$dest/node"
            mv "$d" "$dest/node"
            NPM_NODE="$dest/node/node.exe"
            NPM_CLI="$dest/node/node_modules/npm/bin/npm-cli.js"
            ;;
    esac
    [ -f "$NPM_CLI" ] || { log_error "npm 安装失败，请手动安装 Node.js: https://nodejs.org"; exit 1; }
    NODE_EXE="$NPM_NODE"
    log_ok "已安装 Node.js ${ver} (npm $("$NPM_NODE" "$NPM_CLI" --version 2>/dev/null)) -> $NPM_NODE"
}

# 执行 npm 命令: 优先官方下载(node <npm-cli.js>),回退 PATH npm
# 注意: npm run 的 lifecycle 脚本(node_modules/.bin/*)由 sh/cmd 执行并从 PATH
# 查找 node，因此把官方下载 node 目录临时置顶 PATH，避免系统 PATH 无 node 时报错。
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

# ── 检查 git ─────────────────────────────────────────────────────────────────
check_git() {
    log_step "检查 Git 环境"

    # 方案 1：已在 PATH 中
    if command -v git &>/dev/null; then
        log_ok "git $(git --version | awk '{print $3}') ($(command -v git))"
        return
    fi

    log_warn "未检测到 git，正在自动安装..."

    # ── CPU 架构 ────────────────────────────────────────────────────
    local arch
    arch=$(uname -m)
    log_info "检测到 CPU 架构: ${arch}"

    # ── 方案 2：已安装但不在 PATH ──────────────────────────────────
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
            log_info "检测到已有 Git: ${found_dir}，修复 PATH..."
            export PATH="${found_dir}:${PATH}"
            log_ok "git $(git --version | awk '{print $3}') (${kp})"
            return
        fi
    done

    # ── 方案 3：通过包管理器安装 ────────────────────────────────────
    case "$OS" in
        ubuntu|debian)
            log_info "通过 apt 安装 git..."
            # 尝试换阿里云镜像加速
            if [ -f /etc/apt/sources.list ] && ! grep -q "mirrors.aliyun.com" /etc/apt/sources.list 2>/dev/null; then
                log_info "建议切换至国内镜像源以加速: sudo sed -i 's|archive.ubuntu.com|mirrors.aliyun.com|g' /etc/apt/sources.list"
            fi
            if command -v sudo &>/dev/null; then
                sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git
            else
                apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git
            fi
            ;;
        macos)
            if command -v brew &>/dev/null; then
                log_info "通过 Homebrew 安装 git..."
                brew install git --quiet
            elif command -v xcode-select &>/dev/null; then
                log_info "通过 xcode-select 安装 Command Line Tools（包含 git）..."
                xcode-select --install 2>/dev/null || true
                log_warn "xcode-select 弹出安装窗口，请手动完成安装后重新运行脚本"
                exit 1
            else
                log_error "未找到包管理器，请手动安装 git"
                log_info  "  macOS:  xcode-select --install"
                exit 1
            fi
            ;;
        *)
            log_error "未检测到 git，请手动安装"
            log_info  "  https://git-scm.com/downloads"
            exit 1
            ;;
    esac

    # ── 安装后验证 ──────────────────────────────────────────────────
    if command -v git &>/dev/null; then
        log_ok "git 安装完成: $(git --version)"
    else
        log_error "git 安装失败，请手动安装"
        log_info  "  macOS:  xcode-select --install 或 brew install git"
        log_info  "  Ubuntu: sudo apt-get install -y git"
        log_info  "  https://git-scm.com/downloads"
        exit 1
    fi
}

# ── 克隆仓库 ─────────────────────────────────────────────────────────────────
clone_repo() {
    log_step "克隆项目仓库"

    if [ -d "$INSTALL_DIR/.git" ]; then
        log_warn "目标目录已存在，执行 git pull 更新..."
        cd "$INSTALL_DIR"
        git fetch origin "$BRANCH"
        git checkout "$BRANCH"
        git pull origin "$BRANCH"
        log_ok "项目已更新: $INSTALL_DIR"
        return
    fi

    # 确认安装目录
    log_info "仓库地址: ${REPO_URL}"
    log_info "目标分支: ${BRANCH}"
    log_info "安装目录: ${INSTALL_DIR}"
    echo ""
    read -r -p "确认安装到此目录? 按 Enter 确认，或输入新目录路径: " user_dir
    if [ -n "$user_dir" ]; then
        INSTALL_DIR="$user_dir"
        log_info "已更新安装目录: ${INSTALL_DIR}"
    fi

    # DNS 预热
    local repo_host
    repo_host=$(echo "$REPO_URL" | sed -E 's|^https?://||;s|^git@||;s|:.*||;s|/.*||')
    log_info "预热 DNS: ping ${repo_host} ..."
    if ! ping -c 1 -W 3 "$repo_host" >/dev/null 2>&1; then
        log_error "无法解析仓库域名: ${repo_host}"
        log_info  "请检查网络连接和 DNS 设置"
        exit 1
    fi
    log_ok "域名连通: ${repo_host}"

    # 最多重试 3 次克隆
    local max_retries=3
    local clone_ok=false

    for attempt in $(seq 1 $max_retries); do
        if [ "$attempt" -gt 1 ]; then
            rm -rf "$INSTALL_DIR" 2>/dev/null
            log_info "第 ${attempt} / ${max_retries} 次重试克隆..."
            sleep 3
        else
            log_info "正在克隆: ${REPO_URL} (分支: ${BRANCH})"
        fi

        # git 的进度条（Receiving objects 等）输出到 stderr，2>&1 让它直接显示在终端
        git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>&1 && {
            clone_ok=true
            break
        }

        log_warn "克隆失败 (第 ${attempt} / ${max_retries} 次)"
    done

    if ! $clone_ok; then
        echo ""
        log_error "克隆失败（已重试 ${max_retries} 次）"
        log_info ""
        log_info "请检查:"
        log_info "  1. 仓库地址是否正确: ${REPO_URL}"
        log_info "  2. 网络是否正常"
        log_info "  3. 如为私有仓库，请先配置 SSH Key"
        log_info ""
        log_info "手动操作:"
        log_info "  git clone ${REPO_URL} ${INSTALL_DIR}"
        exit 1
    fi
    log_ok "克隆成功: ${INSTALL_DIR}"
}

# ── 安装依赖 ─────────────────────────────────────────────────────────────────
install_deps() {
    log_step "安装 npm 依赖"

    cd "$INSTALL_DIR"

    if [ ! -f package.json ]; then
        log_error "未找到 package.json，项目结构异常"
        exit 1
    fi

    log_info "正在安装依赖，请稍候..."
    if run_npm install --loglevel=error; then
        log_ok "依赖安装完成"
    else
        log_error "依赖安装失败"
        log_info  "尝试清除缓存后重试: cd ${INSTALL_DIR} && rm -rf node_modules && npm install"
        exit 1
    fi
}

# ── 编译 TypeScript ──────────────────────────────────────────────────────────
build_project() {
    log_step "编译 TypeScript"

    cd "$INSTALL_DIR"

    # 清除 Electron 环境变量干扰（WorkBuddy 环境可能设置）
    local env_prefix=""
    if [ -n "${ELECTRON_RUN_AS_NODE:-}" ]; then
        log_warn "检测到 ELECTRON_RUN_AS_NODE 环境变量，编译时临时清除"
        env_prefix="env -u ELECTRON_RUN_AS_NODE -u NODE_OPTIONS"
    fi

    log_info "正在编译..."
    if $env_prefix run_npm run build 2>&1; then
        log_ok "编译完成"
    else
        log_error "编译失败"
        if [ -n "$NPM_CLI" ]; then
            log_info "手动编译: cd ${INSTALL_DIR} && env -u ELECTRON_RUN_AS_NODE \"$NPM_NODE\" \"$NPM_CLI\" run build"
        else
            log_info "手动编译: cd ${INSTALL_DIR} && env -u ELECTRON_RUN_AS_NODE npm run build"
        fi
        exit 1
    fi

    # 验证编译产物
    if [ -f "$INSTALL_DIR/dist/index.js" ]; then
        log_ok "验证通过: dist/index.js 已生成"
    else
        log_error "编译产物缺失: dist/index.js 不存在"
        exit 1
    fi
}

# ── 检测 MCP 客户端平台 ─────────────────────────────────────────────────────
detect_mcp_platform() {
    log_step "检测 MCP 客户端平台"

    DETECTED_WB=false
    DETECTED_CODEX=false

    # WorkBuddy: 检查目录或 mcp.json 是否存在
    if [ -d "$HOME/.workbuddy" ]; then
        DETECTED_WB=true
        log_ok "检测到 WorkBuddy ($HOME/.workbuddy)"
    fi

    # Codex: 检查目录或二进制是否存在
    if [ -d "$HOME/.codex" ] || command -v codex &>/dev/null; then
        DETECTED_CODEX=true
        log_ok "检测到 Codex ($HOME/.codex)"
    fi

    if ! $DETECTED_WB && ! $DETECTED_CODEX; then
        log_warn "未检测到 WorkBuddy 或 Codex，将输出通用 MCP 配置"
    fi
}

# ── 写入 MCP 配置（合并到已有配置，node 序列化为标准 JSON）─────────────
write_mcp_config_file() {
    local target_dir="$1"
    local node_exe="$2"
    local dist_js="$3"
    local target_path="${target_dir}/mcp.json"

    mkdir -p "$target_dir"

    # 合并 + 序列化交给 node：保证输出标准 JSON（2 空格缩进、路径正确转义）
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
        log_error "写入 MCP 配置失败: ${target_path}"
        exit 1
    }
}

# ── 生成 WorkBuddy 配置 ────────────────────────────────────────────────────────────
generate_wb_config() {
    log_step "生成 Workbuddy 配置"

    # 统一使用选定 Node.js（系统或官方下载，均非 IDE 捆绑、路径固定可排查）
    local default_node node_exe
    node_exe="${NODE_EXE:-}"
    [ -z "$node_exe" ] && node_exe="$(command -v node 2>/dev/null)"
    if [ -z "$node_exe" ]; then
        # 尝试常见路径
        for p in /usr/local/bin/node /opt/homebrew/bin/node /usr/bin/node; do
            if [ -x "$p" ]; then node_exe="$p"; break; fi
        done
    fi

    local dist_js="${INSTALL_DIR}/dist/index.js"
    local written=false

    # 直接写入对应平台的 mcp.json（统一使用选定 Node.js）
    if $DETECTED_WB; then
        write_mcp_config_file "$HOME/.workbuddy" "$node_exe" "$dist_js"
        log_ok "已写入 MCP 配置: ~/.workbuddy/mcp.json"
        log_info "WorkBuddy 连接器管理页面点击「信任」ip-switch 即可使用"
        written=true
    fi

    if $DETECTED_CODEX; then
        write_mcp_config_file "$HOME/.codex" "$node_exe" "$dist_js"
        log_ok "已写入 MCP 配置: ~/.codex/mcp.json"
        log_info "重启 Codex 使配置生效"
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
        log_warn "未检测到 WorkBuddy 或 Codex 平台目录"
        echo ""
        echo "${CYAN}MCP 配置内容:${NC}"
        echo "$json_content"
        echo ""
        log_info  "请将以上配置手动添加到对应客户端的 mcp.json 文件中"
    fi
}



# ── 生成 Codex MCP 直连配置（INSTALL_DIR/.mcp.json） ───────────────────────────
# 从 install_codex_toml 拆出的独立函数：
#   ① 探测/校验 Node.js（优先 $NODE_EXE，回退 PATH 中的 node）
#   ② 校验编译产物 INSTALL_DIR/dist/index.js 存在
#   ③ 生成 INSTALL_DIR/.mcp.json（全路径写法，覆盖仓库自带的 command:"node" 脆弱版本）
# 并把最终选定的 node / dist 路径写入全局变量供 install_codex_toml 复用。
install_codex_mcp() {
    log_step "生成 Codex MCP 直连配置（.mcp.json）"

    local dist_js="${INSTALL_DIR}/dist/index.js"
    local codex_node="${NODE_EXE:-}"
    [ -z "$codex_node" ] && codex_node="$(command -v node 2>/dev/null)"
    if [ -z "$codex_node" ]; then
        log_error "未找到 Node.js，无法生成 Codex MCP 配置"
        exit 1
    fi

    # 1. 校验编译产物存在
    if [ ! -f "$dist_js" ]; then
        log_error "缺少编译产物 ${dist_js}，请先编译"
        exit 1
    fi

    # 2. 生成 INSTALL_DIR/.mcp.json（全路径写法，覆盖仓库自带的 command:"node" 脆弱版本）
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
    log_ok "已生成 MCP 配置: ${INSTALL_DIR}/.mcp.json"

    # 3. 输出供后续 TOML 配置层复用（全局变量跨函数可见）
    CODEX_MCP_DIST="$dist_js"
    CODEX_MCP_NODE="$codex_node"
}

# ── 安装 Codex TOML 配置层（项目级 + Profile 叠加层） ──
# 职责：
#   ① 生成 INSTALL_DIR/.mcp.json —— 已拆出为 install_codex_mcp 独立函数
#      （在主流程先于本函数执行；codex 自带 node 全路径，供市场插件 plugin.json 引用）
#   ② 生成 INSTALL_DIR/.codex/config.toml（项目级配置层 —— 桌面版的主要加载通道）
#      —— 桌面版 codex app 通过协议拉起，-c 参数传不进桌面进程，
#         只能读 ~/.codex/config.toml + 工作区内项目级 .codex/config.toml
#      —— 首次以该目录为工作区启动时 Codex 会自动信任，信任后本文件生效
#   ③ 创建 ~/.codex/ip-switch.config.toml（Profile 叠加层，CLI 专用）
#      —— 用于 codex --profile ip-switch CLI 命令（mcp list / exec / review 等）
#   ④ 清理旧版 ~/.codex/plugins/ip-switch 残留
#   ⑤ 桌面快捷方式已拆出为 install_codex_shotcut 独立函数（在主流程执行）
#      —— codex_app.sh 以 INSTALL_DIR 为工作区启动 codex app
# 注：插件页发现/安装由 install_codex_marketplace 负责，本函数不重复。
# 注：②③两份配置互为镜像；均独立于 config.toml，CC Switch 不影响。
install_codex_toml() {
    log_step "安装 Codex TOML 配置层（项目级 + Profile）"

    # 1. 取 install_codex_mcp 的输出（该函数在主流程先于本函数执行）
    local dist_js="$CODEX_MCP_DIST"
    local codex_node="$CODEX_MCP_NODE"

    local codex_dir="$HOME/.codex"
    local market_dir="$codex_dir/marketplaces/local"
    mkdir -p "${INSTALL_DIR}/.codex"

    # 公共配置主体 —— 项目级配置层与 Profile 叠加层的内容完全一致（互为镜像），
    # 仅文件位置、加载时机与用途不同：
    #   ① 项目级配置层（INSTALL_DIR/.codex/config.toml）→ 桌面版加载通道
    #   ② Profile 叠加层（~/.codex/ip-switch.config.toml）→ CLI --profile 加载通道
    # 统一维护这一份模板，避免两份配置内容漂移；TOML 中表顺序无关紧要。
    # 注意：这里是 shell heredoc，${dist_js} / ${codex_node} / ${INSTALL_DIR} / ${market_dir} 会被展开。
    local ip_switch_config_body
    ip_switch_config_body=$(cat <<EOF
[mcp_servers.ip-switch]
args = ['${dist_js}']
command = '${codex_node}'
startup_timeout_sec = 30
cwd = '${INSTALL_DIR}'
enabled = true

[marketplaces.local]
source_type = "local"
source = '${market_dir}'

[plugins."ip-switch@local"]
enabled = true
EOF
)

    # 2. 生成项目级配置层（INSTALL_DIR/.codex/config.toml）—— 桌面版的主要加载通道
    #     桌面版 codex app 无法接收 -c 覆盖（协议拉起时参数丢失），
    #     只能通过「信任的工作区」内的项目级配置注册 ip-switch。
    #     codex_app.sh 已改为以 INSTALL_DIR 为工作区启动，首次启动自动信任。
    #     内容与 Profile 叠加层相同，共用 ip_switch_config_body（见上方模板说明）。
    cat > "${INSTALL_DIR}/.codex/config.toml" <<EOF
# ip-switch project-scoped config — layered on top of ~/.codex/config.toml
# Independent of user config.toml (CC Switch safe).
# Loaded by Codex when this workspace is opened and trusted.

${ip_switch_config_body}
EOF
    log_ok "已生成项目级配置层: ${INSTALL_DIR}/.codex/config.toml"
    log_info "桌面版 Codex 以本目录为工作区启动时自动加载（首次启动自动信任）"

    # 3. 创建 Codex Profile 叠加层（~/.codex/ip-switch.config.toml）
    #    独立于 config.toml，CC Switch 篡改 config.toml 不影响 ip-switch
    #    用途：codex --profile ip-switch CLI 命令（mcp list / exec / review 等）
    #    注意：codex app 子命令不支持 --profile；桌面版走上面的项目级配置层
    #    内容与项目级配置层相同，共用 ip_switch_config_body（见上方模板说明）。
    mkdir -p "$codex_dir"
    cat > "$codex_dir/ip-switch.config.toml" <<EOF
# ip-switch Profile — 独立于 config.toml 的叠加层
# CC Switch 只管 config.toml，此文件不受影响
# 用途：codex --profile ip-switch CLI 命令（mcp list / exec / review 等）
# 注意：codex app 子命令不支持 --profile；桌面版走工作区内 .codex/config.toml 项目级配置

${ip_switch_config_body}
EOF
    log_ok "已创建 Codex Profile 叠加层: ${codex_dir}/ip-switch.config.toml"
    log_info "CC Switch 篡改 config.toml 不再影响 ip-switch（独立叠加层）"

    # 4. 清理旧版 ~/.codex/plugins/ip-switch（曾导致插件页偶发重复发现 ip-switch）
    local legacy_dir="$HOME/.codex/plugins/ip-switch"
    if [ -d "$legacy_dir" ]; then
        log_info "清理旧版插件目录残留: ${legacy_dir}"
        rm -rf "$legacy_dir"
    fi

    # 5. 验证
    if [ -f "${INSTALL_DIR}/.mcp.json" ]; then
        log_ok "Codex MCP 直连配置已就绪: ${INSTALL_DIR}/.mcp.json"
        log_info "重启 Codex 后生效（插件页发现由市场负责）"
    else
        log_error "MCP 配置生成失败，请检查 ${INSTALL_DIR}/.mcp.json"
        exit 1
    fi
}

# ── 确保 Codex 用户级 config.toml 注册本地市场与插件（全局可见） ──────
# 关键区分（这是上一版"重装后插件列表看不到"的根因）：
#   • model / mcp_servers 由 CC Switch 管理 → 绝不能写用户级 config.toml
#   • marketplaces / plugins 不由 CC Switch 管理（SSOT 无对应表）→ 写用户级安全，
#     且只有写在这里，桌面版 Codex 在「任意工作区」打开时才能发现 ip-switch。
#   项目级 .codex/config.toml 里的同名声明是工作区作用域，普通打开 Codex 时不加载。
# 仅检测缺失项并追加，不做备份/恢复。
ensure_codex_user_config() {
    local codex_config="$1"
    if [ ! -f "$codex_config" ]; then
        log_info "未找到 ${codex_config}，跳过市场/插件注册（首次运行 codex 后会自动创建）"
        return 0
    fi
    # 归一化市场目录为 Windows 路径（Git Bash 下 $HOME 是 /c/Users/...）
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
    if [ -z "$appended" ]; then
        log_info "ip-switch 市场与插件已在用户级 config.toml 中，跳过"
        return 0
    fi
    printf '%s\n' "$appended" >> "$codex_config"
    log_ok "已注册 ip-switch 市场与插件到用户级 config.toml（全局可见，CC Switch 不管理该表）"
}

# ── 创建桌面快捷方式 ───────────────────────────────────────────────────────────
# 从 install_codex_toml 拆出的独立函数：
#   ① 复制 codex_app.vbs 启动脚本（Windows 专用；Linux 下另生成 codex_app.sh）
#   ② 复制 codex.ico 图标文件
#   ③ 生成 codex_app.sh（启动 ip-switch 服务并以 INSTALL_DIR 为工作区启动 codex app）
#   ④ 创建 .desktop 快捷方式
install_codex_shotcut() {
    log_step "创建桌面快捷方式"

    # 桌面目录：优先 xdg-user-dir（Linux），回退 ~/Desktop（macOS/默认）
    local desktop_dir=""
    if command -v xdg-user-dir >/dev/null 2>&1; then
        desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null)"
    fi
    [ -n "$desktop_dir" ] || desktop_dir="$HOME/Desktop"

    # 复制启动脚本（源取脚本所在目录；vbs 为 Windows 专用，Linux 下另生成 codex_app.sh）
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    local vbs_path="$INSTALL_DIR/codex_app.vbs"
    if [ -f "$script_dir/codex_app.vbs" ]; then
        cp -f "$script_dir/codex_app.vbs" "$vbs_path" 2>/dev/null && chmod +x "$vbs_path" 2>/dev/null
        log_ok "已复制 codex_app.vbs 到 ${vbs_path}"
    elif [ ! -f "$vbs_path" ]; then
        log_warn "未找到 codex_app.vbs 文件"
    fi

    # 复制图标文件
    local icon_path="$INSTALL_DIR/codex.ico"
    if [ -f "$script_dir/codex.ico" ]; then
        cp -f "$script_dir/codex.ico" "$icon_path" 2>/dev/null
        log_ok "已复制 codex.ico 到 ${icon_path}"
    elif [ ! -f "$icon_path" ]; then
        log_warn "未找到 codex.ico 图标文件，将使用默认图标"
    fi

    # 生成 Linux/macOS 版启动脚本（等价 codex_app.vbs：启动 ip-switch 服务后启动 Codex）
    # 桌面版无法接收 -c 覆盖（协议拉起时参数丢失），改为以 INSTALL_DIR 为工作区启动，
    # 让 Codex 自动信任工作区并加载其 .codex/config.toml 项目级配置
    local launcher="$INSTALL_DIR/codex_app.sh"
    cat > "$launcher" <<EOF
#!/bin/bash
# Codex launcher (Linux/macOS) - 启动 ip-switch 服务并以本目录为工作区启动 Codex
# 工作区内的 .codex/config.toml 注册 ip-switch MCP/市场/插件（首次启动自动信任）
cd "$INSTALL_DIR" 2>/dev/null || exit 1
if ! pgrep -f "node .*ip-switch" >/dev/null 2>&1; then
    nohup node dist/index.js >/dev/null 2>&1 &
fi
sleep 2
exec codex app "$INSTALL_DIR"
EOF
    chmod +x "$launcher"
    log_ok "已生成启动脚本: ${launcher}"

    # 创建桌面快捷方式
    local desktop_file="$desktop_dir/Codex with ip-switch.desktop"
    mkdir -p "$desktop_dir" 2>/dev/null || true
    cat > "$desktop_file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Codex with ip-switch
Comment=启动 Codex 并自动加载 ip-switch MCP 服务
Exec=${launcher}
Path=${INSTALL_DIR}
Icon=${icon_path}
Terminal=false
Categories=Development;Utility;
EOF
    chmod +x "$desktop_file"
    log_ok "已创建桌面快捷方式: ${desktop_file}"
}

# ── 安装 Codex 插件市场（marketplace），使插件页/市场中可发现 ip-switch ──────
install_codex_marketplace() {
    log_step "安装 Codex 插件市场（ip-switch）"

    local codex_root="$HOME/.codex"
    local market_dir="$codex_root/marketplaces/local"
    local market_plugin_dir="$market_dir/plugins/ip-switch/.codex-plugin"

    # 1. 市场清单 marketplace.json（参考 Codex 自带 openai-bundled 格式）
    mkdir -p "$market_dir/.agents/plugins" "$market_plugin_dir"
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

    # 2. 市场内插件清单 plugin.json（mcpServers 指向源码 .mcp.json 绝对路径）
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
  "mcpServers": "${INSTALL_DIR}/.mcp.json",
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
      "Use IP Switch to rotate the public IP of a cloud instance and update its Cloudflare DNS record.",
      "Use IP Switch to query instance info or list instances in a cloud region."
    ]
  }
}
EOF_PLUGIN
    log_ok "已写入市场清单: ${market_dir}/.agents/plugins/marketplace.json"
    log_ok "已写入插件清单: ${market_plugin_dir}/plugin.json"

    # 3. 市场注册已移至 Profile 叠加层（~/.codex/ip-switch.config.toml）
    #    不再写 config.toml，避免 CC Switch 篡改导致丢失
    log_ok "市场注册已在 Profile 叠加层中配置（ip-switch.config.toml）"

    # 5. 验证
    if [ -f "$market_dir/.agents/plugins/marketplace.json" ] && [ -f "$market_plugin_dir/plugin.json" ]; then
        log_ok "Codex 插件市场已安装: ${market_dir}"
        log_info "重启 Codex 后，插件页/市场中可见 IP Switch"
    else
        log_error "插件市场安装不完整，请检查 ${market_dir}"
        exit 1
    fi
}

# ── 安装完成后提示 ───────────────────────────────────────────────────────────
print_success() {
    # 按实际安装的平台显示路径（WorkBuddy 无插件目录，只有 mcp.json）
    local wb_config="$HOME/.workbuddy/mcp.json"
    local codex_market_dir="$HOME/.codex/marketplaces/local"
    local browser_cmd
    if [ "$OS" = "macos" ]; then
        browser_cmd="open [启动服务器后显示的地址]"
    else
        browser_cmd="xdg-open [启动服务器后显示的地址]"
    fi

    local mcp_hint=""
    if $DETECTED_WB && $DETECTED_CODEX; then
        mcp_hint="  # 通过 MCP 工具使用（在 WorkBuddy/Codex 中直接对话即可）"
    elif $DETECTED_WB; then
        mcp_hint="  # 通过 MCP 工具使用（在 WorkBuddy 中直接对话即可）"
    elif $DETECTED_CODEX; then
        mcp_hint="  # 通过 MCP 工具使用（在 Codex 中直接对话即可）"
    else
        mcp_hint="  # 配置 MCP 客户端后，即可通过对话使用以下指令"
    fi

    # 动态构建"安装位置"与"卸载命令"（只显示实际安装的平台）
    local install_locations=""
    if $DETECTED_WB; then
        install_locations="${install_locations}WorkBuddy MCP 配置: ${wb_config}
"
    fi
    if $DETECTED_CODEX; then
        install_locations="${install_locations}Codex 市场清单:     ${codex_market_dir}
Codex 项目级配置:   ${INSTALL_DIR}/.codex/config.toml（桌面版加载通道）
"
    fi

    local uninstall_cmds=""
    if $DETECTED_WB; then
        uninstall_cmds="${uninstall_cmds}  rm -f ${wb_config}            # 删除 WorkBuddy MCP 配置
"
    fi
    if $DETECTED_CODEX; then
        local profile_file="$HOME/.codex/ip-switch.config.toml"
        uninstall_cmds="${uninstall_cmds}  rm -f ${profile_file}     # 删除 Codex Profile 叠加层
  rm -rf ${INSTALL_DIR}/.codex       # 删除项目级配置层
  rm -rf ${codex_market_dir}       # 删除 Codex 市场清单
"
    fi

    cat <<EOF

${GREEN}╔══════════════════════════════════════════════════════════╗
║          ip-switch 安装成功!                  ║
╚══════════════════════════════════════════════════════════╝${NC}

${install_locations}UI 服务器:  node ${INSTALL_DIR}/ui/server.cjs
UI 地址:    启动后终端会显示实际地址

${YELLOW}使用方式:${NC}
  # 启动 UI 配置服务器（可选）
  node ${INSTALL_DIR}/ui/server.cjs

  # 浏览器打开配置页面
  ${browser_cmd}

${mcp_hint}
  - 列出配置:   "列出我的云服务器配置"
  - 轮换 IP:    "轮换所有配置好的服务器的IP"
  - 添加配置:   "我要添加一个 AWS 配置"

${YELLOW}手动更新:${NC}
  cd ${INSTALL_DIR} && git pull && npm install && npm run build

${YELLOW}卸载:${NC}
${uninstall_cmds}  rm -rf ${INSTALL_DIR}      # 删除源码（可选）
  rm -rf ~/.ip-switch

${YELLOW}重启客户端:${NC}
EOF
    if $DETECTED_WB; then
        echo "  重启 WorkBuddy 后 MCP 配置生效"
    fi
    if $DETECTED_CODEX; then
        echo "  重启 Codex 后插件页可见 IP Switch"
    fi
    echo ""
}

# ── 主流程 ───────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo "${GREEN}║   ip-switch 自动部署脚本 v1.0               ║${NC}"
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
        ensure_codex_user_config "$HOME/.codex/config.toml"
        install_codex_shotcut
        install_codex_marketplace
    fi
    print_success

    log_ok "部署完成!"
}

# ── 命令行参数解析 ──────────────────────────────────────────────────────────
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
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --repo-url URL     指定仓库地址（默认 gitee）"
            echo "  --branch NAME      指定分支（默认 main）"
            echo "  --install-dir DIR  指定安装目录（默认 ~/ip-switch）"
            echo "  --skip-build       跳过编译步骤"
            echo "  -h, --help         显示帮助"
            exit 0;;
        *)
            log_error "未知参数: $1"; exit 1;;
    esac
done

main
