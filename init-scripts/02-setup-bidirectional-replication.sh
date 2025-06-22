#!/bin/bash
set -e

# Wait for PostgreSQL to be ready
sleep 10

# Function to execute SQL on a specific node
exec_sql() {
    local host=$1
    local port=$2
    local sql=$3
    PGPASSWORD=postgres123 psql -h $host -p $port -U postgres -d testdb -c "$sql"
}

# Get container IPs
POSTGRES1_IP=$(getent hosts postgres1 | awk '{ print $1 }')
POSTGRES2_IP=$(getent hosts postgres2 | awk '{ print $1 }')

echo "Setting up bidirectional replication between postgres1 ($POSTGRES1_IP) and postgres2 ($POSTGRES2_IP)"

# Setup subscription on postgres1 to replicate from postgres2
if [ "$HOSTNAME" = "postgres1" ]; then
    sleep 20  # Wait for postgres2 to be ready
    
    # Drop existing subscription if exists
    exec_sql localhost 5432 "DROP SUBSCRIPTION IF EXISTS sub_from_postgres2;"
    
    # Create subscription from postgres2
    exec_sql localhost 5432 "CREATE SUBSCRIPTION sub_from_postgres2 
        CONNECTION 'host=postgres2 port=5432 user=replicator password=replicator123 dbname=testdb' 
        PUBLICATION active_active_pub 
        WITH (copy_data = false, create_slot = true, slot_name = 'sub_from_postgres2_slot');"
    
    echo "Subscription from postgres2 created on postgres1"
fi

# Setup subscription on postgres2 to replicate from postgres1
if [ "$HOSTNAME" = "postgres2" ]; then
    sleep 5  # Short wait
    
    # Drop existing subscription if exists
    exec_sql localhost 5432 "DROP SUBSCRIPTION IF EXISTS sub_from_postgres1;"
    
    # Create subscription from postgres1
    exec_sql localhost 5432 "CREATE SUBSCRIPTION sub_from_postgres1 
        CONNECTION 'host=postgres1 port=5432 user=replicator password=replicator123 dbname=testdb' 
        PUBLICATION active_active_pub 
        WITH (copy_data = false, create_slot = true, slot_name = 'sub_from_postgres1_slot');"
    
    echo "Subscription from postgres1 created on postgres2"
fi

echo "Bidirectional replication setup completed for $HOSTNAME"