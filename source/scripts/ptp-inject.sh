#!/bin/bash
# PTP4L 状态强制注入工具
# Usage: ptp-inject <domain_number>

DOMAIN=${1:-0}
LOG_TAG="ptp-inject"

# 等待 ptp4l 启动就绪
for i in {1..10}; do
    if pgrep -x "ptp4l" > /dev/null; then
        break
    fi
    sleep 1
done
sleep 5 # 额外等待端口初始化

# 构造并发送指令
# clockClass 13: 应用级最高优先级
# clockAccuracy 0x27: < 100μs (NTP 精度)
# timeTraceable 1: 声明时间可追溯
CMD="SET GRANDMASTER_SETTINGS_NP clockClass 13 clockAccuracy 0x27 offsetScaledLogVariance 0xFFFF currentUtcOffset 37 leap61 0 leap59 0 currentUtcOffsetValid 1 ptpTimescale 1 timeTraceable 1 frequencyTraceable 1 timeSource 0x50"

echo "Running injection on Domain $DOMAIN..." | logger -t $LOG_TAG

# 尝试注入 3 次
for i in {1..3}; do
    OUT=$(pmc -u -b 0 -d "$DOMAIN" "$CMD" 2>&1)
    
    if echo "$OUT" | grep -q "RESPONSE"; then
        echo "✅ Injection SUCCESS on Domain $DOMAIN" | logger -t $LOG_TAG
        exit 0
    else
        echo "⚠️ Injection attempt $i failed: $OUT" | logger -t $LOG_TAG
        sleep 2
    fi
done

echo "❌ Injection FAILED after retries" | logger -t $LOG_TAG
exit 1
