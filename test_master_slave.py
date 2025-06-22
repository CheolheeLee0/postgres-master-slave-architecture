#!/usr/bin/env python3
"""
PostgreSQL 17 Master-Slave 복제 테스트 스크립트

이 스크립트는 PostgreSQL 17의 물리 스트리밍 복제를 테스트합니다.

테스트 항목:
1. 기본 데이터 삽입 및 복제 확인
2. 데이터 업데이트 및 복제 확인  
3. Slave 읽기 전용 확인
4. 데이터 동기화 상태 확인
5. 대량 데이터 복제 테스트
6. 복제 성능 및 지연 시간 측정
7. 복제 상태 모니터링 (슬롯, WAL 등)

요구사항:
- psycopg2-binary
- Master (port 15432), Slave (port 15433) 실행 중
- 복제 설정 완료 상태

사용법:
python test_master_slave.py
"""

import psycopg2
import time
import sys
from datetime import datetime

# 데이터베이스 연결 설정
MASTER_CONFIG = {
    'host': 'localhost',
    'port': 15432,
    'database': 'postgres',
    'user': 'postgres',
    'password': 'postgres'
}

SLAVE_CONFIG = {
    'host': 'localhost',
    'port': 15433,
    'database': 'postgres',
    'user': 'postgres',
    'password': 'postgres'
}

def connect_to_db(config, db_name=None):
    """데이터베이스 연결"""
    if db_name is None:
        db_name = "Master" if config == MASTER_CONFIG else "Slave"
    try:
        conn = psycopg2.connect(**config)
        conn.autocommit = True
        return conn
    except Exception as e:
        print(f"{db_name} 데이터베이스 연결 실패: {e}")
        return None

