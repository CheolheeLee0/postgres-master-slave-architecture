#!/bin/bash

# Quick Failover Test Script
# Runs all test steps automatically

set -e

echo "🚀 Quick PostgreSQL Failover Test"
echo "================================="
echo ""

# Step 1: Setup
echo "1️⃣ Setting up Master-Slave..."
./setup-master-slave.sh
echo ""
sleep 5

# Step 2: Initial health check
echo "2️⃣ Checking initial health..."
./health-check.sh
echo ""
sleep 2

# Step 3: Test write operations
echo "3️⃣ Testing write operations..."
echo "Writing to Master (should succeed):"
docker exec postgres_master psql -U postgres -d postgres -c "INSERT INTO users (username, email) VALUES ('before_failover', 'before@test.com') RETURNING id, username;"

echo ""
echo "Writing to Slave (should fail):"
docker exec postgres_slave psql -U postgres -d postgres -c "INSERT INTO users (username, email) VALUES ('slave_test', 'slave@test.com');" 2>&1 || echo "✅ Expected: Slave correctly rejected write operation"
echo ""
sleep 2

# Step 4: Stop master
echo "4️⃣ Simulating Master failure..."
echo "Stopping Master container..."
docker stop postgres_master
echo "✅ Master stopped"
echo ""
sleep 2

# Step 5: Check health with master down
echo "5️⃣ Checking health with Master down..."
./health-check.sh
echo ""
sleep 2

# Step 6: Perform failover
echo "6️⃣ Performing failover..."
echo "Promoting Slave to Master..."
# Auto-answer 'n' to skip the confirmation since master is already down
echo "n" | ./failover.sh
echo ""
sleep 3

# Step 7: Test new master
echo "7️⃣ Testing new Master (former Slave)..."
echo "Writing to new Master (port 15433):"
docker exec postgres_slave psql -U postgres -d postgres -c "INSERT INTO users (username, email) VALUES ('after_failover', 'after@test.com') RETURNING id, username;"
echo "✅ New Master accepts writes!"
echo ""

# Step 8: Final health check
echo "8️⃣ Final health check..."
./health-check.sh
echo ""

# Summary
echo "📊 Test Summary"
echo "==============="
echo "✅ Master-Slave setup completed"
echo "✅ Initial replication verified"
echo "✅ Master failure simulated"
echo "✅ Slave promoted to Master"
echo "✅ New Master accepts read/write operations"
echo ""
echo "🎉 Failover test completed successfully!"
echo ""
echo "New Master is running on port 15433"
echo "Connect with: psql -h localhost -p 15433 -U postgres -d postgres"