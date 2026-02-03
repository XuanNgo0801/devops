#!/bin/bash

# Script test Kafka Failover - CHỈ DÙNG BASH (không cần Python)
# Test: Producer gửi messages + Tăng RF từ 2 -> 3 -> Consumer có bị downtime không?

set -e

# ============ CẤU HÌNH - CHỈNH SỬA THEO CLUSTER CỦA BẠN ============
KAFKA_CONTAINER="kafka-1"           # Container để chạy kafka commands
BOOTSTRAP_SERVER="localhost:9092"   # Bootstrap server
TOPIC_NAME="test-failover"
NUM_MESSAGES=1000
PARTITION_COUNT=3
INITIAL_RF=2                        # Replication Factor ban đầu
FINAL_RF=3                          # Replication Factor cuối
# ===================================================================

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Kafka Replication Failover Test         ║${NC}"
echo -e "${CYAN}║   Test tăng RF từ $INITIAL_RF -> $FINAL_RF (BASH only)       ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"

# Kiểm tra container
if ! docker ps | grep -q $KAFKA_CONTAINER; then
    echo -e "${RED}❌ Container $KAFKA_CONTAINER không chạy!${NC}"
    echo -e "${YELLOW}💡 Kiểm tra: docker ps | grep kafka${NC}"
    exit 1
fi

# Log files
CONSUMER_LOG="/tmp/consumer_${TOPIC_NAME}.log"
TIMING_LOG="/tmp/timing_${TOPIC_NAME}.log"
rm -f $CONSUMER_LOG $TIMING_LOG

# ============ BƯỚC 1: XÓA TOPIC CŨ ============
echo -e "\n${YELLOW}[1/8]${NC} Xóa topic cũ (nếu có)..."
docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --delete --topic $TOPIC_NAME 2>/dev/null || true
sleep 2

# ============ BƯỚC 2: TẠO TOPIC MỚI ============
echo -e "${YELLOW}[2/8]${NC} Tạo topic '${TOPIC_NAME}' với RF=${INITIAL_RF}, Partitions=${PARTITION_COUNT}..."
docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --create --topic $TOPIC_NAME \
    --partitions $PARTITION_COUNT \
    --replication-factor $INITIAL_RF

echo -e "${GREEN}✅ Topic đã tạo:${NC}"
docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --describe --topic $TOPIC_NAME

sleep 2

# ============ BƯỚC 3: KHỞI ĐỘNG CONSUMER ============
echo -e "\n${YELLOW}[3/8]${NC} Khởi động consumer (background)..."
docker exec $KAFKA_CONTAINER kafka-console-consumer \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --topic $TOPIC_NAME \
    --from-beginning 2>&1 | while IFS= read -r line; do
        echo "$(date +%s.%N) $line" >> $CONSUMER_LOG
    done &

CONSUMER_PID=$!
echo -e "${GREEN}✅ Consumer started (PID: $CONSUMER_PID)${NC}"
sleep 3

# ============ BƯỚC 4: CHUẨN BỊ REASSIGNMENT CONFIG ============
echo -e "${YELLOW}[4/8]${NC} Chuẩn bị reassignment configuration..."

cat > /tmp/reassignment.json <<EOF
{
  "version": 1,
  "partitions": [
    {"topic": "$TOPIC_NAME", "partition": 0, "replicas": [0,1,2]},
    {"topic": "$TOPIC_NAME", "partition": 1, "replicas": [1,2,3]},
    {"topic": "$TOPIC_NAME", "partition": 2, "replicas": [2,3,4]}
  ]
}
EOF

echo -e "${GREEN}✅ Reassignment config created${NC}"
docker cp /tmp/reassignment.json $KAFKA_CONTAINER:/tmp/
sleep 1

# ============ BƯỚC 5: BẮT ĐẦU GỬI MESSAGES ============
echo -e "\n${YELLOW}[5/8]${NC} Bắt đầu gửi ${NUM_MESSAGES} messages..."
echo "$(date +%s.%N) PRODUCER_START" >> $TIMING_LOG

(
    for i in $(seq 1 $NUM_MESSAGES); do
        echo "Message_$i: Kafka failover test at $(date +%H:%M:%S.%N)"
        sleep 0.05
    done
) | docker exec -i $KAFKA_CONTAINER kafka-console-producer \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --topic $TOPIC_NAME &