def test_master_slave_replication():
    """Master-Slave 복제 테스트 실행"""
    print("=" * 60)
    print("PostgreSQL Master-Slave 복제 테스트 시작")
    print("=" * 60)
    
    # 데이터베이스 연결
    master_conn = connect_to_db(MASTER_CONFIG, "Master")
    slave_conn = connect_to_db(SLAVE_CONFIG, "Slave")
    
    if not master_conn or not slave_conn:
        print("데이터베이스 연결에 실패했습니다.")
        return False
    
    try:
        master_cur = master_conn.cursor()
        slave_cur = slave_conn.cursor()
        
        # 테스트 시작 시간
        test_time = datetime.now().strftime("%Y%m%d_%H%M%S")
        
        print(f"\n1. Master에서 사용자 데이터 삽입 (테스트 시간: {test_time})")
        user_data = f"test_user_{test_time}"
        email = f"test_{test_time}@test.com"
        
        master_cur.execute(
            "INSERT INTO users (username, email) VALUES (%s, %s) RETURNING id",
            (user_data, email)
        )
        user_id = master_cur.fetchone()[0]
        print(f"   Master에 사용자 삽입 완료: ID={user_id}, username={user_data}")
        
        # 복제 대기
        print("   복제 대기 중... (1초)")
        time.sleep(1)
        
        # Slave에서 데이터 확인
        print("   Slave에서 복제된 데이터 확인:")
        slave_cur.execute("SELECT id, username, email FROM users WHERE username = %s", (user_data,))
        result = slave_cur.fetchone()
        
        if result:
            print(f"   ✓ 복제 성공! Slave에서 발견: ID={result[0]}, username={result[1]}, email={result[2]}")
        else:
            print("   ✗ 복제 실패! Slave에서 데이터를 찾을 수 없습니다.")
            return False
        
        print(f"\n2. Master에서 제품 데이터 삽입")
        product_name = f"Test_Product_{test_time}"
        master_cur.execute(
            "INSERT INTO products (name, description, price, stock_quantity) VALUES (%s, %s, %s, %s) RETURNING id",
            (product_name, f"Test product created at {test_time}", 199.99, 15)
        )
        product_id = master_cur.fetchone()[0]
        print(f"   Master에 제품 삽입: ID={product_id}, name={product_name}")
        
        time.sleep(1)
        
        # Slave에서 제품 확인
        slave_cur.execute("SELECT id, name, price FROM products WHERE name = %s", (product_name,))
        result = slave_cur.fetchone()
        
        if result:
            print(f"   ✓ 제품 복제 성공! Slave에서 발견: ID={result[0]}, name={result[1]}, price={result[2]}")
        else:
            print("   ✗ 제품 복제 실패!")
            return False
        
        print(f"\n3. Master에서 데이터 업데이트 테스트")
        new_price = 299.99
        master_cur.execute(
            "UPDATE products SET price = %s WHERE id = %s",
            (new_price, product_id)
        )
        print(f"   Master에서 제품 가격 업데이트: {new_price}")
        
        time.sleep(1)
        
        # Slave에서 업데이트된 정보 확인
        slave_cur.execute("SELECT price FROM products WHERE id = %s", (product_id,))
        result = slave_cur.fetchone()
        
        if result and float(result[0]) == float(new_price):
            print(f"   ✓ 업데이트 복제 성공! Slave에서 확인된 가격: {result[0]}")
        else:
            current_price = result[0] if result else "결과 없음"
            print(f"   ✗ 업데이트 복제 실패! 예상: {new_price}, 실제: {current_price}")
            return False
        
        print(f"\n4. Slave에서 읽기 전용 확인")
        try:
            slave_cur.execute(
                "INSERT INTO users (username, email) VALUES (%s, %s)",
                (f"slave_test_{test_time}", f"slave_{test_time}@test.com")
            )
            print("   ✗ Slave에서 쓰기가 가능합니다! (예상하지 못한 동작)")
            return False
        except psycopg2.Error as e:
            if "read-only" in str(e) or "cannot execute" in str(e):
                print("   ✓ Slave는 올바르게 읽기 전용으로 설정되어 있습니다.")
            else:
                print(f"   ✗ 예상하지 못한 오류: {e}")
                return False
        
        print(f"\n5. 데이터 동기화 확인")
        # 양쪽 DB의 총 레코드 수 확인
        master_cur.execute("SELECT COUNT(*) FROM users")
        master_users_count = master_cur.fetchone()[0]
        
        slave_cur.execute("SELECT COUNT(*) FROM users")
        slave_users_count = slave_cur.fetchone()[0]
        
        master_cur.execute("SELECT COUNT(*) FROM products")
        master_products_count = master_cur.fetchone()[0]
        
        slave_cur.execute("SELECT COUNT(*) FROM products")
        slave_products_count = slave_cur.fetchone()[0]
        
        print(f"   Master - Users: {master_users_count}, Products: {master_products_count}")
        print(f"   Slave - Users: {slave_users_count}, Products: {slave_products_count}")
        
        if master_users_count == slave_users_count and master_products_count == slave_products_count:
            print("   ✓ 전체 데이터 동기화 성공!")
        else:
            print("   ✗ 데이터 동기화 실패!")
            return False
        
        print(f"\n6. 대량 데이터 복제 테스트")
        # 대량 데이터 삽입 테스트
        batch_size = 100
        print(f"   Master에 {batch_size}개의 사용자 일괄 삽입 중...")
        
        batch_data = []
        for i in range(batch_size):
            batch_data.append((f"batch_user_{test_time}_{i}", f"batch_{i}_{test_time}@test.com"))
        
        master_cur.executemany(
            "INSERT INTO users (username, email) VALUES (%s, %s)",
            batch_data
        )
        
        time.sleep(1)  # 복제 대기
        
        # Slave에서 일괄 삽입된 데이터 확인
        slave_cur.execute("SELECT COUNT(*) FROM users WHERE username LIKE %s", (f"batch_user_{test_time}_%",))
        batch_count = slave_cur.fetchone()[0]
        
        if batch_count == batch_size:
            print(f"   ✓ 대량 데이터 복제 성공! {batch_count}/{batch_size}개 복제됨")
        else:
            print(f"   ✗ 대량 데이터 복제 실패! {batch_count}/{batch_size}개만 복제됨")
            return False
        
        print(f"\n7. 복제 성능 측정")
        # 복제 지연 시간 측정
        start_time = datetime.now()
        
        # Master에 타임스탬프와 함께 데이터 삽입
        timestamp_user = f"perf_test_{test_time}"
        master_cur.execute(
            "INSERT INTO users (username, email, created_at) VALUES (%s, %s, %s) RETURNING created_at",
            (timestamp_user, f"perf_{test_time}@test.com", start_time)
        )
        result = master_cur.fetchone()
        master_timestamp = result[0] if result else None
        
        # Slave에서 데이터가 나타날 때까지 대기
        max_wait = 10  # 최대 10초 대기
        replicated = False
        
        for _ in range(max_wait):
            slave_cur.execute("SELECT created_at FROM users WHERE username = %s", (timestamp_user,))
            result = slave_cur.fetchone()
            if result:
                end_time = datetime.now()
                replication_delay = (end_time - start_time).total_seconds()
                print(f"   ✓ 복제 지연 시간: {replication_delay:.2f}초")
                replicated = True
                break
            time.sleep(1)
        
        if not replicated:
            print(f"   ✗ 복제 성능 테스트 실패! {max_wait}초 내에 복제되지 않음")
            return False
        
        print("\n" + "=" * 60)
        print("🎉 모든 Master-Slave 복제 테스트가 성공적으로 완료되었습니다!")
        print("=" * 60)
        return True
        
    except Exception as e:
        print(f"테스트 중 오류 발생: {e}")
        return False
    
    finally:
        if master_conn:
            master_conn.close()
        if slave_conn:
            slave_conn.close()

