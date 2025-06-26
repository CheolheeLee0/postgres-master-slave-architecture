#!/bin/bash
# PostgreSQL Master-Slave 수동 테스트 가이드
# 운영1서버: 10.164.32.91 (Master)
# 운영2서버: 10.164.32.92 (Slave)
# 각 명령어를 순서대로 복사하여 실행하세요

# PostgreSQL Master-Slave 수동 테스트 시작
# 시작 시간: $(date)

# =============================================================================
# 1. 초기 연결 및 상태 확인
# =============================================================================

# 1. 초기 연결 및 상태 확인

# Master 서버 연결 테스트 (관리 서버에서 실행)
# Master 서버 연결 테스트 중...
psql -h 10.164.32.91 -U postgres -c "SELECT version();"
if [ $? -eq 0 ]; then
    # Master 서버 (10.164.32.91) 연결 성공
    true
else
    # Master 서버 (10.164.32.91) 연결 실패
    false
fi

# Slave 서버 연결 테스트 (관리 서버에서 실행)
# Slave 서버 연결 테스트 중...
psql -h 10.164.32.92 -U postgres -c "SELECT version();"
if [ $? -eq 0 ]; then
    # Slave 서버 (10.164.32.92) 연결 성공
    true
else
    # Slave 서버 (10.164.32.92) 연결 실패
    false
fi

# Master 상태 확인 (관리 서버에서 실행)
# Master 상태 확인 중...
MASTER_RECOVERY=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
if [ "$MASTER_RECOVERY" = "f" ]; then
    # 10.164.32.91이 Master 모드로 실행 중
    true
else
    # 10.164.32.91이 Master 모드가 아님 (Recovery: $MASTER_RECOVERY)
    false
fi

# Slave 상태 확인 (관리 서버에서 실행)
# Slave 상태 확인 중...
SLAVE_RECOVERY=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
if [ "$SLAVE_RECOVERY" = "t" ]; then
    # 10.164.32.92가 Slave(Recovery) 모드로 실행 중
    true
else
    # 10.164.32.92가 Slave 모드가 아님 (Recovery: $SLAVE_RECOVERY)
    false
fi

# =============================================================================
# 2. 복제 상태 확인
# =============================================================================

# 2. 복제 상태 확인

# Master에서 복제 슬롯 확인 (관리 서버에서 실행)
# 복제 슬롯 상태 확인 중...
psql -h 10.164.32.91 -U postgres -c "
SELECT slot_name, slot_type, active, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
FROM pg_replication_slots;"

# Master에서 WAL Sender 확인 (관리 서버에서 실행)
# WAL Sender 상태 확인 중...
psql -h 10.164.32.91 -U postgres -c "
SELECT pid, usename, application_name, client_addr, state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
FROM pg_stat_replication;"

# Slave에서 WAL Receiver 확인 (관리 서버에서 실행)
# WAL Receiver 상태 확인 중...
psql -h 10.164.32.92 -U postgres -c "
SELECT pid, status, receive_start_lsn, received_lsn,
       last_msg_send_time, last_msg_receipt_time
FROM pg_stat_wal_receiver;"

# =============================================================================
# 3. 데이터 동기화 테스트
# =============================================================================

# 3. 데이터 동기화 테스트

# 초기 레코드 수 확인 (관리 서버에서 실행)
# 초기 데이터 개수 확인 중...
MASTER_INITIAL_AUTH=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
SLAVE_INITIAL_AUTH=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')

# Master 초기 Auth 레코드 수: $MASTER_INITIAL_AUTH
# Slave 초기 Auth 레코드 수: $SLAVE_INITIAL_AUTH

if [ "$MASTER_INITIAL_AUTH" = "$SLAVE_INITIAL_AUTH" ]; then
    # 초기 데이터 동기화 확인됨
    true
else
    # 초기 데이터 동기화 불일치
    false
fi

# Master에서 테스트 데이터 삽입 (관리 서버에서 실행)
# Master에서 테스트 데이터 삽입 중...
TEST_ID=$(date +%s)
TEST_EMAIL="sync_test_$TEST_ID@example.com"

# Auth 데이터 삽입
psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('test_auth_$TEST_ID', '$TEST_EMAIL', 'hashed_password_$TEST_ID', NOW(), NOW()) 
RETURNING id;"

# User 데이터 삽입
psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"User\" (id, \"authId\", role, language, name, \"createdAt\", \"updatedAt\") 
VALUES ('test_user_$TEST_ID', 'test_auth_$TEST_ID', 'CUSTOMER', 'ko', 'Test User $TEST_ID', NOW(), NOW()) 
RETURNING id;"

