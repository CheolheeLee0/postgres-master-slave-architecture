#!/bin/bash

# PostgreSQL Master-Slave Failover Test Scenario
# Step-by-step guide to test failover functionality

set -e

echo "PostgreSQL Master-Slave Failover Test Scenario"
echo "=============================================="
echo ""
echo "This script will guide you through testing the failover functionality"
echo ""

# Function to pause and wait for user
pause() {
    echo ""
    read -p "Press Enter to continue..."
    echo ""
}

# Step 1: Setup
echo "📋 Step 1: Initial Setup"
echo "------------------------"
echo "First, let's ensure the master-slave setup is running"
echo ""
echo "Run: ./setup-master-slave.sh"
echo ""
pause

# Step 2: Check initial health
echo "📋 Step 2: Check Initial Health"
echo "-------------------------------"
echo "Let's check the health of both servers"
echo ""
echo "Run: ./health-check.sh"
echo ""
echo "You should see:"
echo "  - Master is UP (port 15432)"
echo "  - Slave is UP and in recovery mode (port 15433)"
echo "  - Data is synchronized"
pause

# Step 3: Test write operations
echo "📋 Step 3: Test Write Operations"
echo "--------------------------------"
echo "Let's verify that only master can accept writes"
echo ""
echo "Test writing to master (should succeed):"
echo 'docker exec postgres_master psql -U postgres -d postgres -c "INSERT INTO users (name, email) VALUES ('"'"'test_user'"'"', '"'"'test@example.com'"'"');"'
echo ""
echo "Test writing to slave (should fail):"
echo 'docker exec postgres_slave psql -U postgres -d postgres -c "INSERT INTO users (name, email) VALUES ('"'"'test_user2'"'"', '"'"'test2@example.com'"'"');"'
echo ""
echo "The slave write should fail with: 'cannot execute INSERT in a read-only transaction'"
pause

# Step 4: Run comprehensive test
echo "📋 Step 4: Run Comprehensive Replication Test"
echo "---------------------------------------------"
echo "Let's run the full replication test to ensure everything works"
echo ""
echo "Run: python3 test_master_slave.py"
echo ""
echo "This will test data replication between master and slave"
pause

# Step 5: Simulate master failure
echo "📋 Step 5: Simulate Master Failure"
echo "----------------------------------"
echo "Now let's simulate a master server failure"
echo ""
echo "Stop the master server:"
echo "docker stop postgres_master"
echo ""
echo "After stopping, check health again:"
echo "./health-check.sh"
echo ""
echo "You should see:"
echo "  - Master is DOWN"
echo "  - Slave is still UP"
echo "  - Warning to run failover"
pause

# Step 6: Perform failover
echo "📋 Step 6: Perform Failover"
echo "---------------------------"
echo "Now let's promote the slave to become the new master"
echo ""
echo "Run: ./failover.sh"
echo ""
echo "This will:"
echo "  1. Check master status"
echo "  2. Promote slave to master"
echo "  3. Stop old master (if still running)"
echo "  4. Show new master status"
pause

# Step 7: Verify new master
echo "📋 Step 7: Verify New Master"
echo "----------------------------"
echo "Let's verify the failover was successful"
echo ""
echo "Check health status:"
echo "./health-check.sh"
echo ""
echo "You should see that the slave (port 15433) is no longer in recovery mode"
echo ""
echo "Test write operation on new master (former slave):"
echo 'docker exec postgres_slave psql -U postgres -d postgres -c "INSERT INTO users (name, email) VALUES ('"'"'failover_test'"'"', '"'"'failover@test.com'"'"');"'
echo ""
echo "This should now succeed!"
pause

# Step 8: Run automated test
echo "📋 Step 8: Run Automated Failover Test"
echo "--------------------------------------"
echo "For a fully automated test, you can run:"
echo ""
echo "python3 test_failover.py"
echo ""
echo "This will automatically:"
echo "  1. Test initial state"
echo "  2. Stop master"
echo "  3. Run failover"
echo "  4. Test new master write capability"
echo "  5. Show summary"
pause

# Step 9: Cleanup
echo "📋 Step 9: Cleanup and Reset"
echo "----------------------------"
echo "To reset everything and start fresh:"
echo ""
echo "Run: ./rm-docker.sh"
echo "Then: ./setup-master-slave.sh"
echo ""
echo "This will remove all containers and data, then set up fresh master-slave replication"
pause

# Summary
echo "📋 Summary"
echo "----------"
echo ""
echo "Key Commands:"
echo "  1. ./setup-master-slave.sh    - Initial setup"
echo "  2. ./health-check.sh          - Check server health"
echo "  3. ./failover.sh              - Promote slave when master fails"
echo "  4. python3 test_failover.py   - Automated failover test"
echo "  5. ./rm-docker.sh             - Clean up everything"
echo ""
echo "After failover:"
echo "  - Old master (port 15432) is stopped"
echo "  - New master (former slave, port 15433) accepts read/write"
echo "  - Connect to new master at: psql -h localhost -p 15433 -U postgres -d postgres"
echo ""
echo "✅ Test scenario guide completed!"