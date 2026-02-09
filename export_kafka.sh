#!/bin/bash

# Script to export Kafka topics configuration from Docker Compose cluster
# Output: JSON file containing all topics with their configurations
# Usage: ./export-topics.sh [output_file]

set -e

# ===== CONFIGURATION =====
# Docker Compose service name for Kafka
KAFKA_CONTAINER_NAME="kafka"

# Output file
OUTPUT_FILE="${1:-topics-export.json}"

# Kafka broker inside container
KAFKA_BROKER="localhost:9092"

# ===== COLOR OUTPUT =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ===== FUNCTIONS =====
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_docker_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${KAFKA_CONTAINER_NAME}$"; then
        log_error "Kafka container '${KAFKA_CONTAINER_NAME}' is not running"
        log_info "Available containers:"
        docker ps --format "table {{.Names}}\t{{.Status}}"
        exit 1
    fi
    log_info "Found running Kafka container: ${KAFKA_CONTAINER_NAME}"
}

get_topic_list() {
    log_info "Fetching topic list from Kafka cluster..."
    
    topics=$(docker exec ${KAFKA_CONTAINER_NAME} \
        kafka-topics.sh \
        --bootstrap-server ${KAFKA_BROKER} \
        --list 2>/dev/null)
    
    echo "$topics"
}

get_topic_details() {
    local topic=$1
    
    # Get describe output
    describe_output=$(docker exec ${KAFKA_CONTAINER_NAME} \
        kafka-topics.sh \
        --bootstrap-server ${KAFKA_BROKER} \
        --describe \
        --topic "$topic" 2>/dev/null)
    
    # Parse partitions and replication factor
    partitions=$(echo "$describe_output" | grep "PartitionCount" | grep -oP 'PartitionCount:\s*\K\d+')
    replication_factor=$(echo "$describe_output" | grep "ReplicationFactor" | grep -oP 'ReplicationFactor:\s*\K\d+')
    
    # Get topic configs
    configs_output=$(docker exec ${KAFKA_CONTAINER_NAME} \
        kafka-configs.sh \
        --bootstrap-server ${KAFKA_BROKER} \
        --describe \
        --entity-type topics \
        --entity-name "$topic" 2>/dev/null || echo "")
    
    # Parse configs into JSON format
    configs_json="{"
    first=true
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([^=]+)=(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            
            # Skip empty or header lines
            if [[ -z "$key" ]] || [[ "$key" == *"Dynamic configs"* ]]; then
                continue
            fi
            
            # Remove leading/trailing whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            
            if [ "$first" = true ]; then
                first=false
            else
                configs_json+=","
            fi
            
            # Escape quotes in value
            value=$(echo "$value" | sed 's/"/\\"/g')
            configs_json+="\"$key\":\"$value\""
        fi
    done <<< "$configs_output"
    
    configs_json+="}"
    
    # Return JSON object for this topic
    cat <<EOF
{
  "name": "$topic",
  "partitions": ${partitions:-1},
  "replication_factor": ${replication_factor:-1},
  "configs": $configs_json
}
EOF
}

export_topics_to_json() {
    local output_file=$1
    
    # Get all topics
    topics=$(get_topic_list)
    
    if [ -z "$topics" ]; then
        log_warn "No topics found in Kafka cluster"
        echo "[]" > "$output_file"
        return
    fi
    
    topic_count=$(echo "$topics" | wc -l)
    log_info "Found $topic_count topics"
    
    # Start JSON array
    echo "[" > "$output_file"
    
    first=true
    counter=0
    
    while IFS= read -r topic; do
        if [ -z "$topic" ]; then
            continue
        fi
        
        counter=$((counter + 1))
        log_info "Processing topic [$counter/$topic_count]: $topic"
        
        # Get topic details
        topic_json=$(get_topic_details "$topic")
        
        # Add comma between objects (not before first or after last)
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$output_file"
        fi
        
        # Append topic JSON (with proper indentation)
        echo "$topic_json" | sed 's/^/  /' >> "$output_file"
        
    done <<< "$topics"
    
    # Close JSON array
    echo "" >> "$output_file"
    echo "]" >> "$output_file"
    
    log_info "Successfully exported $counter topics to: $output_file"
}

# ===== MAIN =====
main() {
    echo "======================================"
    echo "Kafka Topics Export Tool (Docker)"
    echo "======================================"
    echo ""
    
    # Check if docker is available
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi
    
    # Check if Kafka container is running
    check_docker_container
    
    # Export topics
    export_topics_to_json "$OUTPUT_FILE"
    
    echo ""
    echo "======================================"
    echo "Export completed successfully!"
    echo "======================================"
    echo "Output file: $OUTPUT_FILE"
    echo ""
    echo "To import topics to another cluster:"
    echo "  ./import-topics.sh $OUTPUT_FILE"
    echo ""
}

main "$@"