#!/bin/bash

# Script test Kafka Rebalancing - CHỈ DÙNG BASH (không cần Python)
# Test: Producer gửi messages + Rebalance partitions -> Consumer có bị downtime không?

set -e

# ============ CẤU HÌNH ============
KAFKA_CONTAINER="kafka-1"
BOOTSTRAP_SERVER="localhost:9092"
TOPIC_NAME="test-rebalance"
NUM_MESSAGES=1000
PARTITION_COUNT=5
REPLICATION_FACTOR=3
# ==================================

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Kafka Partition Rebalancing Test        ║${NC}"
echo -e "${CYAN}║   Test di chuyển partitions (BASH only)   ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"

if ! docker ps | grep -q $KAFKA_CONTAINER; then
    echo -e "${RED}❌ Container $KAFKA_CONTAINER không chạy!${NC}"
    exit 1
fi

CONSUMER_LOG="/tmp/consumer_rebalance.log"
TIMING_LOG="/tmp/timing_rebalance.log"
rm -f $CONSUMER_LOG $TIMING_LOG

# ============ TẠO TOPIC ============
echo -e "\n${YELLOW}[1/7]${NC} Tạo topic với $PARTITION_COUNT partitions, RF=$REPLICATION_FACTOR..."
docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --delete --topic $TOPIC_NAME 2>/dev/null || true
sleep 2

docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --create --topic $TOPIC_NAME \
    --partitions $PARTITION_COUNT \
    --replication-factor $REPLICATION_FACTOR

echo -e "${GREEN}✅ Topic ban đầu:${NC}"
docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --describe --topic $TOPIC_NAME

sleep 2

# ============ KHỞI ĐỘNG CONSUMER ============
echo -e "\n${YELLOW}[2/7]${NC} Khởi động consumer..."
docker exec $KAFKA_CONTAINER kafka-console-consumer \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --topic $TOPIC_NAME \
    --from-beginning 2>&1 | while IFS= read -r line; do
        echo "$(date +%s.%N) $line" >> $CONSUMER_LOG
    done &

CONSUMER_PID=$!
echo -e "${GREEN}✅ Consumer started (PID: $CONSUMER_PID)${NC}"
sleep 3

# ============ CHUẨN BỊ REBALANCE CONFIG ============
echo -e "\n${YELLOW}[3/7]${NC} Chuẩn bị rebalance configuration..."

cat > /tmp/rebalanced_assignment.json <<EOF
{
  "version": 1,
  "partitions": [
    {"topic": "$TOPIC_NAME", "partition": 0, "replicas": [4,0,1]},
    {"topic": "$TOPIC_NAME", "partition": 1, "replicas": [3,4,0]},
    {"topic": "$TOPIC_NAME", "partition": 2, "replicas": [2,3,4]},
    {"topic": "$TOPIC_NAME", "partition": 3, "replicas": [1,2,3]},
    {"topic": "$TOPIC_NAME", "partition": 4, "replicas": [0,1,2]}
  ]
}
EOF

echo -e "${GREEN}✅ Rebalance config created${NC}"
docker cp /tmp/rebalanced_assignment.json $KAFKA_CONTAINER:/tmp/

# ============ GỬI MESSAGES ============
echo -e "\n${YELLOW}[4/7]${NC} Bắt đầu gửi ${NUM_MESSAGES} messages..."
echo "$(date +%s.%N) PRODUCER_START" >> $TIMING_LOG

(
    for i in $(seq 1 $NUM_MESSAGES); do
        key=$((i % PARTITION_COUNT))
        echo "key_${key}:Message_$i at $(date +%H:%M:%S.%N)"
        sleep 0.04
    done
) | docker exec -i $KAFKA_CONTAINER kafka-console-producer \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --topic $TOPIC_NAME \
    --property "parse.key=true" \
    --property "key.separator=:" &

PRODUCER_PID=$!
echo -e "${GREEN}✅ Producer started${NC}"

sleep 3

# ============ THỰC HIỆN REBALANCING ============
echo -e "\n${RED}╔════════════════════════════════════════════╗${NC}"
echo -e "${RED}║    [5/7] BẮT ĐẦU REBALANCING PARTITIONS    ║${NC}"
echo -e "${RED}║    Thời gian: $(date +%H:%M:%S)                 ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════╝${NC}"

echo "$(date +%s.%N) REBALANCE_START" >> $TIMING_LOG

docker exec $KAFKA_CONTAINER kafka-reassign-partitions \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --reassignment-json-file /tmp/rebalanced_assignment.json \
    --execute

echo "$(date +%s.%N) REBALANCE_EXECUTED" >> $TIMING_LOG

# ============ ĐỢI REBALANCING HOÀN TẤT ============
echo -e "\n${YELLOW}[6/7]${NC} Đợi rebalancing hoàn tất..."
echo -n "${CYAN}Progress: ${NC}"

