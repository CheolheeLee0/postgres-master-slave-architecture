#!/bin/bash

# Restore old master as a new slave
# This script converts the old master to a slave of the current master

set -e

echo "PostgreSQL Master Restore as Slave Script"
echo "========================================"
echo ""
echo "This script will restore the old master as a slave to the current master"
echo ""

# Check current status
check_current_status() {
    echo "Checking current status..."
    
    # Check if old master is already running
    if docker ps | grep -q postgres_master; then
        echo "❌ Old master is already running!"
        echo "Please stop it first: docker stop postgres_master"
        exit 1
    fi
    
    # Check if current master (former slave) is running
    if ! docker exec postgres_slave pg_isready -U postgres >/dev/null 2>&1; then
        echo "❌ Current master (postgres_slave) is not running!"
        exit 1
    fi
    
    # Check if current master is actually a master (not in recovery)
    IS_IN_RECOVERY=$(docker exec postgres_slave psql -U postgres -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
    
    if [ "$IS_IN_RECOVERY" = "t" ]; then
        echo "❌ postgres_slave is still in recovery mode! Run failover first."
        exit 1
    fi
    
    echo "✅ Current master (postgres_slave) is running and accepting writes"
}

# Prepare new master for replication
prepare_new_master() {
    echo ""
    echo "Preparing current master for replication..."
    
    # Create replication slot for the new slave
    echo "Creating replication slot for new slave..."
    docker exec postgres_slave psql -U postgres -c "SELECT pg_create_physical_replication_slot('master_as_slave_slot');" || echo "Slot already exists"
    
    # Ensure replication user exists
    docker exec postgres_slave psql -U postgres -c "CREATE USER IF NOT EXISTS replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicator_password';"
    
    # Update pg_hba.conf to allow replication from old master
    docker exec postgres_slave bash -c "
        grep -q 'host replication replicator postgres_master' /var/lib/postgresql/data/pg_hba.conf || \
        echo 'host replication replicator postgres_master md5' >> /var/lib/postgresql/data/pg_hba.conf
    "
    
    # Reload configuration
    docker exec postgres_slave psql -U postgres -c "SELECT pg_reload_conf();"
    
    echo "✅ Current master prepared for replication"
}

# Convert old master to slave
convert_master_to_slave() {
    echo ""
    echo "Converting old master to slave..."
    
    # Clean old master data directory
    echo "Cleaning old master data directory..."
    docker run --rm \
        -v postgres-master-slave_postgres_master_data:/var/lib/postgresql/data \
        postgres:latest bash -c "rm -rf /var/lib/postgresql/data/*"
    
    # Take base backup from current master
    echo "Taking base backup from current master..."
    docker run --rm \
        --network postgres-master-slave_test_network \
        -v postgres-master-slave_postgres_master_data:/var/lib/postgresql/data \
        postgres:latest bash -c "
            PGPASSWORD=replicator_password pg_basebackup -h postgres_slave -D /var/lib/postgresql/data -U replicator -v -P
            touch /var/lib/postgresql/data/standby.signal
            echo 'primary_conninfo = '\''host=postgres_slave port=5432 user=replicator password=replicator_password application_name=master_as_slave'\''' >> /var/lib/postgresql/data/postgresql.conf
            echo 'primary_slot_name = '\''master_as_slave_slot'\''' >> /var/lib/postgresql/data/postgresql.conf
            echo 'hot_standby = on' >> /var/lib/postgresql/data/postgresql.conf
            chown -R postgres:postgres /var/lib/postgresql/data
        "
    
    echo "✅ Base backup completed"
}

# Start old master as slave
start_as_slave() {
    echo ""
    echo "Starting old master as slave..."
    
    # Start the container
    docker start postgres_master
    
    # Wait for it to be ready
    echo "Waiting for new slave to be ready..."
    sleep 3
    
    until docker exec postgres_master pg_isready -U postgres; do
        echo "Waiting for slave to start..."
        sleep 1
    done
    
    # Verify it's in recovery mode
    IS_IN_RECOVERY=$(docker exec postgres_master psql -U postgres -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
    
    if [ "$IS_IN_RECOVERY" = "t" ]; then
        echo "✅ Old master successfully converted to slave!"
    else
        echo "❌ Failed to convert to slave mode"
        exit 1
    fi
}

# Verify replication
verify_replication() {
    echo ""
    echo "Verifying replication..."
    
    # Check replication status on current master
    echo "Replication status on current master:"
    docker exec postgres_slave psql -U postgres -c "
        SELECT application_name, client_addr, state, sync_state 
        FROM pg_stat_replication 
        WHERE application_name = 'master_as_slave';
    "
    
    # Test replication by inserting data
    echo ""
    echo "Testing replication with new data..."
    docker exec postgres_slave psql -U postgres -c "
        INSERT INTO users (username, email) 
        VALUES ('replication_test', 'test@replication.com') 
        RETURNING id, username;
    "
    
    sleep 2
    
    # Check if data replicated
    REPLICATED=$(docker exec postgres_master psql -U postgres -t -c "
        SELECT COUNT(*) FROM users WHERE username = 'replication_test';
    " | tr -d ' ')
    
    if [ "$REPLICATED" = "1" ]; then
        echo "✅ Data successfully replicated to new slave!"
    else
        echo "❌ Replication not working properly"
    fi
}

# Show final status
show_status() {
    echo ""
    echo "Final Configuration:"
    echo "==================="
    echo "Current Master: postgres_slave (port 15433) - Read/Write"
    echo "New Slave: postgres_master (port 15432) - Read-Only"
    echo ""
    
    ./health-check.sh
}

# Main execution
main() {
    echo "⚠️  WARNING: This will wipe all data from the old master!"
    read -p "Are you sure you want to continue? (y/n): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    check_current_status
    prepare_new_master
    convert_master_to_slave
    start_as_slave
    verify_replication
    show_status
    
    echo ""
    echo "✅ Old master successfully restored as slave!"
    echo ""
    echo "Current architecture:"
    echo "  - Master: postgres_slave (port 15433) - Accepts reads and writes"
    echo "  - Slave: postgres_master (port 15432) - Read-only replica"
}

# Run the restore
main