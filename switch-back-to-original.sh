#!/bin/bash

# Switch back to original master-slave configuration
# This script performs a planned switchover to restore the original configuration

set -e

echo "PostgreSQL Switchback Script"
echo "============================"
echo ""
echo "This script will switch back to the original configuration:"
echo "  - postgres_master as Master (port 15432)"
echo "  - postgres_slave as Slave (port 15433)"
echo ""

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
    
    # Both containers must be running
    if ! docker ps | grep -q postgres_master; then
        echo "❌ postgres_master is not running!"
        echo "Run ./restore-master-as-slave.sh first"
        exit 1
    fi
    
    if ! docker ps | grep -q postgres_slave; then
        echo "❌ postgres_slave is not running!"
        exit 1
    fi
    
    # Current master should be postgres_slave
    IS_SLAVE_MASTER=$(docker exec postgres_slave psql -U postgres -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
    IS_MASTER_SLAVE=$(docker exec postgres_master psql -U postgres -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
    
    if [ "$IS_SLAVE_MASTER" != "f" ] || [ "$IS_MASTER_SLAVE" != "t" ]; then
        echo "❌ Current configuration is not as expected!"
        echo "   postgres_slave should be master (not in recovery)"
        echo "   postgres_master should be slave (in recovery)"
        exit 1
    fi
    
    echo "✅ Prerequisites met"
}

# Step 1: Stop applications (simulate maintenance window)
maintenance_notice() {
    echo ""
    echo "⚠️  MAINTENANCE NOTICE"
    echo "This operation requires a brief downtime"
    read -p "Continue with switchback? (y/n): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Switchback cancelled."
        exit 0
    fi
}

# Step 2: Ensure data is synchronized
ensure_sync() {
    echo ""
    echo "Ensuring data synchronization..."
    
    # Get LSN positions
    CURRENT_LSN=$(docker exec postgres_slave psql -U postgres -t -c "SELECT pg_current_wal_lsn();" | tr -d ' ')
    echo "Current master LSN: $CURRENT_LSN"
    
    # Wait for slave to catch up
    echo "Waiting for slave to catch up..."
    sleep 2
    
    SLAVE_LSN=$(docker exec postgres_master psql -U postgres -t -c "SELECT pg_last_wal_replay_lsn();" | tr -d ' ')
    echo "Slave replay LSN: $SLAVE_LSN"
    
    if [ "$CURRENT_LSN" = "$SLAVE_LSN" ]; then
        echo "✅ Data is fully synchronized"
    else
        echo "⚠️  Data may not be fully synchronized, waiting..."
        sleep 3
    fi
}

# Step 3: Stop both servers
stop_both_servers() {
    echo ""
    echo "Stopping both servers..."
    docker stop postgres_slave postgres_master
    echo "✅ Both servers stopped"
}

# Step 4: Reconfigure postgres_master as master
reconfigure_master() {
    echo ""
    echo "Reconfiguring postgres_master as master..."
    
    # Remove standby.signal to make it a master
    docker run --rm \
        -v postgres-master-slave_postgres_master_data:/var/lib/postgresql/data \
        postgres:latest bash -c "
            rm -f /var/lib/postgresql/data/standby.signal
            # Remove slave configuration
            sed -i '/primary_conninfo/d' /var/lib/postgresql/data/postgresql.conf
            sed -i '/primary_slot_name/d' /var/lib/postgresql/data/postgresql.conf
        "
    
    echo "✅ postgres_master reconfigured as master"
}

# Step 5: Start postgres_master
start_master() {
    echo ""
    echo "Starting postgres_master..."
    docker start postgres_master
    
    # Wait for it to be ready
    until docker exec postgres_master pg_isready -U postgres; do
        echo "Waiting for master to start..."
        sleep 1
    done
    
    # Verify it's not in recovery
    IS_IN_RECOVERY=$(docker exec postgres_master psql -U postgres -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
    
    if [ "$IS_IN_RECOVERY" = "f" ]; then
        echo "✅ postgres_master is now master"
    else
        echo "❌ Failed to promote postgres_master"
        exit 1
    fi
    
    # Create replication slot for slave
    docker exec postgres_master psql -U postgres -c "SELECT pg_create_physical_replication_slot('slave_slot');" || true
}

# Step 6: Reconfigure postgres_slave as slave
reconfigure_slave() {
    echo ""
    echo "Reconfiguring postgres_slave as slave..."
    
    # Clean and setup as slave
    docker run --rm \
        --network postgres-master-slave_test_network \
        -v postgres-master-slave_postgres_slave_data:/var/lib/postgresql/data \
        postgres:latest bash -c "
            rm -rf /var/lib/postgresql/data/*
            PGPASSWORD=replicator_password pg_basebackup -h postgres_master -D /var/lib/postgresql/data -U replicator -v -P
            touch /var/lib/postgresql/data/standby.signal
            echo 'primary_conninfo = '\''host=postgres_master port=5432 user=replicator password=replicator_password application_name=slave_node'\''' >> /var/lib/postgresql/data/postgresql.conf
            echo 'primary_slot_name = '\''slave_slot'\''' >> /var/lib/postgresql/data/postgresql.conf
            chown -R postgres:postgres /var/lib/postgresql/data
        "
    
    echo "✅ postgres_slave reconfigured as slave"
}

# Step 7: Start postgres_slave
start_slave() {
    echo ""
    echo "Starting postgres_slave..."
    docker start postgres_slave
    
    # Wait for it to be ready
    until docker exec postgres_slave pg_isready -U postgres; do
        echo "Waiting for slave to start..."
        sleep 1
    done
    
    # Verify it's in recovery
    IS_IN_RECOVERY=$(docker exec postgres_slave psql -U postgres -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
    
    if [ "$IS_IN_RECOVERY" = "t" ]; then
        echo "✅ postgres_slave is now slave"
    else
        echo "❌ Failed to configure postgres_slave as slave"
        exit 1
    fi
}

# Step 8: Verify final configuration
verify_configuration() {
    echo ""
    echo "Verifying final configuration..."
    
    # Test write on master
    docker exec postgres_master psql -U postgres -c "
        INSERT INTO users (username, email) 
        VALUES ('switchback_test', 'switchback@test.com') 
        RETURNING id, username;
    "
    
    sleep 2
    
    # Check replication
    REPLICATED=$(docker exec postgres_slave psql -U postgres -t -c "
        SELECT COUNT(*) FROM users WHERE username = 'switchback_test';
    " | tr -d ' ')
    
    if [ "$REPLICATED" = "1" ]; then
        echo "✅ Replication working correctly"
    else
        echo "❌ Replication not working"
    fi
}

# Show final status
show_final_status() {
    echo ""
    echo "Switchback Complete!"
    echo "==================="
    echo "Original configuration restored:"
    echo "  - Master: postgres_master (port 15432) - Read/Write"
    echo "  - Slave: postgres_slave (port 15433) - Read-Only"
    echo ""
    
    ./health-check.sh
}

# Main execution
main() {
    check_prerequisites
    maintenance_notice
    ensure_sync
    stop_both_servers
    reconfigure_master
    start_master
    reconfigure_slave
    start_slave
    verify_configuration
    show_final_status
    
    echo ""
    echo "✅ Successfully switched back to original configuration!"
}

# Run the switchback
main