COUNTER=0
while true; do
    VERIFY_RESULT=$(docker exec $KAFKA_CONTAINER kafka-reassign-partitions \
        --bootstrap-server $BOOTSTRAP_SERVER \
        --reassignment-json-file /tmp/rebalanced_assignment.json \
        --verify 2>&1)
    
    if echo "$VERIFY_RESULT" | grep -q "still in progress"; then
        echo -n "."
        COUNTER=$((COUNTER + 1))
        sleep 1
    else
        echo -e " ${GREEN}✅${NC}"
        break
    fi
    
    if [ $COUNTER -ge 120 ]; then
        echo -e "\n${RED}⚠️  Timeout sau 120s${NC}"
        break
    fi
done

echo "$(date +%s.%N) REBALANCE_COMPLETED" >> $TIMING_LOG
echo -e "${GREEN}✅ Rebalancing hoàn tất sau ${COUNTER} giây!${NC}"

echo -e "\n${GREEN}📋 Partition assignment sau rebalancing:${NC}"
docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --describe --topic $TOPIC_NAME

wait $PRODUCER_PID 2>/dev/null || true
echo "$(date +%s.%N) PRODUCER_END" >> $TIMING_LOG
sleep 5

# ============ PHÂN TÍCH KẾT QUẢ ============
echo -e "\n${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         [7/7] PHÂN TÍCH KẾT QUẢ            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"

if [ -f "$CONSUMER_LOG" ]; then
    RECEIVED=$(grep -c "Message_" $CONSUMER_LOG 2>/dev/null || echo "0")
else
    RECEIVED=0
fi

echo -e "\n${CYAN}📊 Tổng quan:${NC}"
echo -e "  ✉️  Messages đã gửi:        ${GREEN}${NUM_MESSAGES}${NC}"
echo -e "  📥 Messages đã nhận:        ${GREEN}${RECEIVED}${NC}"

if [ "$RECEIVED" -eq "$NUM_MESSAGES" ]; then
    echo -e "  ✅ Kết quả:                 ${GREEN}100% - Không mất message${NC}"
else
    PERCENT=$((RECEIVED * 100 / NUM_MESSAGES))
    echo -e "  ⚠️  Kết quả:                 ${YELLOW}${RECEIVED}/${NUM_MESSAGES} (${PERCENT}%)${NC}"
fi

echo -e "\n${CYAN}⏱️  Phân tích thời gian:${NC}"
if [ -f "$TIMING_LOG" ]; then
    RB_START=$(grep "REBALANCE_START" $TIMING_LOG | cut -d' ' -f1)
    RB_END=$(grep "REBALANCE_COMPLETED" $TIMING_LOG | cut -d' ' -f1)
    
    if [ -n "$RB_START" ] && [ -n "$RB_END" ]; then
        RB_DURATION=$(echo "$RB_END - $RB_START" | bc 2>/dev/null || echo "N/A")
        echo -e "  Thời gian rebalancing:      ${BLUE}${RB_DURATION} giây${NC}"
    fi
fi

echo -e "\n${CYAN}🔍 Phân tích Consumer Downtime:${NC}"

if [ -f "$CONSUMER_LOG" ] && [ "$RECEIVED" -gt 0 ]; then
    grep "Message_" $CONSUMER_LOG | cut -d' ' -f1 > /tmp/timestamps.txt
    
    awk 'BEGIN {
        max_gap = 0
        gaps_count = 0
    }
    NR > 1 {
        gap = $1 - prev
        if (gap > max_gap) {
            max_gap = gap
        }
        if (gap > 0.2) {
            gaps_count++
            if (gaps_count <= 3) {
                printf "    • Gap: %.3f giây\n", gap
            }
        }
        prev = $1
    }
    NR == 1 {
        prev = $1
    }
    END {
        printf "  Gap lớn nhất:               %.3f giây\n", max_gap
        printf "  Số gaps > 0.2s:             %d\n", gaps_count
        
        if (max_gap < 0.15) {
            printf "  \033[0;32m✅ KHÔNG có downtime trong rebalance!\033[0m\n"
        } else if (max_gap < 0.5) {
            printf "  \033[0;32m✅ Downtime rất thấp (<0.5s)\033[0m\n"
        } else {
            printf "  \033[1;33m⚠️  Có downtime: %.3fs\033[0m\n", max_gap
        }
    }' /tmp/timestamps.txt
    
    rm -f /tmp/timestamps.txt
fi

echo -e "\n${YELLOW}🧹 Dọn dẹp...${NC}"
kill $CONSUMER_PID 2>/dev/null || true

echo -e "\n${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            ✅ TEST HOÀN TẤT!               ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"

echo -e "\n${CYAN}📁 Logs: ${BLUE}$CONSUMER_LOG, $TIMING_LOG${NC}"