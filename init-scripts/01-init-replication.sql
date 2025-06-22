-- Create replication user
DO
$$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = 'replicator') THEN
        CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicator123';
    END IF;
END
$$;

-- Grant necessary permissions
GRANT CONNECT ON DATABASE testdb TO replicator;
GRANT USAGE ON SCHEMA public TO replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO replicator;

-- Create publication for logical replication
DROP PUBLICATION IF EXISTS active_active_pub;
CREATE PUBLICATION active_active_pub FOR ALL TABLES;

-- Create test table
CREATE TABLE IF NOT EXISTS test_data (
    id SERIAL PRIMARY KEY,
    node_name VARCHAR(50),
    data VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create function to update timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create trigger for updated_at
DROP TRIGGER IF EXISTS update_test_data_updated_at ON test_data;
CREATE TRIGGER update_test_data_updated_at 
BEFORE UPDATE ON test_data 
FOR EACH ROW 
EXECUTE FUNCTION update_updated_at_column();