# 동기화 대기
# 동기화 대기 중... (5초)
sleep 5

# Slave에서 데이터 확인 (관리 서버에서 실행)
# Slave에서 데이터 동기화 확인 중...
SLAVE_TEST_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = '$TEST_EMAIL';" 2>/dev/null | tr -d ' ')

if [ "$SLAVE_TEST_COUNT" = "1" ]; then
    # Auth 데이터가 Slave로 정상 동기화됨
    true
else
    # Auth 데이터가 Slave로 동기화되지 않음 (개수: $SLAVE_TEST_COUNT)
    false
fi

# JOIN 쿼리로 관계 데이터 확인 (관리 서버에서 실행)
# 관계 데이터 동기화 확인 중...
psql -h 10.164.32.92 -U postgres -c "
SELECT u.id as user_id, u.name, a.\"emailAddress\", u.role
FROM \"User\" u 
JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.\"emailAddress\" = '$TEST_EMAIL';"

# =============================================================================
# 4. Master 장애 시뮬레이션 테스트
# =============================================================================

# 4. Master 장애 시뮬레이션 테스트

# 장애 전 데이터 삽입 (관리 서버에서 실행)
# 장애 전 테스트 데이터 삽입 중...
FAILURE_TEST_ID=$(date +%s)
psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('pre_failure_$FAILURE_TEST_ID', 'pre_failure_$FAILURE_TEST_ID@example.com', 'hashed_password', NOW(), NOW());"

INITIAL_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
# 장애 전 Master Auth 레코드 수: $INITIAL_COUNT

echo ""
echo "🔶 다음 명령어를 운영1번 서버(10.164.32.91)에서 실행하세요:"
echo "sudo systemctl stop postgresql"
echo ""
echo "위 명령어를 실행한 후 Enter를 누르세요..."
read -r

# Master 연결 불가 확인 (관리 서버에서 실행)
# Master 연결 불가 확인 중...
if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    # Master가 여전히 응답하고 있음
    false
else
    # Master 서비스가 정상적으로 중지됨
    true
fi

# Slave 상태 확인 (관리 서버에서 실행)
# Slave 생존 확인 중...
if psql -h 10.164.32.92 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    # Master 장애 시 Slave가 정상 동작 중
    true
else
    # Master 장애 시 Slave도 응답하지 않음
    false
fi

# Slave를 Master로 승격 (관리 서버에서 실행)
# Slave를 Master로 승격 중...
psql -h 10.164.32.92 -U postgres -c "SELECT pg_promote();"

# 승격 완료 대기 중... (5초)
sleep 5

# 승격 확인 (관리 서버에서 실행)
NEW_MASTER_RECOVERY=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
if [ "$NEW_MASTER_RECOVERY" = "f" ]; then
    # Slave가 성공적으로 Master로 승격됨
    true
else
    # Slave 승격 후에도 Recovery 모드임
    false
fi

# 새 Master에서 쓰기 테스트 (관리 서버에서 실행)
# 새 Master에서 쓰기 테스트 중...
NEW_MASTER_TEST_ID=$(date +%s)
psql -h 10.164.32.92 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('post_failover_$NEW_MASTER_TEST_ID', 'post_failover_$NEW_MASTER_TEST_ID@example.com', 'hashed_password', NOW(), NOW()) 
RETURNING id;"

echo ""
echo "🔶 다음 명령어를 운영1번 서버(10.164.32.91)에서 실행하세요:"
echo "sudo systemctl start postgresql"
echo ""
echo "위 명령어를 실행한 후 Enter를 누르세요..."
read -r

# 원래 Master 복구 대기 중... (10초)
sleep 10

# 복구된 서버 상태 확인 (관리 서버에서 실행)
# 복구된 서버 상태 확인 중...
if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    RECOVERED_RECOVERY=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    if [ "$RECOVERED_RECOVERY" = "t" ]; then
        # 원래 Master가 Slave로 자동 전환됨
        true
    else
        # 원래 Master가 Master 모드로 복구됨 (Split-brain 위험)
        false
    fi
else
    # 원래 Master 서버 복구 실패
    false
fi

# =============================================================================
# 5. Slave 장애 시뮬레이션 테스트
# =============================================================================

# 5. Slave 장애 시뮬레이션 테스트

# 현재 Master/Slave 확인 (관리 서버에서 실행)
# 현재 Master/Slave 상태 확인 중...
CURRENT_92_RECOVERY=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
CURRENT_91_RECOVERY=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')

if [ "$CURRENT_92_RECOVERY" = "f" ]; then
    CURRENT_MASTER="10.164.32.92"
    CURRENT_SLAVE="10.164.32.91"
    SLAVE_SERVER="운영1번"
    # 현재 Master: 10.164.32.92 (운영2번)
    # 현재 Slave: 10.164.32.91 (운영1번)