PRODUCER_PID=$!
echo -e "${GREEN}✅ Producer started (PID: $PRODUCER_PID)${NC}"

sleep 3
echo -e "${CYAN}⏳ Đã gửi ~60 messages, bắt đầu thay đổi RF...${NC}"

# ============ BƯỚC 6: THAY ĐỔI REPLICATION FACTOR ============
echo -e "\n${RED}╔════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  [6/8] TĂNG REPLICATION FACTOR: $INITIAL_RF -> $FINAL_RF      ║${NC}"
echo -e "${RED}║  Thời gian: $(date +%H:%M:%S)                    ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════╝${NC}"

echo "$(date +%s.%N) RF_CHANGE_START" >> $TIMING_LOG

docker exec $KAFKA_CONTAINER kafka-reassign-partitions \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --reassignment-json-file /tmp/reassignment.json \
    --execute

echo "$(date +%s.%N) RF_CHANGE_EXECUTED" >> $TIMING_LOG

# ============ BƯỚC 7: ĐỢI REASSIGNMENT HOÀN TẤT ============
echo -e "\n${YELLOW}[7/8]${NC} Đang chờ reassignment hoàn tất..."
echo -n "${CYAN}Progress: ${NC}"

COUNTER=0
while true; do
    VERIFY_RESULT=$(docker exec $KAFKA_CONTAINER kafka-reassign-partitions \
        --bootstrap-server $BOOTSTRAP_SERVER \
        --reassignment-json-file /tmp/reassignment.json \
        --verify 2>&1)
    
    if echo "$VERIFY_RESULT" | grep -q "still in progress"; then
        echo -n "."
        COUNTER=$((COUNTER + 1))
        sleep 1
    else
        echo -e " ${GREEN}✅${NC}"
        break
    fi
    
    if [ $COUNTER -ge 60 ]; then
        echo -e "\n${RED}⚠️  Timeout sau 60s${NC}"
        break
    fi
done

echo "$(date +%s.%N) RF_CHANGE_COMPLETED" >> $TIMING_LOG
echo -e "${GREEN}✅ Reassignment hoàn tất sau ${COUNTER} giây!${NC}"

echo -e "\n${GREEN}📋 Topic sau khi tăng RF:${NC}"
docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --describe --topic $TOPIC_NAME

echo -e "\n${YELLOW}Đợi producer gửi hết messages...${NC}"
wait $PRODUCER_PID 2>/dev/null || true
echo "$(date +%s.%N) PRODUCER_END" >> $TIMING_LOG

sleep 5

# ============ BƯỚC 8: PHÂN TÍCH KẾT QUẢ (BASH THUẦN) ============
echo -e "\n${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          [8/8] PHÂN TÍCH KẾT QUẢ           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"

# Đếm số messages
if [ -f "$CONSUMER_LOG" ]; then
    RECEIVED=$(grep -c "Message_" $CONSUMER_LOG 2>/dev/null || echo "0")
else
    RECEIVED=0
fi

echo -e "\n${CYAN}📊 Tổng quan:${NC}"
echo -e "  ✉️  Messages đã gửi:        ${GREEN}${NUM_MESSAGES}${NC}"
echo -e "  📥 Messages đã nhận:        ${GREEN}${RECEIVED}${NC}"

if [ "$RECEIVED" -eq "$NUM_MESSAGES" ]; then
    echo -e "  ✅ Kết quả:                 ${GREEN}HOÀN HẢO - Nhận đủ 100%${NC}"
elif [ "$RECEIVED" -ge $((NUM_MESSAGES * 95 / 100)) ]; then
    echo -e "  ✅ Kết quả:                 ${GREEN}TỐT - Nhận >95%${NC}"
else
    echo -e "  ⚠️  Kết quả:                 ${YELLOW}CẦN KIỂM TRA - Mất messages${NC}"
fi

