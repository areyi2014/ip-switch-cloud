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

# ── 查找 WorkBuddy/CodeBuddy 自带 Node.js ─────────────────────────────────────
find_workbuddy_node() {
    # 优先使用 CodeBuddy 注入的环境变量（运行时自动指向最新版本）
    if [ -n "${CODEBUDDY_NODE_BIN:-}" ] && [ -x "$CODEBUDDY_NODE_BIN" ]; then
        echo "$CODEBUDDY_NODE_BIN"
        return 0
    fi

    local versions_root="$HOME/.workbuddy/binaries/node/versions"
    [ -d "$versions_root" ] || return 1

    # 取版本号最大的目录（sort -V 按版本排序，取最后一个）
    local latest
    latest=$(ls -1 "$versions_root" 2>/dev/null | sort -V 2>/dev/null | tail -1)
    [ -n "$latest" ] || return 1

    # Unix 布局: bin/node；部分版本直接放在版本目录下
    for f in "$versions_root/$latest/bin/node" "$versions_root/$latest/node"; do
        if [ -x "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# ── 查找 Codex 自带 Node.js ─────────────────────────────────────────────────
find_codex_node() {
    local codex_node
    codex_node="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
    if [ -x "$codex_node" ]; then
        echo "$codex_node"
        return 0
    fi
    # 兜底：查找其他 runtime
    for f in "$HOME"/.cache/codex-runtimes/*/dependencies/node/bin/node; do
        if [ -x "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# ── 检测系统上所有可用的 Node.js ─────────────────────────────────────────────
# 输出格式: 来源<TAB>路径，每行一个
collect_all_nodes() {
    local wb codex

    wb=$(find_workbuddy_node) && printf 'WorkBuddy 自带\t%s\n' "$wb"
    codex=$(find_codex_node) && printf 'Codex 自带\t%s\n' "$codex"

    if command -v node &>/dev/null; then
        printf '系统 PATH\t%s\n' "$(command -v node)"
    fi
}

# ── 检查 Node.js ─────────────────────────────────────────────────────────────
check_node() {
    log_step "检查 Node.js 环境"

    # 检测系统上所有可用的 Node.js（WorkBuddy / Codex 自带 + 系统 PATH 安装的）
    local node_list
    node_list=$(collect_all_nodes)

    if [ -z "$node_list" ]; then
        log_error "未检测到任何 Node.js，请先安装 Node.js >= ${NODE_MIN_VERSION}"
        log_info  "安装方式:"
        log_info  "  macOS:  brew install node@22"
        log_info  "  Ubuntu: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs"
        log_info  "  通用:   访问 https://nodejs.org/ 下载安装"
        exit 1
    fi

    echo ""
    log_info "检测到以下 Node.js 环境:"
    local idx=0
    local best=""
    local best_ver="0.0.0"
    while IFS=$'\t' read -r src path; do
        [ -z "$src" ] && continue
        idx=$((idx + 1))
        local ver
        ver=$("$path" -v 2>/dev/null | sed 's/v//')
        if [ -n "$ver" ]; then
            echo "  [${idx}] ${src}: v${ver}"
            echo "      ${path}"
            # 记录版本号最大的 Node.js
            if [ "$(printf '%s\n%s\n' "$ver" "$best_ver" | sort -V | tail -1)" = "$ver" ]; then
                best="$path"
                best_ver="$ver"
            fi
        else
            echo "  [${idx}] ${src}: 版本未知"
            echo "      ${path}"
        fi
    done <<< "$node_list"
    echo ""

    # 记录 WorkBuddy / Codex 自带 node（供生成 MCP 配置时按平台选用）
    local first_node=""
    WB_NODE_EXE=""
    CODEX_NODE_EXE=""
    while IFS=$'\t' read -r src path; do
        [ -z "$src" ] && continue
        [ -z "$first_node" ] && first_node="$path"
        case "$src" in
            "WorkBuddy 自带") WB_NODE_EXE="$path" ;;
            "Codex 自带")     CODEX_NODE_EXE="$path" ;;
        esac
    done <<< "$node_list"

    # 默认使用"版本号最大"的 Node.js
    local node_exe="${best:-$first_node}"
    export PATH="$(dirname "$node_exe"):${PATH}"

    local node_version
    node_version=$(node -v | sed 's/v//')
    local major
    major=$(echo "$node_version" | cut -d. -f1)

    if [ "$major" -lt "$NODE_MIN_VERSION" ]; then
        log_error "Node.js 版本过低: v${node_version}，需要 >= v${NODE_MIN_VERSION}"
        log_info  "可尝试改用列表中其他版本的 Node.js，或升级当前版本"
        exit 1
    fi

    NODE_PATH="$node_exe"
    log_ok "使用 Node.js v${node_version} ($NODE_PATH)"
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
    if npm install --loglevel=error; then
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
    if $env_prefix npm run build 2>&1; then
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

    # 各平台优先使用其自带 Node.js（用户可能只装了 IDE，没有独立 Node）
    local default_node wb_node codex_node
    default_node=$(command -v node)
    if [ -z "$default_node" ]; then
        # 尝试常见路径
        for p in /usr/local/bin/node /opt/homebrew/bin/node /usr/bin/node; do
            if [ -x "$p" ]; then default_node="$p"; break; fi
        done
    fi
    wb_node="${WB_NODE_EXE:-$default_node}"
    codex_node="${CODEX_NODE_EXE:-$default_node}"

    local dist_js="${INSTALL_DIR}/dist/index.js"
    local written=false

    # 直接写入对应平台的 mcp.json（各自优先用自带 Node.js）
    if $DETECTED_WB; then
        write_mcp_config_file "$HOME/.workbuddy" "$wb_node" "$dist_js"
        log_ok "已写入 MCP 配置: ~/.workbuddy/mcp.json"
        log_info "WorkBuddy 连接器管理页面点击「信任」ip-switch 即可使用"
        written=true
    fi

    if $DETECTED_CODEX; then
        write_mcp_config_file "$HOME/.codex" "$codex_node" "$dist_js"
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
      "command": "${wb_node}",
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



# ── 安装 Codex MCP 直连配置 + Profile 叠加层 + 项目级配置 ──
# 职责：
#   ① 生成 INSTALL_DIR/.mcp.json（codex 自带 node 全路径，供市场插件 plugin.json 引用）
#   ② 生成 INSTALL_DIR/.codex/config.toml（项目级配置层 —— 桌面版的主要加载通道）
#      —— 桌面版 codex app 通过协议拉起，-c 参数传不进桌面进程，
#         只能读 ~/.codex/config.toml + 工作区内项目级 .codex/config.toml
#      —— 首次以该目录为工作区启动时 Codex 会自动信任，信任后本文件生效
#   ③ 创建 ~/.codex/ip-switch.config.toml（Profile 叠加层，CLI 专用）
#      —— 用于 codex --profile ip-switch CLI 命令（mcp list / exec / review 等）
#   ④ 清理旧版 ~/.codex/plugins/ip-switch 残留
#   ⑤ 桌面快捷方式已拆出为 install_codex_shotcut 独立函数
#      —— codex_app.sh 以 INSTALL_DIR 为工作区启动 codex app
# 注：插件页发现/安装由 install_codex_marketplace 负责，本函数不重复。
# 注：②③两份配置互为镜像；均独立于 config.toml，CC Switch 不影响。
install_codex_profile() {
    log_step "安装 Codex MCP 直连配置 + Profile 叠加层"

    local dist_js="${INSTALL_DIR}/dist/index.js"
    local codex_node="${CODEX_NODE_EXE:-}"
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

    # 2.5 生成项目级配置层（INSTALL_DIR/.codex/config.toml）—— 桌面版的主要加载通道
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

    # 5. 创建桌面快捷方式（已拆出为 install_codex_shotcut 独立函数）
    install_codex_shotcut

    # 6. 验证
    if [ -f "${INSTALL_DIR}/.mcp.json" ]; then
        log_ok "Codex MCP 直连配置已就绪: ${INSTALL_DIR}/.mcp.json"
        log_info "重启 Codex 后生效（插件页发现由市场负责）"
    else
        log_error "MCP 配置生成失败，请检查 ${INSTALL_DIR}/.mcp.json"
        exit 1
    fi
}

# ── 创建桌面快捷方式 ───────────────────────────────────────────────────────────
# 从 install_codex_profile 拆出的独立函数：
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
    check_node
    check_git
    detect_mcp_platform
    clone_repo
    install_deps
    build_project
    if $DETECTED_WB; then
        generate_wb_config
    fi
    if $DETECTED_CODEX; then
        install_codex_profile
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
