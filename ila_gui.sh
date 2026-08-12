#!/usr/bin/env bash
# ============================================================================
# fpga_ila GUI 启动脚本 — RiscV_WebSoC_3
#
# IP 来源: fpga_ila-snapshot-20260812133532
#   /home/zhihuiw/fpga_work/ip copy/fpga_ila-snapshot-20260812133532/
#
# 用法:
#   ./ila_gui.sh            # Qt GUI 桌面版
#   ./ila_gui.sh web        # Web 版 (浏览器 http://localhost:9527)
#   ./ila_gui.sh web 9528   # Web 版 (指定端口)
# ============================================================================

# ---- 路径配置 ----
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ILA_HOME="/home/zhihuiw/fpga_work/ip_copy"
VENV_HOME="/home/zhihuiw/fpga_work/fpga_ila_local"     # 已有 venv + 全部依赖
VENV_PYTHON="$VENV_HOME/.venv/bin/python"
SIGNALS_JSON="$PROJECT_DIR/signals.json"

# ---- 检查 venv ----
if [ ! -f "$VENV_PYTHON" ]; then
    echo "ERROR: venv 未找到: $VENV_PYTHON"
    echo "请先创建 venv: python3 -m venv $VENV_HOME/.venv"
    echo "然后安装依赖: $VENV_HOME/.venv/bin/pip install PySide6 pyqtgraph pyserial"
    exit 1
fi

# ---- 检查 ILA 目录 ----
if [ ! -d "$ILA_HOME" ]; then
    echo "ERROR: fpga_ila IP 未找到: $ILA_HOME"
    exit 1
fi

# 自动复制 signals.json 到 ILA 目录 (GUI 从此加载)
if [ -f "$SIGNALS_JSON" ]; then
    cp "$SIGNALS_JSON" "$ILA_HOME/signals.json" 2>/dev/null
fi

# ---- 启动 ----
if [ "$1" = "web" ]; then
    PORT="${2:-9527}"
    echo "=== fpga_ila Web 版 ==="
    echo "   IP:    $ILA_HOME"
    echo "   地址:  http://localhost:$PORT"
    echo "   信号:  $SIGNALS_JSON"
    echo ""
    cd "$ILA_HOME/web_portable" || exit 1
    exec "$VENV_PYTHON" server.py --port "$PORT"
else
    export QT_QPA_PLATFORM=xcb
    echo "=== fpga_ila Qt GUI ==="
    echo "   IP:    $ILA_HOME"
    echo "   信号:  $SIGNALS_JSON"
    echo ""
    cd "$ILA_HOME" || exit 1
    exec "$VENV_PYTHON" gui/main.py
fi