# Phân tích thời gian
echo -e "\n${CYAN}⏱️  Phân tích thời gian:${NC}"
if [ -f "$TIMING_LOG" ]; then
    RF_START=$(grep "RF_CHANGE_START" $TIMING_LOG | cut -d' ' -f1)
    RF_END=$(grep "RF_CHANGE_COMPLETED" $TIMING_LOG | cut -d' ' -f1)
    PROD_START=$(grep "PRODUCER_START" $TIMING_LOG | cut -d' ' -f1)
    PROD_END=$(grep "PRODUCER_END" $TIMING_LOG | cut -d' ' -f1)
    
    if [ -n "$RF_START" ] && [ -n "$RF_END" ]; then
        RF_DURATION=$(echo "$RF_END - $RF_START" | bc 2>/dev/null || echo "N/A")
        echo -e "  Thời gian reassignment:     ${BLUE}${RF_DURATION} giây${NC}"
    fi
    
    if [ -n "$PROD_START" ] && [ -n "$PROD_END" ]; then
        PROD_DURATION=$(echo "$PROD_END - $PROD_START" | bc 2>/dev/null || echo "N/A")
        echo -e "  Thời gian gửi messages:     ${BLUE}${PROD_DURATION} giây${NC}"
    fi
fi

# Phân tích gaps (BASH THUẦN - không dùng Python)
echo -e "\n${CYAN}🔍 Phân tích Consumer Downtime (BASH):${NC}"

if [ -f "$CONSUMER_LOG" ] && [ "$RECEIVED" -gt 0 ]; then
    # Tạo file tạm với timestamps
    grep "Message_" $CONSUMER_LOG | cut -d' ' -f1 > /tmp/timestamps.txt
    
    # Tính gaps bằng awk
    awk 'BEGIN {
        max_gap = 0
        max_gap_line = 0
        gaps_count = 0
    }
    NR > 1 {
        gap = $1 - prev
        if (gap > max_gap) {
            max_gap = gap
            max_gap_line = NR
        }
        if (gap > 0.2) {
            gaps_count++
            if (gaps_count <= 5) {
                printf "    • Message %d: %.3f giây\n", NR, gap
            }
        }
        prev = $1
    }
    NR == 1 {
        prev = $1
    }
    END {
        printf "  Gap lớn nhất:               %.3f giây (tại message %d)\n", max_gap, max_gap_line
        printf "  Số gaps > 0.2s:             %d\n", gaps_count
        
        if (max_gap < 0.1) {
            printf "  \033[0;32m✅ KẾT LUẬN: KHÔNG có downtime đáng kể!\033[0m\n"
        } else if (max_gap < 0.5) {
            printf "  \033[0;32m✅ KẾT LUẬN: Downtime rất thấp (<0.5s)\033[0m\n"
        } else {
            printf "  \033[1;33m⚠️  KẾT LUẬN: Có downtime đáng kể (>0.5s)\033[0m\n"
        }
        
        # Tính throughput
        total_time = $1 - first_time
        if (total_time > 0) {
            throughput = NR / total_time
            printf "\n  Throughput trung bình:      %.2f msg/s\n", throughput
        }
    }
    NR == 1 {
        first_time = $1
    }' /tmp/timestamps.txt
    
    rm -f /tmp/timestamps.txt
else
    echo -e "  ${RED}⚠️  Không có dữ liệu consumer để phân tích${NC}"
fi

# ============ CLEANUP ============
echo -e "\n${YELLOW}🧹 Dọn dẹp...${NC}"
kill $CONSUMER_PID 2>/dev/null || true

# ============ KẾT LUẬN ============
echo -e "\n${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            ✅ TEST HOÀN TẤT!               ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"

echo -e "\n${CYAN}📁 Log files:${NC}"
echo -e "  Consumer log: ${BLUE}$CONSUMER_LOG${NC}"
echo -e "  Timing log:   ${BLUE}$TIMING_LOG${NC}"

echo -e "\n${CYAN}💡 Xem chi tiết:${NC}"
echo -e "  • Head: ${YELLOW}head -20 $CONSUMER_LOG${NC}"
echo -e "  • Tail: ${YELLOW}tail -20 $CONSUMER_LOG${NC}"
echo -e "  • Gaps: ${YELLOW}cat $CONSUMER_LOG | cut -d' ' -f1 | awk 'NR>1{print \$1-prev} {prev=\$1}' | sort -n | tail -5${NC}"