#!/usr/bin/env bash
#===============================================================================
# cloud-ip-rotator-mcp 自动部署脚本 (macOS / Ubuntu)
#===============================================================================
# 用途: 一键克隆、安装依赖、编译、生成 MCP 配置
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
REPO_URL="${REPO_URL:-https://gitee.com/areyi2014/cloud-ip-rotator-mcp.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/cloud-ip-rotator-mcp}"
NODE_MIN_VERSION=18
PROJECT_NAME="cloud-ip-rotator-mcp"

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

# ── 检查 Node.js ─────────────────────────────────────────────────────────────
check_node() {
    log_step "检查 Node.js 环境"

    if ! command -v node &>/dev/null; then
        log_error "未检测到 Node.js，请先安装 Node.js >= ${NODE_MIN_VERSION}"
        log_info  "安装方式:"
        log_info  "  macOS:  brew install node@22"
        log_info  "  Ubuntu: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs"
        log_info  "  通用:   访问 https://nodejs.org/ 下载安装"
        exit 1
    fi

    local node_version
    node_version=$(node -v | sed 's/v//')
    local major
    major=$(echo "$node_version" | cut -d. -f1)

    if [ "$major" -lt "$NODE_MIN_VERSION" ]; then
        log_error "Node.js 版本过低: v${node_version}，需要 >= v${NODE_MIN_VERSION}"
        exit 1
    fi

    NODE_PATH=$(command -v node)
    log_ok "Node.js v${node_version} ($NODE_PATH)"

    if ! command -v npm &>/dev/null; then
        log_error "未检测到 npm"
        exit 1
    fi
    NPM_PATH=$(command -v npm)
    log_ok "npm $($NPM_PATH --version) ($NPM_PATH)"
}

# ── 检查 git ─────────────────────────────────────────────────────────────────
check_git() {
    if ! command -v git &>/dev/null; then
        log_error "未检测到 git，请先安装 git"
        log_info  "安装方式:"
        log_info  "  macOS:  xcode-select --install"
        log_info  "  Ubuntu: sudo apt-get install -y git"
        exit 1
    fi
    log_ok "git $(git --version | awk '{print $3}') ($(command -v git))"
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

    # 尝试 HTTPS 克隆
    log_info "正在克隆: ${REPO_URL} (分支: ${BRANCH})"
    if git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>/dev/null; then
        log_ok "克隆成功: $INSTALL_DIR"
    else
        log_error "克隆失败，请检查:"
        log_info  "  1. 仓库地址是否正确: ${REPO_URL}"
        log_info  "  2. 网络是否正常"
        log_info  "  3. 如为私有仓库，请先配置 SSH Key"
        log_info  ""
        log_info  "手动操作:"
        log_info  "  git clone ${REPO_URL} ${INSTALL_DIR}"
        exit 1
    fi
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
    if $NPM_PATH install --loglevel=error; then
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
    if $env_prefix $NPM_PATH run build 2>&1; then
        log_ok "编译完成"
    else
        log_error "编译失败"
        log_info  "手动编译: cd ${INSTALL_DIR} && env -u ELECTRON_RUN_AS_NODE npm run build"
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
        log_ok "检测到 Codex"
    fi

    if ! $DETECTED_WB && ! $DETECTED_CODEX; then
        log_warn "未检测到 WorkBuddy 或 Codex，将输出通用 MCP 配置"
    fi
}

# ── 生成 MCP 配置 ────────────────────────────────────────────────────────────
generate_mcp_config() {
    log_step "生成 MCP 配置"

    # 转义路径中的特殊字符
    local node_json
    node_json=$(printf '%s' "$NODE_PATH" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    local dist_json
    dist_json=$(printf '%s' "$INSTALL_DIR/dist/index.js" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')

    local config_json
    config_json=$(cat <<EOF
{
  "mcpServers": {
    "cloud-ip-rotator": {
      "command": "${node_json}",
      "args": ["${dist_json}"]
    }
  }
}
EOF
)

    # 写入通用配置文件（如已存在则跳过）
    local mcp_config_path="$HOME/.cloud-ip-rotator/mcp-config.json"
    if [ -f "$mcp_config_path" ]; then
        log_info "MCP 配置文件已存在，跳过生成: ${mcp_config_path}"
    else
        mkdir -p "$HOME/.cloud-ip-rotator"
        cat > "$mcp_config_path" <<MCPEOF
$config_json
MCPEOF
        log_ok "MCP 配置已生成: ${mcp_config_path}"
    fi

    # 根据实际检测到的平台，给出针对性指引
    local shown=false

    if $DETECTED_WB; then
        echo ""
        echo "${CYAN}── WorkBuddy 设置步骤 ──${NC}"
        log_info  "1. 将上方的 cloud-ip-rotator 配置合并到:"
        log_info  "   ~/.workbuddy/mcp.json"
        log_info  "2. 在 WorkBuddy 连接器管理页面点击「信任」cloud-ip-rotator"
        shown=true
    fi

    if $DETECTED_CODEX; then
        echo ""
        echo "${CYAN}── Codex 设置步骤 ──${NC}"
        log_info  "1. 将上方的 cloud-ip-rotator 配置合并到 Codex 的 MCP 配置文件"
        log_info  "   常见路径: ~/.codex/mcp.json 或 Codex 设置面板"
        log_info  "2. 重启 Codex 使配置生效"
        shown=true
    fi

    if ! $shown; then
        echo ""
        log_info  "未检测到兼容的 MCP 客户端。配置已保存，可手动导入到你的 MCP 客户端。"
    fi
}

# ── 安装完成后提示 ───────────────────────────────────────────────────────────
print_success() {
    local browser_cmd
    if [ "$OS" = "macos" ]; then
        browser_cmd="open http://localhost:8787"
    else
        browser_cmd="xdg-open http://localhost:8787"
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

    cat <<EOF

${GREEN}╔══════════════════════════════════════════════════════════╗
║          cloud-ip-rotator-mcp 安装成功!                  ║
╚══════════════════════════════════════════════════════════╝${NC}

项目路径:   ${INSTALL_DIR}
配置目录:   ~/.cloud-ip-rotator/config.json
UI 服务器:  node ${INSTALL_DIR}/ui/server.cjs
UI 地址:    http://localhost:8787

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
  rm -rf ${INSTALL_DIR}
  rm -rf ~/.cloud-ip-rotator

EOF
}

# ── 主流程 ───────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo "${GREEN}║   cloud-ip-rotator-mcp 自动部署脚本 v1.0               ║${NC}"
    echo "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    detect_os
    check_node
    check_git
    detect_mcp_platform
    clone_repo
    install_deps
    build_project
    generate_mcp_config
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
            echo "  --install-dir DIR  指定安装目录（默认 ~/cloud-ip-rotator-mcp）"
            echo "  --skip-build       跳过编译步骤"
            echo "  -h, --help         显示帮助"
            exit 0;;
        *)
            log_error "未知参数: $1"; exit 1;;
    esac
done

main
