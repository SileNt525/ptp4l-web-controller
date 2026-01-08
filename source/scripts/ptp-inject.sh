#!/bin/bash
# PTP4L 状态强制注入工具 (v6.2 Robust)
# Usage: ptp-inject <domain_number>

DOMAIN=${1:-0}
LOG_TAG="ptp-inject"

# 构造指令：包含 clockClass 13 (Master) 以及 ST 2110 必需的 Traceable 标志
CMD="SET GRANDMASTER_SETTINGS_NP clockClass 13 clockAccuracy 0x27 offsetScaledLogVariance 0xFFFF currentUtcOffset 37 leap61 0 leap59 0 currentUtcOffsetValid 1 ptpTimescale 1 timeTraceable 1 frequencyTraceable 1 timeSource 0x50"

echo "Starting injection loop on Domain $DOMAIN..." | logger -t $LOG_TAG

# 循环尝试注入 (持续 20 秒)，确保覆盖 ptp4l 的 LISTENING -> MASTER 状态转换期
# 只要成功一次，并不代表状态会一直保持，所以我们在这个窗口期内多次确认
SUCCESS_COUNT=0

for i in {1..20}; do
    # 运行 PMC 命令
    OUT=$(pmc -u -b 0 -d "$DOMAIN" "$CMD" 2>&1)
    
    # 检查结果：必须包含 RESPONSE 且不能包含 ERROR
    if echo "$OUT" | grep -q "RESPONSE" && ! echo "$OUT" | grep -q "ERROR"; then
        echo "✅ Injection attempt $i: SUCCESS" | logger -t $LOG_TAG
        SUCCESS_COUNT=$((SUCCESS_COUNT+1))
        
        # 即使成功了，我们也建议稍微多试几次或者在初期保持覆盖
        # 但为了效率，如果连续成功2次，我们就认为稳定了
        if [ "$SUCCESS_COUNT" -ge 2 ]; then
            echo "🚀 Injection Stabilized on Domain $DOMAIN" | logger -t $LOG_TAG
            exit 0
        fi
    else
        echo "⚠️ Injection attempt $i failed/ignored. Retrying..." | logger -t $LOG_TAG
        SUCCESS_COUNT=0 # 如果中间失败了，重置计数
    fi
    
    sleep 1
done

echo "❌ Injection timed out (Process might not be Master or ready)" | logger -t $LOG_TAG
exit 1