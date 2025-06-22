# PostgreSQL Active-Active Replication Test

This project demonstrates PostgreSQL Active-Active (bidirectional) replication using Docker Compose with PostgreSQL 17.

## Architecture

- **postgres1**: Primary PostgreSQL instance (port 5432)
- **postgres2**: Secondary PostgreSQL instance (port 5434)
- **pgbouncer**: Connection pooler (port 6432)
- Bidirectional logical replication between both nodes

## Quick Start

1. Start the containers:
```bash
docker-compose up -d
```

2. Wait for initialization (about 30 seconds):
```bash
docker-compose logs -f
```

3. Run the test script:
```bash
./test-replication.sh
```

## Manual Testing

Connect to postgres1:
```bash
PGPASSWORD=postgres123 psql -h localhost -p 5432 -U postgres -d testdb
```

Connect to postgres2:
```bash
PGPASSWORD=postgres123 psql -h localhost -p 5434 -U postgres -d testdb
```

## Monitoring Replication

Check replication status:
```sql
-- On either node
SELECT * FROM pg_replication_slots;
SELECT * FROM pg_subscription;
SELECT * FROM pg_stat_replication;
```

## Stopping the Environment

```bash
docker-compose down -v
```

## Configuration Files

- `docker-compose.yml`: Container orchestration
- `pg-config/postgresql*.conf`: PostgreSQL configuration
- `pg-config/pg_hba*.conf`: Authentication configuration
- `init-scripts/`: Initialization and replication setup scripts
- `pgbouncer/`: Connection pooler configuration

## Notes

- This setup uses logical replication for bidirectional sync
- Conflict resolution follows "last write wins" approach
- Both nodes can accept writes simultaneously
- PgBouncer provides connection pooling and load balancing