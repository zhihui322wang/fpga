#!/usr/bin/env bash
# ============================================================================
# fpga_ila GUI 启动脚本 — RiscV_WebSoC_3
# 用法: ./ila_gui.sh            # Qt GUI 桌面版
#       ./ila_gui.sh web        # Web 版 (浏览器)
#       ./ila_gui.sh web 9527   # Web 版 (指定端口)
# ============================================================================
ILA_HOME="/home/zhihuiw/fpga_work/fpga_ila_local"
VENV_PYTHON="$ILA_HOME/.venv/bin/python"
SIGNALS_JSON="$(dirname "$0")/signals.json"

# 自动复制 signals.json 到 GUI 可发现的位置
cp "$SIGNALS_JSON" "$ILA_HOME/signals.json" 2>/dev/null

cd "$ILA_HOME"

if [ "$1" = "web" ]; then
    PORT="${2:-9527}"
    echo "=== fpga_ila Web 版 ==="
    echo "   地址: http://localhost:$PORT"
    echo "   信号: $SIGNALS_JSON"
    echo ""
    cd web
    exec "$VENV_PYTHON" server.py --port "$PORT"
else
    export QT_QPA_PLATFORM=xcb
    echo "=== fpga_ila Qt GUI ==="
    echo "   ILA:  $ILA_HOME"
    echo "   信号: $SIGNALS_JSON"
    echo ""
    exec "$VENV_PYTHON" gui/main.py
fi
