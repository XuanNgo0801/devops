#!/bin/bash

# Script to export Kafka topics from Docker Compose deployment to JSON
# Usage: ./export_kafka_topics.sh [output_file]

set -e

# Configuration
DOCKER_CONTAINER_NAME="kafka"  # Change this to your Kafka container name
OUTPUT_FILE="${1:-kafka_topics.json}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Kafka Topic Export Script ===${NC}"
echo "Exporting topics from Docker container: $DOCKER_CONTAINER_NAME"

# Check if Docker container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${DOCKER_CONTAINER_NAME}$"; then
    echo -e "${RED}Error: Docker container '${DOCKER_CONTAINER_NAME}' is not running${NC}"
    exit 1
fi

# Get all topics description in one call
echo "Fetching all topics information..."
ALL_TOPICS_DESC=$(docker exec $DOCKER_CONTAINER_NAME kafka-topics --bootstrap-server localhost:9092 --describe)

if [ -z "$ALL_TOPICS_DESC" ]; then
    echo -e "${YELLOW}Warning: No topics found${NC}"
    echo "[]" > "$OUTPUT_FILE"
    exit 0
fi

# Get list of unique topic names (excluding internal topics)
TOPICS=$(echo "$ALL_TOPICS_DESC" | grep "Topic:" | awk '{print $2}' | grep -v "^__" | sort -u)

if [ -z "$TOPICS" ]; then
    echo -e "${YELLOW}Warning: No non-internal topics found${NC}"
    echo "[]" > "$OUTPUT_FILE"
    exit 0
fi

# Get all topic configs in one call
echo "Fetching all topic configurations..."
ALL_CONFIGS=$(docker exec $DOCKER_CONTAINER_NAME kafka-configs \
    --bootstrap-server localhost:9092 \
    --entity-type topics \
    --describe --all 2>/dev/null || echo "")

# Initialize JSON array
echo "[" > "$OUTPUT_FILE"

FIRST_TOPIC=true

# Loop through each topic and extract its information
for TOPIC in $TOPICS; do
    echo "Processing topic: $TOPIC"
    
    # Extract topic-specific description from the full output
    TOPIC_INFO=$(echo "$ALL_TOPICS_DESC" | grep "Topic: $TOPIC" | head -1)
    
    # Extract partitions count
    PARTITIONS=$(echo "$TOPIC_INFO" | sed -n 's/.*PartitionCount: \([0-9]*\).*/\1/p')
    
    # Extract replication factor
    REPLICATION=$(echo "$TOPIC_INFO" | sed -n 's/.*ReplicationFactor: \([0-9]*\).*/\1/p')
    
    # Extract topic-specific configs from the full config output
    CONFIGS=$(echo "$ALL_CONFIGS" | awk "/Configs for topic '$TOPIC'/,/^$/" | grep "=" || true)
    
    # Parse configurations into JSON format
    CONFIG_JSON="{"
    if [ -n "$CONFIGS" ]; then
        while IFS= read -r line; do
            if [[ $line == *"="* ]]; then
                KEY=$(echo "$line" | cut -d'=' -f1 | xargs)
                VALUE=$(echo "$line" | cut -d'=' -f2- | xargs)
                if [ "$CONFIG_JSON" != "{" ]; then
                    CONFIG_JSON+=","
                fi
                CONFIG_JSON+="\"$KEY\":\"$VALUE\""
            fi
        done <<< "$CONFIGS"
    fi
    CONFIG_JSON+="}"
    
    # Add comma if not first topic
    if [ "$FIRST_TOPIC" = false ]; then
        echo "," >> "$OUTPUT_FILE"
    fi
    FIRST_TOPIC=false
    
    # Write topic information to JSON
    cat >> "$OUTPUT_FILE" << JSON_BLOCK
  {
    "name": "$TOPIC",
    "partitions": $PARTITIONS,
    "replication_factor": $REPLICATION,
    "configs": $CONFIG_JSON
  }
JSON_BLOCK

done

# Close JSON array
echo "" >> "$OUTPUT_FILE"
echo "]" >> "$OUTPUT_FILE"

echo -e "${GREEN}Export completed successfully!${NC}"
echo "Topics exported to: $OUTPUT_FILE"

# Display summary
TOPIC_COUNT=$(jq '. | length' "$OUTPUT_FILE")
echo -e "${GREEN}Total topics exported: $TOPIC_COUNT${NC}"