#!/bin/bash

echo "=== PostgreSQL Active-Active Replication Test ==="
echo

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to execute SQL
exec_sql() {
    local port=$1
    local sql=$2
    PGPASSWORD=postgres123 psql -h localhost -p $port -U postgres -d testdb -t -c "$sql"
}

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    if [ "$status" = "SUCCESS" ]; then
        echo -e "${GREEN}[SUCCESS]${NC} $message"
    elif [ "$status" = "FAIL" ]; then
        echo -e "${RED}[FAIL]${NC} $message"
    else
        echo -e "${YELLOW}[INFO]${NC} $message"
    fi
}

# Wait for services to be ready
print_status "INFO" "Waiting for services to be ready..."

# Test 1: Insert data on postgres1
print_status "INFO" "Test 1: Inserting data on postgres1 (port 5432)"
exec_sql 5432 "INSERT INTO test_data (node_name, data) VALUES ('postgres1', 'Test data from node 1');"
exec_sql 5432 "INSERT INTO test_data (node_name, data) VALUES ('postgres1', 'Another test from node 1');"

# Test 2: Insert data on postgres2
print_status "INFO" "Test 2: Inserting data on postgres2 (port 5434)"
exec_sql 5434 "INSERT INTO test_data (node_name, data) VALUES ('postgres2', 'Test data from node 2');"
exec_sql 5434 "INSERT INTO test_data (node_name, data) VALUES ('postgres2', 'Another test from node 2');"

# Wait for replication
print_status "INFO" "Waiting for replication to complete..."
sleep 5

# Test 3: Verify data on both nodes
print_status "INFO" "Test 3: Verifying data replication"
echo
echo "Data on postgres1 (port 5432):"
exec_sql 5432 "SELECT id, node_name, data, created_at FROM test_data ORDER BY id;"

echo
echo "Data on postgres2 (port 5434):"
exec_sql 5434 "SELECT id, node_name, data, created_at FROM test_data ORDER BY id;"

# Test 4: Count verification
count1=$(exec_sql 5432 "SELECT COUNT(*) FROM test_data;" | tr -d ' ')
count2=$(exec_sql 5434 "SELECT COUNT(*) FROM test_data;" | tr -d ' ')

echo
if [ "$count1" = "$count2" ] && [ "$count1" = "4" ]; then
    print_status "SUCCESS" "Data count matches on both nodes: $count1 records"
else
    print_status "FAIL" "Data count mismatch! Node1: $count1, Node2: $count2"
fi

# Test 5: Update test
print_status "INFO" "Test 5: Testing updates"
exec_sql 5432 "UPDATE test_data SET data = 'Updated from node 1' WHERE id = 1;"
sleep 3

# Verify update propagated
updated_data=$(exec_sql 5434 "SELECT data FROM test_data WHERE id = 1;" | tr -d ' \n')
if [[ "$updated_data" == *"Updated from node 1"* ]]; then
    print_status "SUCCESS" "Update from node 1 successfully replicated to node 2"
else
    print_status "FAIL" "Update replication failed"
fi

# Test 6: Conflict resolution test
print_status "INFO" "Test 6: Testing conflict resolution (updating same row on both nodes)"
exec_sql 5432 "UPDATE test_data SET data = 'Conflict test from node 1' WHERE id = 2;" &
exec_sql 5434 "UPDATE test_data SET data = 'Conflict test from node 2' WHERE id = 2;" &
wait
sleep 3

# Check final state
final_data1=$(exec_sql 5432 "SELECT data FROM test_data WHERE id = 2;" | tr -d ' \n')
final_data2=$(exec_sql 5434 "SELECT data FROM test_data WHERE id = 2;" | tr -d ' \n')

echo
echo "After conflict resolution:"
echo "Node 1 data for id=2: $final_data1"
echo "Node 2 data for id=2: $final_data2"

if [ "$final_data1" = "$final_data2" ]; then
    print_status "SUCCESS" "Conflict resolved - both nodes have same data"
else
    print_status "FAIL" "Conflict not resolved - nodes have different data"
fi

# Test 7: Replication status check
print_status "INFO" "Test 7: Checking replication status"
echo
echo "Replication status on postgres1:"
exec_sql 5432 "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"

echo
echo "Replication status on postgres2:"
exec_sql 5434 "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"

echo
echo "Subscription status on postgres1:"
exec_sql 5432 "SELECT subname, subenabled FROM pg_subscription;"

echo
echo "Subscription status on postgres2:"
exec_sql 5434 "SELECT subname, subenabled FROM pg_subscription;"

echo
print_status "INFO" "Active-Active replication test completed!"