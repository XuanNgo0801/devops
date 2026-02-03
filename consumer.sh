#!/bin/bash

# Script để nhận messages và hiển thị với timestamp
# Dùng cho TERMINAL 2 - Consumer

# ============ CẤU HÌNH ============
KAFKA_CONTAINER="kafka-1"
BOOTSTRAP_SERVER="localhost:9092"
TOPIC_NAME="test-failover"
# ==================================

echo "👂 Kafka Consumer - Nhận messages"
echo "Topic: $TOPIC_NAME"
echo "=========================================="
echo ""

docker exec -i $KAFKA_CONTAINER kafka-console-consumer \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --topic $TOPIC_NAME \
    --from-beginning | while IFS= read -r line; do
        TIMESTAMP=$(date +%H:%M:%S.%N | cut -c1-12)
        echo "[$TIMESTAMP] $line"
    done