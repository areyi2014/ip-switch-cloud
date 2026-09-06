#!/usr/bin/env bash
# ip-switch Skill - Bash 包装器
# 自动定位 node 并调用 open-ui.mjs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/open-ui.mjs" "$@"