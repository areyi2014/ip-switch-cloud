#!/bin/bash
# Modified install.sh - 添加桌面快捷方式创建功能（对应 install.ps1 第 6 步）

# 安装目录（与 install_original.sh 保持一致）
INSTALL_DIR="${INSTALL_DIR:-$HOME/ip-switch}"

# 第 6 步：创建 Codex 桌面快捷方式（对应 PowerShell 的 Create-CodexShortcut）
create_codex_shortcut() {
    local desktop_dir="${USERPROFILE:-/c/Users/Administrator}/Desktop"
    local install_dir="$INSTALL_DIR"
    local vbs_path="$install_dir/codex_app.vbs"
    # 系统安装盘下的 Windows\System32\wscript.exe（反斜杠转正斜杠）
    local wscript_exe="${SYSTEMROOT:-C:/Windows}/System32/wscript.exe"
    wscript_exe="${wscript_exe//\\//}"

    echo "正在创建 Codex 快捷方式..."

    # 复制启动脚本
    if [ -f "./codex_app.vbs" ]; then
        cp "./codex_app.vbs" "$vbs_path"
        chmod +x "$vbs_path"
        echo "✓ 已复制 codex_app.vbs 到 $vbs_path"
    elif [ ! -f "$vbs_path" ]; then
        echo "警告: 未找到 codex_app.vbs 文件"
    fi

    # 复制图标文件
    local icon_path="$install_dir/codex.ico"
    if [ -f "./codex.ico" ]; then
        cp "./codex.ico" "$icon_path"
        echo "✓ 已复制 codex.ico 到 $icon_path"
    elif [ ! -f "$icon_path" ]; then
        echo "警告: 未找到 codex.ico 图标文件，将使用默认图标"
    fi

    # 创建桌面快捷方式
    mkdir -p "$desktop_dir" 2>/dev/null || true
    cat > "$desktop_dir/Codex with ip-switch.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Codex with ip-switch
Comment=启动 Codex 并自动加载 ip-switch MCP 服务
Exec="$wscript_exe" "$vbs_path"
Path=$install_dir
Icon=$icon_path
Terminal=false
Categories=Development;Utility;
EOF

    chmod +x "$desktop_dir/Codex with ip-switch.desktop"
    echo "✓ 已创建桌面快捷方式: $desktop_dir/Codex with ip-switch.desktop"
}

# 主安装流程
echo "=== ip-switch 安装（含 Codex 集成） ==="

# 执行原始安装流程（步骤 1-5）
echo "执行原始安装..."
./install_original.sh "$@"

# 第 6 步：创建桌面快捷方式
create_codex_shortcut

echo "安装完成！"
echo ""
echo "使用方法："
echo "1. 双击桌面上的 'Codex with ip-switch' 快捷方式"
echo "2. 或在终端运行: wscript '$INSTALL_DIR/codex_app.vbs'"
