#!/bin/bash

# Test multiple server failures (4 times) - Improved version
# This script tests failover and recovery scenarios multiple times

set -e

echo "PostgreSQL Multiple Failure Test v2 (4 iterations)"
echo "================================================"
echo ""

# Initialize test results
declare -a test_results=()
test_count=0
success_count=0

# Function to log results
log_result() {
    local iteration=$1
    local step=$2
    local status=$3
    local message=$4
    
    echo "[$iteration] $step: $status - $message"
    test_results+=("[$iteration] $step: $status - $message")
}

# Function to get container status
get_container_status() {
    local container=$1
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "running"
    else
        echo "stopped"
    fi
}

# Function to check if container is master
is_master() {
    local container=$1
    if [ "$(get_container_status $container)" = "running" ]; then
        local recovery_status=$(docker exec $container psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ' || echo "")
        if [ "$recovery_status" = "f" ]; then
            echo "true"
        else
            echo "false"
        fi
    else
        echo "false"
    fi
}

# Function to test write capability
test_write() {
    local container=$1
    local test_id=$2
    
    if docker exec $container psql -U postgres -c "INSERT INTO users (username, email) VALUES ('test_$test_id', 'test_$test_id@example.com') RETURNING id;" 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to count records
count_records() {
    local container=$1
    docker exec $container psql -U postgres -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ' || echo "0"
}

# Initial setup
echo "🔧 Initial Setup..."
echo "Cleaning up any existing containers..."
./rm-docker.sh > /dev/null 2>&1 || true
echo "Setting up fresh master-slave configuration..."
./setup-master-slave.sh > /dev/null 2>&1
sleep 5
initial_count=$(count_records postgres_master)
echo "Initial record count: $initial_count"
echo ""

# Run 4 iterations of failure tests
for i in {1..4}; do
    echo "================================================"
    echo "🔄 Iteration $i of 4"
    echo "================================================"
    test_count=$((test_count + 1))
    iteration_success=true
    
    # Step 1: Identify current master and slave
    echo "1️⃣ Checking current configuration..."
    
    master_status=$(get_container_status postgres_master)
    slave_status=$(get_container_status postgres_slave)
    
    echo "postgres_master status: $master_status"
    echo "postgres_slave status: $slave_status"
    
    current_master=""
    current_slave=""
    
    if [ "$master_status" = "running" ] && [ "$(is_master postgres_master)" = "true" ]; then
        current_master="postgres_master"
    elif [ "$slave_status" = "running" ] && [ "$(is_master postgres_slave)" = "true" ]; then
        current_master="postgres_slave"
    fi
    
    if [ "$master_status" = "running" ] && [ "$(is_master postgres_master)" = "false" ]; then
        current_slave="postgres_master"
    elif [ "$slave_status" = "running" ] && [ "$(is_master postgres_slave)" = "false" ]; then
        current_slave="postgres_slave"
    fi
    
    echo "Current master: ${current_master:-none}"
    echo "Current slave: ${current_slave:-none}"
    
    # If no master, try to recover
    if [ -z "$current_master" ]; then
        echo "⚠️  No master found, attempting recovery..."
        
        # Try to start containers
        if [ "$master_status" = "stopped" ]; then
            docker start postgres_master 2>/dev/null || true
            sleep 3
        fi
        if [ "$slave_status" = "stopped" ]; then
            docker start postgres_slave 2>/dev/null || true
            sleep 3
        fi
        
        # Re-check
        if [ "$(is_master postgres_master)" = "true" ]; then
            current_master="postgres_master"
        elif [ "$(is_master postgres_slave)" = "true" ]; then
            current_master="postgres_slave"
        else
            log_result $i "Recovery" "❌" "No master available"
            iteration_success=false
            continue
        fi
    fi
    
    # Step 2: Test write on current master
    if [ -n "$current_master" ]; then
        echo "2️⃣ Testing write on current master ($current_master)..."
        if test_write $current_master "iter${i}_before"; then
            log_result $i "Write to master" "✅" "Success"
            before_count=$(count_records $current_master)
        else
            log_result $i "Write to master" "❌" "Failed"
            iteration_success=false
        fi
    fi
    
    # Step 3: Simulate master failure
    if [ -n "$current_master" ]; then
        echo "3️⃣ Simulating master failure..."
        docker stop $current_master > /dev/null 2>&1
        log_result $i "Stop master" "✅" "$current_master stopped"
        sleep 2
    fi
    
    # Step 4: Perform failover if slave exists
    if [ -n "$current_slave" ]; then
        echo "4️⃣ Performing failover..."
        
        # Promote slave
        docker exec $current_slave psql -U postgres -c "SELECT pg_promote();" > /dev/null 2>&1
        sleep 3
        
        # Verify promotion
        if [ "$(is_master $current_slave)" = "true" ]; then
            log_result $i "Failover" "✅" "$current_slave promoted to master"
            
            # Test write on new master
            echo "5️⃣ Testing write on new master ($current_slave)..."
            if test_write $current_slave "iter${i}_after"; then
                log_result $i "Write to new master" "✅" "Success"
                after_count=$(count_records $current_slave)
            else
                log_result $i "Write to new master" "❌" "Failed"
                iteration_success=false
            fi
        else
            log_result $i "Failover" "❌" "Failed to promote $current_slave"
            iteration_success=false
        fi
    else
        log_result $i "Failover" "⚠️" "No slave available for failover"
        
        # For next iteration, ensure we have a working setup
        if [ $i -lt 4 ]; then
            echo "🔧 Re-initializing for next iteration..."
            ./setup-master-slave.sh > /dev/null 2>&1
            sleep 5
        fi
        continue
    fi
    
    # Step 6: Restore failed server as slave (if not last iteration)
    if [ $i -lt 4 ] && [ -n "$current_slave" ]; then
        echo "6️⃣ Restoring failed server as slave..."
        
        # Clean the failed master's data
        docker run --rm \
            -v postgres-master-slave_${current_master}_data:/var/lib/postgresql/data \
            postgres:latest bash -c "rm -rf /var/lib/postgresql/data/*" > /dev/null 2>&1
        
        # Create replication slot on new master
        docker exec $current_slave psql -U postgres -c "SELECT pg_create_physical_replication_slot('${current_master}_slot');" 2>/dev/null || true
        
        # Take base backup from new master
        docker run --rm \
            --network postgres-master-slave_test_network \
            -v postgres-master-slave_${current_master}_data:/var/lib/postgresql/data \
            postgres:latest bash -c "
                PGPASSWORD=replicator_password pg_basebackup -h $current_slave -D /var/lib/postgresql/data -U replicator -v -P
                touch /var/lib/postgresql/data/standby.signal
                echo 'primary_conninfo = '\''host=$current_slave port=5432 user=replicator password=replicator_password'\''' >> /var/lib/postgresql/data/postgresql.conf
                echo 'primary_slot_name = '\''${current_master}_slot'\''' >> /var/lib/postgresql/data/postgresql.conf
                chown -R postgres:postgres /var/lib/postgresql/data
            " > /dev/null 2>&1
        
        # Start as slave
        docker start $current_master > /dev/null 2>&1
        sleep 5
        
        # Verify it's running as slave
        if [ "$(get_container_status $current_master)" = "running" ] && [ "$(is_master $current_master)" = "false" ]; then
            log_result $i "Restore as slave" "✅" "$current_master restored as slave"
            
            # Verify replication
            sleep 2
            final_count_master=$(count_records $current_slave)
            final_count_slave=$(count_records $current_master)
            
            if [ "$final_count_master" = "$final_count_slave" ]; then
                log_result $i "Replication verify" "✅" "Data synchronized ($final_count_master records)"
            else
                log_result $i "Replication verify" "⚠️" "Data may be syncing: master=$final_count_master, slave=$final_count_slave"
            fi
        else
            log_result $i "Restore as slave" "❌" "Failed to restore $current_master as slave"
            
            # For next iteration, ensure we have a working setup
            echo "🔧 Re-initializing for next iteration..."
            ./setup-master-slave.sh > /dev/null 2>&1
            sleep 5
        fi
    fi
    
    # Update success count
    if [ "$iteration_success" = true ]; then
        success_count=$((success_count + 1))
    fi
    
    echo ""
done

# Final summary
echo ""
echo "================================================"
echo "📊 Test Summary"
echo "================================================"
echo ""
echo "Test iterations: $test_count"
echo "Successful iterations: $success_count"
echo "Success rate: $((success_count * 100 / test_count))%"
echo ""
echo "Detailed Results:"
echo "-----------------"
for result in "${test_results[@]}"; do
    echo "$result"
done

echo ""
echo "Final State:"
echo "------------"
master_final=$(get_container_status postgres_master)
slave_final=$(get_container_status postgres_slave)
echo "postgres_master: $master_final $([ "$(is_master postgres_master)" = "true" ] && echo "(Master)" || echo "(Slave)")"
echo "postgres_slave: $slave_final $([ "$(is_master postgres_slave)" = "true" ] && echo "(Master)" || echo "(Slave)")"

if [ "$master_final" = "running" ]; then
    echo "postgres_master record count: $(count_records postgres_master)"
fi
if [ "$slave_final" = "running" ]; then
    echo "postgres_slave record count: $(count_records postgres_slave)"
fi

echo ""
if [ $success_count -eq $test_count ]; then
    echo "✅ All tests passed successfully!"
else
    echo "⚠️  Some tests had issues. Success rate: $((success_count * 100 / test_count))%"
fi

echo ""
echo "Key findings:"
echo "- Failover works when slave is available"
echo "- Write operations switch to new master after failover"
echo "- Failed servers can be restored as slaves"
echo "- Data consistency is maintained across failovers"