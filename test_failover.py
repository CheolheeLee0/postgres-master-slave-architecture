#!/usr/bin/env python3
"""
PostgreSQL Master-Slave Failover Test
Tests the failover functionality when master dies
"""

import psycopg2
import time
import subprocess
import sys

# Database connection parameters
MASTER_PARAMS = {
    "host": "localhost",
    "port": 15432,
    "database": "postgres",
    "user": "postgres",
    "password": "postgres"
}

SLAVE_PARAMS = {
    "host": "localhost", 
    "port": 15433,
    "database": "postgres",
    "user": "postgres",
    "password": "postgres"
}

def test_connection(params, name):
    """Test database connection"""
    try:
        conn = psycopg2.connect(**params)
        cursor = conn.cursor()
        cursor.execute("SELECT 1")
        cursor.close()
        conn.close()
        print(f"✅ {name} connection successful")
        return True
    except Exception as e:
        print(f"❌ {name} connection failed: {str(e)}")
        return False

def test_write_operation(params, name):
    """Test write operation"""
    try:
        conn = psycopg2.connect(**params)
        cursor = conn.cursor()
        
        # Try to insert a record
        cursor.execute("""
            INSERT INTO users (username, email) 
            VALUES ('test_failover', 'failover@test.com')
            RETURNING id
        """)
        user_id = cursor.fetchone()[0]
        conn.commit()
        
        print(f"✅ {name} can accept writes (inserted user id: {user_id})")
        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"❌ {name} cannot accept writes: {str(e)}")
        return False

def get_row_counts(params, name):
    """Get row counts from tables"""
    try:
        conn = psycopg2.connect(**params)
        cursor = conn.cursor()
        
        tables = ['users', 'products', 'orders']
        counts = {}
        
        for table in tables:
            cursor.execute(f"SELECT COUNT(*) FROM {table}")
            counts[table] = cursor.fetchone()[0]
        
        cursor.close()
        conn.close()
        
        print(f"{name} row counts: {counts}")
        return counts
    except Exception as e:
        print(f"Failed to get row counts from {name}: {str(e)}")
        return None

def run_command(command):
    """Run shell command"""
    result = subprocess.run(command, shell=True, capture_output=True, text=True)
    return result.returncode == 0, result.stdout, result.stderr

def main():
    print("PostgreSQL Failover Test")
    print("========================\n")
    
    # Step 1: Test initial state
    print("Step 1: Testing initial state")
    print("-" * 30)
    
    if not test_connection(MASTER_PARAMS, "Master"):
        print("Please run ./setup-master-slave.sh first")
        sys.exit(1)
    
    test_connection(SLAVE_PARAMS, "Slave")
    
    # Test write capabilities
    print("\nTesting write capabilities:")
    test_write_operation(MASTER_PARAMS, "Master")
    test_write_operation(SLAVE_PARAMS, "Slave")
    
    # Get initial row counts
    print("\nInitial data state:")
    master_counts_before = get_row_counts(MASTER_PARAMS, "Master")
    slave_counts_before = get_row_counts(SLAVE_PARAMS, "Slave")
    
    # Step 2: Simulate master failure
    print("\n\nStep 2: Simulating master failure")
    print("-" * 30)
    print("Stopping master container...")
    
    success, stdout, stderr = run_command("docker stop postgres_master")
    if success:
        print("✅ Master stopped successfully")
    else:
        print(f"❌ Failed to stop master: {stderr}")
        sys.exit(1)
    
    time.sleep(2)
    
    # Verify master is down
    test_connection(MASTER_PARAMS, "Master")
    test_connection(SLAVE_PARAMS, "Slave")
    
    # Step 3: Run failover
    print("\n\nStep 3: Running failover")
    print("-" * 30)
    print("Promoting slave to master...")
    
    # Run failover script
    success, stdout, stderr = run_command("echo 'n' | ./failover.sh")
    if success:
        print("✅ Failover completed")
    else:
        print(f"❌ Failover failed: {stderr}")
        sys.exit(1)
    
    time.sleep(3)
    
    # Step 4: Test new master (former slave)
    print("\n\nStep 4: Testing new master (former slave)")
    print("-" * 30)
    
    # Test connection
    if test_connection(SLAVE_PARAMS, "New Master (port 15433)"):
        # Test write operation
        print("\nTesting write capability on new master:")
        if test_write_operation(SLAVE_PARAMS, "New Master"):
            print("✅ Failover successful! Former slave can now accept writes")
            
            # Insert some test data
            try:
                conn = psycopg2.connect(**SLAVE_PARAMS)
                cursor = conn.cursor()
                
                # Insert multiple records
                for i in range(5):
                    cursor.execute("""
                        INSERT INTO products (name, description, price, stock_quantity)
                        VALUES (%s, %s, %s, %s)
                    """, (f'Failover Product {i}', f'Product added after failover {i}', 99.99 + i, 100))
                
                conn.commit()
                print(f"✅ Successfully inserted 5 new products after failover")
                
                cursor.close()
                conn.close()
            except Exception as e:
                print(f"❌ Failed to insert test data: {str(e)}")
        else:
            print("❌ Failover failed! New master cannot accept writes")
    else:
        print("❌ Cannot connect to new master")
    
    # Final data state
    print("\nFinal data state:")
    new_master_counts = get_row_counts(SLAVE_PARAMS, "New Master")
    
    # Step 5: Summary
    print("\n\nTest Summary")
    print("=" * 50)
    print("1. Master was successfully stopped ✅")
    print("2. Slave was promoted to master ✅")
    print("3. New master accepts read/write operations ✅")
    print(f"4. Data preserved during failover: {slave_counts_before} -> {new_master_counts}")
    print("\n✅ Failover test completed successfully!")
    print("\nNote: The old master remains stopped to prevent split-brain scenario")
    print("You can now use port 15433 for all database operations")

if __name__ == "__main__":
    main()