else
    CURRENT_MASTER="10.164.32.91"
    CURRENT_SLAVE="10.164.32.92"
    SLAVE_SERVER="운영2번"
    # 현재 Master: 10.164.32.91 (운영1번)
    # 현재 Slave: 10.164.32.92 (운영2번)
fi

echo ""
echo "🔶 다음 명령어를 $SLAVE_SERVER 서버($CURRENT_SLAVE)에서 실행하세요:"
echo "sudo systemctl stop postgresql"
echo ""
echo "위 명령어를 실행한 후 Enter를 누르세요..."
read -r

# Slave 연결 불가 확인 (관리 서버에서 실행)
# Slave 연결 불가 확인 중...
if psql -h "$CURRENT_SLAVE" -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    # Slave가 여전히 응답하고 있음
    false
else
    # Slave 서비스가 정상적으로 중지됨
    true
fi

# Master 상태 확인 (관리 서버에서 실행)
# Master 생존 확인 중...
if psql -h "$CURRENT_MASTER" -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    # Slave 장애 시 Master가 정상 동작 중
    true
else
    # Slave 장애 시 Master도 응답하지 않음
    false
fi

# Master에서 계속 쓰기 작업 테스트 (관리 서버에서 실행)
# Master에서 쓰기 작업 테스트 중...
SLAVE_FAILURE_TEST_ID=$(date +%s)
for i in {1..3}; do
    WRITE_TEST_ID="${SLAVE_FAILURE_TEST_ID}_$i"
    # 쓰기 테스트 $i 실행 중...
    psql -h "$CURRENT_MASTER" -U postgres -c "
    INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
    VALUES ('during_slave_failure_$WRITE_TEST_ID', 'during_slave_failure_$WRITE_TEST_ID@example.com', 'hashed_password', NOW(), NOW());"
done
# Slave 장애 중에도 Master 쓰기 작업 정상

echo ""
echo "🔶 다음 명령어를 $SLAVE_SERVER 서버($CURRENT_SLAVE)에서 실행하세요:"
echo "sudo systemctl start postgresql"
echo ""
echo "위 명령어를 실행한 후 Enter를 누르세요..."
read -r

# Slave 복구 대기 중... (10초)
sleep 10

