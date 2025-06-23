#!/bin/bash

# PostgreSQL Master-Slave Health Check Script
# Monitors the health of master and slave servers

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "PostgreSQL Master-Slave Health Check"
echo "===================================="
echo ""

# Check Master Health
check_master() {
    echo "🔍 Checking Master Server (port 15432)..."
    echo "----------------------------------------"
    
    if docker exec postgres_master pg_isready -U postgres >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Master is UP${NC}"
        
        # Check if master can accept connections
        if docker exec postgres_master psql -U postgres -c "SELECT 1;" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Master can accept connections${NC}"
            
            # Check replication status
            REPLICATION_STATUS=$(docker exec postgres_master psql -U postgres -t -c "
                SELECT COUNT(*) FROM pg_stat_replication;
            " | tr -d ' ')
            
            if [ "$REPLICATION_STATUS" -gt 0 ]; then
                echo -e "${GREEN}✅ Active replication connections: $REPLICATION_STATUS${NC}"
                
                # Show replication details
                echo ""
                echo "Replication Details:"
                docker exec postgres_master psql -U postgres -c "
                    SELECT 
                        application_name,
                        client_addr,
                        state,
                        sync_state,
                        pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)) as lag
                    FROM pg_stat_replication;
                "
            else
                echo -e "${YELLOW}⚠️  No active replication connections${NC}"
            fi
        else
            echo -e "${RED}❌ Master cannot accept connections${NC}"
        fi
    else
        echo -e "${RED}❌ Master is DOWN${NC}"
        return 1
    fi
}

# Check Slave Health
check_slave() {
    echo ""
    echo "🔍 Checking Slave Server (port 15433)..."
    echo "----------------------------------------"
    
    if docker exec postgres_slave pg_isready -U postgres >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Slave is UP${NC}"
        
        # Check if slave is in recovery mode
        IS_IN_RECOVERY=$(docker exec postgres_slave psql -U postgres -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
        
        if [ "$IS_IN_RECOVERY" = "t" ]; then
            echo -e "${GREEN}✅ Slave is in recovery mode (read-only)${NC}"
            
            # Check replication lag
            LAG_INFO=$(docker exec postgres_slave psql -U postgres -t -c "
                SELECT 
                    CASE 
                        WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() 
                        THEN 'No lag'
                        ELSE pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()))
                    END as lag;
            " | tr -d ' ')
            
            echo -e "${GREEN}✅ Replication lag: $LAG_INFO${NC}"
            
            # Show WAL receiver status
            echo ""
            echo "WAL Receiver Status:"
            docker exec postgres_slave psql -U postgres -c "
                SELECT 
                    status,
                    receive_start_lsn,
                    received_lsn,
                    latest_end_lsn
                FROM pg_stat_wal_receiver
                WHERE pid IS NOT NULL;
            " 2>/dev/null || echo "No active WAL receiver"
            
        elif [ "$IS_IN_RECOVERY" = "f" ]; then
            echo -e "${YELLOW}⚠️  Slave has been promoted to master (read-write)${NC}"
        else
            echo -e "${RED}❌ Unable to determine slave recovery status${NC}"
        fi
    else
        echo -e "${RED}❌ Slave is DOWN${NC}"
        return 1
    fi
}

# Check Data Sync
check_data_sync() {
    echo ""
    echo "🔍 Checking Data Synchronization..."
    echo "-----------------------------------"
    
    # Only check if both are running
    if docker exec postgres_master pg_isready -U postgres >/dev/null 2>&1 && \
       docker exec postgres_slave pg_isready -U postgres >/dev/null 2>&1; then
        
        # Get row counts from master
        MASTER_USERS=$(docker exec postgres_master psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM users;" | tr -d ' ')
        MASTER_PRODUCTS=$(docker exec postgres_master psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM products;" | tr -d ' ')
        MASTER_ORDERS=$(docker exec postgres_master psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM orders;" | tr -d ' ')
        
        # Get row counts from slave
        SLAVE_USERS=$(docker exec postgres_slave psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM users;" | tr -d ' ')
        SLAVE_PRODUCTS=$(docker exec postgres_slave psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM products;" | tr -d ' ')
        SLAVE_ORDERS=$(docker exec postgres_slave psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM orders;" | tr -d ' ')
        
        # Compare counts
        echo "Table Row Counts:"
        echo "  Users:    Master: $MASTER_USERS, Slave: $SLAVE_USERS $([ "$MASTER_USERS" = "$SLAVE_USERS" ] && echo -e "${GREEN}✅${NC}" || echo -e "${RED}❌${NC}")"
        echo "  Products: Master: $MASTER_PRODUCTS, Slave: $SLAVE_PRODUCTS $([ "$MASTER_PRODUCTS" = "$SLAVE_PRODUCTS" ] && echo -e "${GREEN}✅${NC}" || echo -e "${RED}❌${NC}")"
        echo "  Orders:   Master: $MASTER_ORDERS, Slave: $SLAVE_ORDERS $([ "$MASTER_ORDERS" = "$SLAVE_ORDERS" ] && echo -e "${GREEN}✅${NC}" || echo -e "${RED}❌${NC}")"
        
        if [ "$MASTER_USERS" = "$SLAVE_USERS" ] && [ "$MASTER_PRODUCTS" = "$SLAVE_PRODUCTS" ] && [ "$MASTER_ORDERS" = "$SLAVE_ORDERS" ]; then
            echo -e "${GREEN}✅ Data is synchronized${NC}"
        else
            echo -e "${YELLOW}⚠️  Data is not fully synchronized${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  Cannot check sync - one or both servers are down${NC}"
    fi
}

# Summary
show_summary() {
    echo ""
    echo "===================================="
    echo "Summary"
    echo "===================================="
    
    MASTER_STATUS="DOWN"
    SLAVE_STATUS="DOWN"
    
    docker exec postgres_master pg_isready -U postgres >/dev/null 2>&1 && MASTER_STATUS="UP"
    docker exec postgres_slave pg_isready -U postgres >/dev/null 2>&1 && SLAVE_STATUS="UP"
    
    echo "Master: $MASTER_STATUS (port 15432)"
    echo "Slave:  $SLAVE_STATUS (port 15433)"
    
    if [ "$MASTER_STATUS" = "DOWN" ] && [ "$SLAVE_STATUS" = "UP" ]; then
        echo ""
        echo -e "${YELLOW}⚠️  Master is down! Consider running ./failover.sh to promote slave${NC}"
    elif [ "$MASTER_STATUS" = "DOWN" ] && [ "$SLAVE_STATUS" = "DOWN" ]; then
        echo ""
        echo -e "${RED}❌ Both servers are down! Run ./setup-master-slave.sh to restore${NC}"
    fi
}

# Main execution
main() {
    check_master || true
    check_slave || true
    check_data_sync || true
    show_summary
}

# Run health check
main