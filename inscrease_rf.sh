#!/bin/bash

# Script để tăng Replication Factor từ 2 lên 3
# Dùng cho TERMINAL 3 - Increase RF

# ============ CẤU HÌNH ============
KAFKA_CONTAINER="kafka-1"
BOOTSTRAP_SERVER="localhost:9092"
TOPIC_NAME="test-failover"
PARTITION_COUNT=3        # Số partitions của topic
# ==================================

echo "🔄 Kafka Increase Replication Factor"
echo "Topic: $TOPIC_NAME"
echo "RF: 2 -> 3"
echo "=========================================="
echo ""

# Hiển thị topic trước khi thay đổi
echo "📋 Topic TRƯỚC khi tăng RF:"
docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --describe --topic $TOPIC_NAME

echo ""
echo "⏳ Đợi 3 giây trước khi tăng RF..."
sleep 3

# Tạo reassignment config
cat > /tmp/increase_rf.json <<EOF
{
  "version": 1,
  "partitions": [
    {"topic": "$TOPIC_NAME", "partition": 0, "replicas": [0,1,2]},
    {"topic": "$TOPIC_NAME", "partition": 1, "replicas": [1,2,3]},
    {"topic": "$TOPIC_NAME", "partition": 2, "replicas": [2,3,4]}
  ]
}
EOF

docker cp /tmp/increase_rf.json $KAFKA_CONTAINER:/tmp/

echo ""
echo "🚀 BẮT ĐẦU TĂNG REPLICATION FACTOR - Thời gian: $(date +%H:%M:%S)"
echo "=========================================="

# Execute reassignment
docker exec $KAFKA_CONTAINER kafka-reassign-partitions \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --reassignment-json-file /tmp/increase_rf.json \
    --execute

echo ""
echo "⏳ Đợi reassignment hoàn tất..."
echo -n "Progress: "

# Đợi hoàn tất
COUNTER=0
while true; do
    VERIFY_RESULT=$(docker exec $KAFKA_CONTAINER kafka-reassign-partitions \
        --bootstrap-server $BOOTSTRAP_SERVER \
        --reassignment-json-file /tmp/increase_rf.json \
        --verify 2>&1)
    
    if echo "$VERIFY_RESULT" | grep -q "still in progress"; then
        echo -n "."
        COUNTER=$((COUNTER + 1))
        sleep 1
    else
        echo " ✅"
        break
    fi
    
    if [ $COUNTER -ge 60 ]; then
        echo ""
        echo "⚠️  Timeout sau 60s"
        break
    fi
done

echo ""
echo "✅ HOÀN TẤT TĂNG RF - Thời gian: $(date +%H:%M:%S)"
echo "Tổng thời gian: ${COUNTER} giây"
echo "=========================================="

# Hiển thị topic sau khi thay đổi
echo ""
echo "📋 Topic SAU khi tăng RF:"
docker exec $KAFKA_CONTAINER kafka-topics \
    --bootstrap-server $BOOTSTRAP_SERVER \
    --describe --topic $TOPIC_NAME

echo ""
echo "🎉 Kiểm tra Consumer ở Terminal 2 xem có bị gián đoạn không!"