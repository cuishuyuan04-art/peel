#!/bin/bash
# 编译并组装 ~/Applications/Peel.app（只编本机架构，开发时用）
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

assemble_app
echo "✓ 已生成 ${APP}"
