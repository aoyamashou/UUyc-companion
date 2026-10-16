#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# 使用真实的私有 API 声明编译 DisplayManager，但测试替代所有布局 I/O；不运行建屏路径。
cp Sources/CGVirtualDisplayBridge/include/CGVirtualDisplay.h "$TEST_DIR/"
cat > "$TEST_DIR/module.modulemap" <<'MODULE'
module CGVirtualDisplayBridge {
    header "CGVirtualDisplay.h"
    export *
}
MODULE
swiftc -I "$TEST_DIR" Sources/UUDisplay/Config.swift \
    Sources/UUDisplay/DisplayLayoutStability.swift Sources/UUDisplay/DisplayManager.swift \
    tests/display-recovery-main.swift -o "$TEST_DIR/display-recovery-tests"
"$TEST_DIR/display-recovery-tests"
