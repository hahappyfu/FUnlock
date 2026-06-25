#!/bin/bash
# Claude Code 透明委托脚本
# 用法: ./claude-delegate.sh "任务描述"

set -e

TASK="$1"
LOG_FILE="/tmp/claude-delegate-$(date +%Y%m%d-%H%M%S).log"

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ 📤 发送给 Claude Code 的指令：                                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
echo "$TASK"
echo ""
echo "─────────────────────────────────────────────────────────────────"
echo "⏳ Claude Code 执行中... (日志: $LOG_FILE)"
echo "─────────────────────────────────────────────────────────────────"
echo ""

# 执行 Claude Code，同时记录到文件
/opt/homebrew/bin/claude --dangerously-skip-permissions -p "$TASK" \
    --allowedTools 'Read,Edit,Bash' \
    --max-turns 30 \
    --model sonnet \
    --output-format text \
    2>&1 | tee "$LOG_FILE"

EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "─────────────────────────────────────────────────────────────────"
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Claude Code 执行完成 (退出码: $EXIT_CODE)"
else
    echo "❌ Claude Code 执行失败 (退出码: $EXIT_CODE)"
fi
echo "📁 完整日志: $LOG_FILE"
echo "─────────────────────────────────────────────────────────────────"
echo ""
echo "📋 完整输出已保存到: $LOG_FILE"
echo "   查看命令: cat $LOG_FILE"
echo ""

exit $EXIT_CODE