def check_replication_status():
    """복제 상태 확인"""
    print("\n복제 상태 확인:")
    print("-" * 30)
    
    master_conn = connect_to_db(MASTER_CONFIG, "Master")
    slave_conn = connect_to_db(SLAVE_CONFIG, "Slave")
    
    if master_conn:
        try:
            master_cur = master_conn.cursor()
            
            # 복제 상태 확인
            master_cur.execute("SELECT client_addr, application_name, state, sync_state FROM pg_stat_replication;")
            results = master_cur.fetchall()
            print("Master 복제 상태:")
            if results:
                for row in results:
                    print(f"  - Client: {row[0]}, App: {row[1]}, State: {row[2]}, Sync: {row[3]}")
            else:
                print("  - 연결된 복제 클라이언트가 없습니다.")
            
            # 복제 슬롯 상태 확인 (PostgreSQL 17)
            master_cur.execute("SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;")
            slots = master_cur.fetchall()
            print("Master 복제 슬롯 상태:")
            if slots:
                for slot in slots:
                    active_status = "활성" if slot[2] else "비활성"
                    print(f"  - Slot: {slot[0]}, Type: {slot[1]}, Status: {active_status}, LSN: {slot[3]}")
            else:
                print("  - 복제 슬롯이 없습니다.")
                
        except Exception as e:
            print(f"Master 상태 확인 실패: {e}")
        finally:
            master_conn.close()
    
    if slave_conn:
        try:
            slave_cur = slave_conn.cursor()
            
            # 복구 모드 확인
            slave_cur.execute("SELECT pg_is_in_recovery();")
            is_recovery = slave_cur.fetchone()[0]
            print(f"Slave 복구 모드: {'Yes (정상)' if is_recovery else 'No (문제 있음)'}")
            
            if is_recovery:
                # WAL 상태 확인
                slave_cur.execute("SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();")
                result = slave_cur.fetchone()
                print(f"Slave WAL 상태: Received={result[0]}, Replayed={result[1]}")
                
                # 복제 지연 확인 (PostgreSQL 17)
                slave_cur.execute("SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int;")
                lag_result = slave_cur.fetchone()
                if lag_result[0] is not None:
                    print(f"복제 지연: {lag_result[0]}초")
                else:
                    print("복제 지연: 측정 불가 (트랜잭션 없음)")
            
        except Exception as e:
            print(f"Slave 상태 확인 실패: {e}")
        finally:
            slave_conn.close()

if __name__ == "__main__":
    # 복제 상태 먼저 확인
    check_replication_status()
    
    # 테스트 실행
    success = test_master_slave_replication()
    
    sys.exit(0 if success else 1)