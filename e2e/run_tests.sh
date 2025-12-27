#!/bin/bash
set -e

echo "=== EctoLiteFS E2E Tests ==="
echo ""

cd "$(dirname "$0")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker-compose down -v --remove-orphans 2>/dev/null || true
}

trap cleanup EXIT

echo -e "${YELLOW}Building Docker images...${NC}"
docker-compose build

echo -e "\n${YELLOW}Starting cluster...${NC}"
docker-compose up -d

echo -e "\n${YELLOW}Waiting for services to be healthy...${NC}"
sleep 5

# Wait for Consul to be ready
CONSUL_READY=false
for i in {1..15}; do
    if curl -s http://localhost:8500/v1/status/leader 2>/dev/null | grep -q ":"; then
        echo -e "${GREEN}Consul is ready${NC}"
        CONSUL_READY=true
        break
    fi
    echo "Waiting for Consul... ($i/15)"
    sleep 2
done

if [ "$CONSUL_READY" = "false" ]; then
    echo -e "${RED}Consul failed to start${NC}"
    docker-compose logs consul
    exit 1
fi

# Wait for primary to be ready
PRIMARY_READY=false
for i in {1..30}; do
    if curl -s http://localhost:4001/health > /dev/null 2>&1; then
        echo -e "${GREEN}Primary is ready${NC}"
        PRIMARY_READY=true
        break
    fi
    echo "Waiting for primary... ($i/30)"
    sleep 2
done

if [ "$PRIMARY_READY" = "false" ]; then
    echo -e "${RED}Primary failed to start${NC}"
    docker-compose logs primary
    exit 1
fi

# Wait for replica to be ready
REPLICA_READY=false
for i in {1..30}; do
    if curl -s http://localhost:4002/health > /dev/null 2>&1; then
        echo -e "${GREEN}Replica is ready${NC}"
        REPLICA_READY=true
        break
    fi
    echo "Waiting for replica... ($i/30)"
    sleep 2
done

if [ "$REPLICA_READY" = "false" ]; then
    echo -e "${RED}Replica failed to start${NC}"
    docker-compose logs replica
    exit 1
fi

echo -e "\n${YELLOW}=== Test 1: Check cluster status ===${NC}"
echo "Primary status:"
curl -s http://localhost:4001/status | jq .
echo ""
echo "Replica status:"
curl -s http://localhost:4002/status | jq .

echo -e "\n${YELLOW}=== Test 2: Write to primary, read from both ===${NC}"
echo "Creating item on primary..."
curl -s -X POST http://localhost:4001/items \
    -H "Content-Type: application/json" \
    -d '{"name": "item_from_primary"}' | jq .

sleep 2

echo -e "\nReading from primary:"
PRIMARY_ITEMS=$(curl -s http://localhost:4001/items)
echo "$PRIMARY_ITEMS" | jq .

echo -e "\nReading from replica:"
REPLICA_ITEMS=$(curl -s http://localhost:4002/items)
echo "$REPLICA_ITEMS" | jq .

# Verify replication
if echo "$REPLICA_ITEMS" | grep -q "item_from_primary"; then
    echo -e "${GREEN}✓ Data replicated to replica${NC}"
else
    echo -e "${RED}✗ Data NOT replicated to replica${NC}"
    exit 1
fi

echo -e "\n${YELLOW}=== Test 3: Write forwarding from replica ===${NC}"
echo "Creating item via replica (should forward to primary)..."
FORWARD_RESULT=$(curl -s -X POST http://localhost:4002/items \
    -H "Content-Type: application/json" \
    -d '{"name": "item_from_replica"}')
echo "$FORWARD_RESULT" | jq .

if echo "$FORWARD_RESULT" | grep -q "created"; then
    echo -e "${GREEN}✓ Write forwarded successfully${NC}"
else
    echo -e "${RED}✗ Write forwarding failed${NC}"
    exit 1
fi

sleep 2

echo -e "\nVerifying item exists on both nodes..."
echo "Primary items:"
curl -s http://localhost:4001/items | jq .

echo -e "\nReplica items:"
curl -s http://localhost:4002/items | jq .

echo -e "\n${YELLOW}=== Test 4: Primary failover ===${NC}"
echo "Current replica status before failover:"
curl -s http://localhost:4002/status | jq .

echo -e "\nStopping primary container..."
docker-compose stop primary

echo -e "\nWaiting for replica to become primary..."
FAILOVER_SUCCESS=false
for i in {1..30}; do
    REPLICA_STATUS=$(curl -s http://localhost:4002/status 2>/dev/null || echo "{}")
    IS_PRIMARY=$(echo "$REPLICA_STATUS" | jq -r '.is_primary // false')
    
    if [ "$IS_PRIMARY" = "true" ]; then
        echo -e "${GREEN}Replica promoted to primary after ~$((i * 2)) seconds${NC}"
        echo "$REPLICA_STATUS" | jq .
        FAILOVER_SUCCESS=true
        break
    fi
    
    echo "Waiting for promotion... ($i/30) - is_primary: $IS_PRIMARY"
    sleep 2
done

if [ "$FAILOVER_SUCCESS" = "false" ]; then
    echo -e "${RED}✗ Failover failed - replica did not become primary${NC}"
    exit 1
fi

echo -e "\nTesting write on new primary (formerly replica)..."
FAILOVER_WRITE=$(curl -s -X POST http://localhost:4002/items \
    -H "Content-Type: application/json" \
    -d '{"name": "item_after_failover"}')
echo "$FAILOVER_WRITE" | jq .

if echo "$FAILOVER_WRITE" | grep -q "created"; then
    echo -e "${GREEN}✓ Write successful on new primary${NC}"
else
    echo -e "${RED}✗ Write failed on new primary${NC}"
    exit 1
fi

echo -e "\nVerifying all items exist on new primary:"
curl -s http://localhost:4002/items | jq .

# Verify we have all 3 items
ITEM_COUNT=$(curl -s http://localhost:4002/items | jq 'length')
if [ "$ITEM_COUNT" = "3" ]; then
    echo -e "${GREEN}✓ All 3 items present after failover${NC}"
else
    echo -e "${RED}✗ Expected 3 items, got $ITEM_COUNT${NC}"
    exit 1
fi

echo -e "\n${GREEN}=== All E2E tests passed! ===${NC}"