# Slave 복구 확인 (관리 서버에서 실행)
# Slave 복구 상태 확인 중...
if psql -h "$CURRENT_SLAVE" -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    RECOVERED_SLAVE_RECOVERY=$(psql -h "$CURRENT_SLAVE" -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    if [ "$RECOVERED_SLAVE_RECOVERY" = "t" ]; then
        # Slave가 정상적으로 복구되어 Recovery 모드로 실행 중
        true
    else
        # Slave가 Master 모드로 복구됨
        false
    fi
else
    # Slave 서버 복구 실패
    false
fi

# 복제 재연결 확인 (관리 서버에서 실행)
# 복제 재연결 확인 중... (5초 대기)
sleep 5
REPLICATION_RECONNECTED=$(psql -h "$CURRENT_MASTER" -U postgres -t -c "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')

if [ "$REPLICATION_RECONNECTED" -gt "0" ]; then
    # 복제 연결이 재설정됨
    psql -h "$CURRENT_MASTER" -U postgres -c "
    SELECT application_name, client_addr, state, 
           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
    FROM pg_stat_replication;"
else
    # 복제 연결이 재설정되지 않음
    false
fi

# =============================================================================
# 6. 성능 테스트
# =============================================================================

# 6. 성능 테스트

# 대량 데이터 삽입 성능 테스트 (관리 서버에서 실행)
# 대량 데이터 삽입 성능 테스트 중...
BULK_COUNT=1000
START_TIME=$(date +%s)

psql -h "$CURRENT_MASTER" -U postgres -c "
BEGIN;
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\")
SELECT 
    'perf_auth_' || generate_series(1, $BULK_COUNT),
    'perf_user_' || generate_series(1, $BULK_COUNT) || '@example.com',
    'hashed_password_' || generate_series(1, $BULK_COUNT),
    NOW(),
    NOW();
COMMIT;"

END_TIME=$(date +%s)
BULK_TIME=$((END_TIME - START_TIME))
BULK_RATE=$((BULK_COUNT / BULK_TIME))
# $BULK_COUNT 레코드를 ${BULK_TIME}초에 삽입 (${BULK_RATE} 레코드/초)

# 복제 지연 측정 (관리 서버에서 실행)
# 복제 지연 측정 중...
MARKER_ID=$(date +%s%N)
psql -h "$CURRENT_MASTER" -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('sync_marker_$MARKER_ID', 'sync_marker_$MARKER_ID@example.com', 'hashed_password', NOW(), NOW());" > /dev/null

# Slave에서 마커 레코드가 나타날 때까지 대기
SYNC_START=$(date +%s%N)
while true; do
    MARKER_COUNT=$(psql -h "$CURRENT_SLAVE" -U postgres -t -c "
    SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = 'sync_marker_$MARKER_ID@example.com';" 2>/dev/null | tr -d ' ')
    
    if [ "$MARKER_COUNT" = "1" ]; then
        break
    fi
    
    sleep 0.1
done
SYNC_END=$(date +%s%N)
REPLICATION_LAG=$(( (SYNC_END - MARKER_ID) / 1000000 ))
# 복제 지연 시간: ${REPLICATION_LAG}ms

# 동시 연결 테스트 (관리 서버에서 실행)
# 동시 연결 테스트 중...
CONCURRENT_CONNECTIONS=10
for i in $(seq 1 $CONCURRENT_CONNECTIONS); do
    {
        for j in {1..10}; do
            psql -h "$CURRENT_MASTER" -U postgres -c "
            INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
            VALUES ('concurrent_${i}_${j}', 'concurrent_${i}_${j}@example.com', 'hashed_password', NOW(), NOW());" > /dev/null 2>&1
        done
    } &
done

# 모든 백그라운드 작업 완료 대기
wait
# ${CONCURRENT_CONNECTIONS}개 동시 연결에서 각각 10개 레코드 삽입 완료

# =============================================================================
# 7. 데이터 일관성 최종 확인
# =============================================================================

# 7. 데이터 일관성 최종 확인

# 복제 완료 대기
# 복제 완료 대기 중... (10초)
sleep 10

# 주요 테이블들의 레코드 수 비교 (관리 서버에서 실행)
# 테이블별 레코드 수 비교 중...
TABLES=("Auth" "User" "ChatRoom" "AccessLog" "Bookmark")

for table in "${TABLES[@]}"; do
    MASTER_COUNT=$(psql -h "$CURRENT_MASTER" -U postgres -t -c "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null | tr -d ' ')
    SLAVE_COUNT=$(psql -h "$CURRENT_SLAVE" -U postgres -t -c "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null | tr -d ' ')
    
    # $table 테이블: Master=$MASTER_COUNT, Slave=$SLAVE_COUNT
    
    if [ "$MASTER_COUNT" = "$SLAVE_COUNT" ]; then
        # $table 테이블 동기화 확인
        true
    else
        # $table 테이블 동기화 불일치
        false
    fi
done

# 관계 무결성 확인 (관리 서버에서 실행)
# 관계 무결성 확인 중...
ORPHAN_USERS=$(psql -h "$CURRENT_SLAVE" -U postgres -t -c "
SELECT COUNT(*) FROM \"User\" u 
LEFT JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.id IS NULL;" 2>/dev/null | tr -d ' ')

if [ "$ORPHAN_USERS" = "0" ]; then
    # 고아 레코드가 없음 - 관계 무결성 확인
    true
else
    # $ORPHAN_USERS개의 고아 User 레코드 발견
    false
fi

# =============================================================================
# 최종 결과 출력
# =============================================================================

# 테스트 완료 시간: $(date)
# 현재 서버 상태:

FINAL_92_RECOVERY=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
FINAL_91_RECOVERY=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')

# 10.164.32.91 (운영1번): $([ "$FINAL_91_RECOVERY" = "f" ] && echo "Master" || echo "Slave")
# 10.164.32.92 (운영2번): $([ "$FINAL_92_RECOVERY" = "f" ] && echo "Master" || echo "Slave")

if psql -h "$CURRENT_MASTER" -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    FINAL_MASTER_COUNT=$(psql -h "$CURRENT_MASTER" -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
    # $CURRENT_MASTER Auth 레코드 수: $FINAL_MASTER_COUNT
fi

if psql -h "$CURRENT_SLAVE" -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    FINAL_SLAVE_COUNT=$(psql -h "$CURRENT_SLAVE" -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
    # $CURRENT_SLAVE Auth 레코드 수: $FINAL_SLAVE_COUNT
fi

# PostgreSQL Master-Slave 테스트가 완료되었습니다!
# 테스트 요약:
# - 초기 연결 및 상태 확인: 완료
# - 복제 상태 확인: 완료
# - 데이터 동기화 테스트: 완료
# - Master 장애 시뮬레이션: 완료
# - Slave 장애 시뮬레이션: 완료
# - 성능 테스트: 완료
# - 데이터 일관성 확인: 완료