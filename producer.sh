#!/bin/bash

# Script đơn giản để đẩy messages liên tục với timestamp
# Dùng cho TERMINAL 1 - Producer

# ============ CẤU HÌNH ============
KAFKA_CONTAINER="kafka-1"
BOOTSTRAP_SERVER="localhost:9092"
TOPIC_NAME="test-failover"
NUM_MESSAGES=1000        # Tổng số messages
DELAY=0.05              # Delay giữa các messages (giây)
# ==================================

echo "🚀 Kafka Producer - Đẩy messages với timestamp"
echo "Topic: $TOPIC_NAME"
echo "Số messages: $NUM_MESSAGES"
echo "Delay: ${DELAY}s"
echo "=========================================="
echo ""

for i in $(seq 1 $NUM_MESSAGES); do
    TIMESTAMP=$(date +%H:%M:%S.%N | cut -c1-12)
    MESSAGE="MSG_${i} at ${TIMESTAMP}"
    echo "$MESSAGE"
    sleep $DELAY
done | docker exec -i $KAFKA_CONTAINER kafka-console-producer \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --topic $TOPIC_NAME

echo ""
echo "✅ Đã gửi xong $NUM_MESSAGES messages!"