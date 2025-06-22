# PostgreSQL Master-Slave Replication Test

This project demonstrates PostgreSQL Master-Slave (primary-standby) replication using Docker Compose with PostgreSQL 17.

## Architecture

- **postgres_master**: Primary PostgreSQL instance (port 15432)
- **postgres_slave**: Standby PostgreSQL instance (port 15433)
- Physical streaming replication from master to slave
- Hot standby enabled for read operations on slave

## Quick Start

1. Start the containers and setup replication:
```bash
./setup-master-slave.sh
```

2. Monitor the setup process:
```bash
docker-compose logs -f
```

3. Run the replication test:
```bash
python test_master_slave.py
```

## Manual Testing

Connect to Master (Read/Write):
```bash
PGPASSWORD=postgres psql -h localhost -p 15432 -U postgres -d postgres
```

Connect to Slave (Read-only):
```bash
PGPASSWORD=postgres psql -h localhost -p 15433 -U postgres -d postgres
```

## Test Operations

### Insert data on Master:
```sql
INSERT INTO users (username, email) VALUES ('test_user', 'test@example.com');
SELECT * FROM users;
```

### Verify replication on Slave:
```sql
SELECT * FROM users;
```

### Check replication lag:
```sql
-- On Master
SELECT client_addr, state, sync_state FROM pg_stat_replication;

-- On Slave  
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
```

## Monitoring Replication

Check replication status:
```sql
-- On Master
SELECT * FROM pg_replication_slots;
SELECT * FROM pg_stat_replication;

-- On Slave
SELECT pg_is_in_recovery();
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
```

## Prerequisites

- Docker and Docker Compose
- Python 3.x with psycopg2-binary

Install Python dependencies:
```bash
pip install -r requirements.txt
```

## File Structure

```
test-db/
├── docker-compose.yml              # Container orchestration
├── setup-master-slave.sh           # Master-Slave setup script
├── test_master_slave.py             # Replication test script
├── requirements.txt                 # Python dependencies
├── init-scripts/
│   └── master/
│       ├── 01-init-master.sql      # Master initialization
│       └── 02-setup-master.sh      # Master configuration
└── README.md                       # This file
```

## Stopping the Environment

```bash
docker-compose down -v
```

## PostgreSQL 17 Features Used

- **Physical Replication Slots**: Ensures WAL retention for reliable replication
- **Hot Standby**: Allows read queries on the standby server
- **Streaming Replication**: Real-time data synchronization
- **WAL Management**: Optimized for PostgreSQL 17 with improved performance

## Configuration Highlights

### Master Configuration:
- `wal_level=replica`: Enables physical replication
- `max_wal_senders=10`: Supports multiple standby servers
- `max_replication_slots=10`: Physical replication slots
- `wal_keep_size=128MB`: WAL retention for standbys
- `synchronous_commit=on`: Ensures durability

### Slave Configuration:
- `hot_standby=on`: Enables read queries
- `hot_standby_feedback=on`: Prevents query conflicts
- `primary_conninfo`: Connection to master server
- `primary_slot_name`: Uses dedicated replication slot

## Notes

- Master server accepts both read and write operations
- Slave server is read-only (hot standby mode)
- Automatic failover is not configured (manual promotion required)
- Data is replicated from master to slave in real-time
- This setup provides high availability for read operations# postgres-master-slave-architecture
