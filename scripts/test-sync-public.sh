#!/usr/bin/env bash
# 本地端到端测试 .workflow/gitee-go-sync-public.yml（不触碰 Gitee）
# 原理：从 YAML 提取真实 script 块 → 把 PUBLIC_REPO 替换为临时本地裸仓库 → 原样执行 → 校验推送结果
# 用法：bash scripts/test-sync-public.sh
set -euo pipefail

YML=".workflow/sync-public.yml"
[ -f "$YML" ] || { echo "ERROR: $YML not found (run from repo root)"; exit 1; }

TEST_DIR="$PWD/.sync-test"
BARE="$TEST_DIR/target.git"
rm -rf "$TEST_DIR" "$PWD/sync-tmp"
mkdir -p "$TEST_DIR"
trap 'echo "Test artifacts kept at: $TEST_DIR"' EXIT

git init --bare -b main "$BARE" >/dev/null

# 1) 提取 commands 块（commands: 下的 - | 之后到文件末尾就是脚本本体）
SCRIPT=$(awk '/^ *- \| *$/{flag=1;next} flag' "$YML")
[ -n "$SCRIPT" ] || { echo "ERROR: failed to extract script block from $YML"; exit 1; }

# 2) 仅替换推送目标为本地裸仓库（注意 YAML 中该行有缩进），其余逻辑一字不动
RUNNER=$(printf '%s\n' "$SCRIPT" | sed "s|^\( *PUBLIC_REPO=\).*|\1\"$BARE\"|")
RUNNER_FILE="$TEST_DIR/run.sh"
printf '%s\n' "$RUNNER" > "$RUNNER_FILE"

echo "=== Running pipeline script locally (target: local bare repo) ==="
bash "$RUNNER_FILE"

echo
echo "=== Verify: commits pushed to target ==="
git -C "$BARE" log --oneline main

echo
echo "=== Verify: files synced to target ==="
git -C "$BARE" ls-tree -r --name-only main

echo
echo "PASS: pipeline script works end-to-end (manifest parse -> copy -> commit -> push)."
echo "      Now test the REAL push with: check GITEE_PUBLIC_TOKEN in Gitee Go env vars."
