#!/bin/bash

# PostgreSQL Master-Slave Failover Script
# Promotes slave to master when master fails

set -e

echo "PostgreSQL Failover Script"
echo "========================="

# Check if master is down
check_master_status() {
    echo "Checking master status..."
    if docker exec postgres_master pg_isready -U postgres >/dev/null 2>&1; then
        echo "Master is still running!"
        read -p "Do you want to force failover? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Failover cancelled."
            exit 0
        fi
    else
        echo "Master is down. Proceeding with failover..."
    fi
}

# Promote slave to master
promote_slave() {
    echo "Promoting slave to master..."
    
    # Check if slave is running
    if ! docker exec postgres_slave pg_isready -U postgres >/dev/null 2>&1; then
        echo "Error: Slave is not running!"
        exit 1
    fi
    
    # Check if slave is in recovery mode
    IS_IN_RECOVERY=$(docker exec postgres_slave psql -U postgres -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
    
    if [ "$IS_IN_RECOVERY" != "t" ]; then
        echo "Slave is already promoted or not in recovery mode!"
        exit 1
    fi
    
    # Promote the slave
    echo "Executing pg_promote()..."
    docker exec postgres_slave psql -U postgres -c "SELECT pg_promote();"
    
    # Wait for promotion to complete
    echo "Waiting for promotion to complete..."
    sleep 3
    
    # Verify promotion
    IS_IN_RECOVERY=$(docker exec postgres_slave psql -U postgres -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
    
    if [ "$IS_IN_RECOVERY" = "f" ]; then
        echo "✅ Slave successfully promoted to master!"
        
        # Update slave configuration to accept writes
        docker exec postgres_slave bash -c "
            echo 'host all all 0.0.0.0/0 md5' >> /var/lib/postgresql/data/pg_hba.conf
            echo 'host replication replicator 0.0.0.0/0 md5' >> /var/lib/postgresql/data/pg_hba.conf
        "
        
        # Reload configuration
        docker exec postgres_slave psql -U postgres -c "SELECT pg_reload_conf();"
        
        echo "Configuration updated for write access."
    else
        echo "❌ Failed to promote slave!"
        exit 1
    fi
}

# Stop the old master to prevent split-brain
stop_old_master() {
    echo "Stopping old master to prevent split-brain..."
    docker stop postgres_master 2>/dev/null || true
    echo "Old master stopped."
}

# Show new master status
show_status() {
    echo ""
    echo "New Master Status:"
    echo "=================="
    
    # Check recovery status
    echo -n "Is in recovery mode: "
    docker exec postgres_slave psql -U postgres -t -c "SELECT pg_is_in_recovery();"
    
    # Check if it can accept writes
    echo -n "Can accept writes: "
    docker exec postgres_slave psql -U postgres -c "CREATE TEMP TABLE test_write (id int); DROP TABLE test_write;" >/dev/null 2>&1 && echo "Yes" || echo "No"
    
    # Show connection info
    echo ""
    echo "Connection Information:"
    echo "======================"
    echo "Host: localhost"
    echo "Port: 15433"
    echo "Database: postgres"
    echo "User: postgres"
    echo "Password: postgres"
    
    echo ""
    echo "✅ Failover completed successfully!"
    echo ""
    echo "You can now connect to the new master at port 15433"
    echo "Example: psql -h localhost -p 15433 -U postgres -d postgres"
}

# Main execution
main() {
    check_master_status
    promote_slave
    stop_old_master
    show_status
}

# Run the failover
main