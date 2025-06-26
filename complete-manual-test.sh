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
# 연결 성공한 경우: ✅ Master 서버 (10.164.32.91) 연결 성공
# 연결 실패한 경우: ❌ Master 서버 (10.164.32.91) 연결 실패

# Slave 서버 연결 테스트 (관리 서버에서 실행)
# Slave 서버 연결 테스트 중...
psql -h 10.164.32.92 -U postgres -c "SELECT version();"
# 연결 성공한 경우: ✅ Slave 서버 (10.164.32.92) 연결 성공
# 연결 실패한 경우: ❌ Slave 서버 (10.164.32.92) 연결 실패

# Master 상태 확인 (관리 서버에서 실행)
# Master 상태 확인 중...
psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();"
# 결과가 'f' 인 경우: ✅ 10.164.32.91이 Master 모드로 실행 중
# 결과가 't' 인 경우: ❌ 10.164.32.91이 Master 모드가 아님

# Slave 상태 확인 (관리 서버에서 실행)
# Slave 상태 확인 중...
psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();"
# 결과가 't' 인 경우: ✅ 10.164.32.92가 Slave(Recovery) 모드로 실행 중
# 결과가 'f' 인 경우: ❌ 10.164.32.92가 Slave 모드가 아님

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
psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";"
psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";"
# Master와 Slave의 레코드 수가 같은 경우: ✅ 초기 데이터 동기화 확인됨
# Master와 Slave의 레코드 수가 다른 경우: ❌ 초기 데이터 동기화 불일치

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

# Slave에서 데이터 확인 (관리 서버에서 실행)
# Slave에서 데이터 동기화 확인 중...
psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = '$TEST_EMAIL';"
# 결과가 '1'인 경우: ✅ Auth 데이터가 Slave로 정상 동기화됨
# 결과가 '0'인 경우: ❌ Auth 데이터가 Slave로 동기화되지 않음

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

# 장애 전 Master Auth 레코드 수 확인
psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";"

echo ""
echo "🔶 다음 명령어를 운영1번 서버(10.164.32.91)에서 실행하세요:"
echo "sudo systemctl stop postgresql"
echo ""
echo "위 명령어를 실행한 후 Enter를 누르세요..."
read -r

# Master 연결 불가 확인 (관리 서버에서 실행)
# Master 연결 불가 확인 중...
psql -h 10.164.32.91 -U postgres -c "SELECT 1;"
# 연결 성공한 경우: ❌ Master가 여전히 응답하고 있음
# 연결 실패한 경우: ✅ Master 서비스가 정상적으로 중지됨

# Slave 상태 확인 (관리 서버에서 실행)
# Slave 생존 확인 중...
psql -h 10.164.32.92 -U postgres -c "SELECT 1;"
# 연결 성공한 경우: ✅ Master 장애 시 Slave가 정상 동작 중
# 연결 실패한 경우: ❌ Master 장애 시 Slave도 응답하지 않음

# Slave를 Master로 승격 (관리 서버에서 실행)
# Slave를 Master로 승격 중...
psql -h 10.164.32.92 -U postgres -c "SELECT pg_promote();"

# 승격 완료 대기

# 승격 확인 (관리 서버에서 실행)
psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();"
# 결과가 'f'인 경우: ✅ Slave가 성공적으로 Master로 승격됨
# 결과가 't'인 경우: ❌ Slave 승격 후에도 Recovery 모드임

# 새 Master에서 쓰기 테스트 (관리 서버에서 실행)
# 새 Master에서 쓰기 테스트 중...
NEW_MASTER_TEST_ID=$(date +%s)
psql -h 10.164.32.92 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('post_failover_$NEW_MASTER_TEST_ID', 'post_failover_$NEW_MASTER_TEST_ID@example.com', 'hashed_password', NOW(), NOW()) 
RETURNING id;"
# INSERT 성공한 경우: ✅ 새 Master에서 쓰기 작업 성공
# INSERT 실패한 경우: ❌ 새 Master에서 쓰기 작업 실패

echo ""
echo "🔶 다음 명령어를 운영1번 서버(10.164.32.91)에서 실행하세요:"
echo "sudo systemctl start postgresql"
echo ""
echo "위 명령어를 실행한 후 Enter를 누르세요..."
read -r

# 복구된 서버 상태 확인 (관리 서버에서 실행)
# 복구된 서버 상태 확인 중...
psql -h 10.164.32.91 -U postgres -c "SELECT 1;"
# 연결이 성공한 경우 다음 명령어 실행:
psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();"
# 결과가 't'인 경우: ✅ 원래 Master가 Slave로 자동 전환됨
# 결과가 'f'인 경우: ❌ 원래 Master가 Master 모드로 복구됨 (Split-brain 위험)
# 연결이 실패한 경우: ❌ 원래 Master 서버 복구 실패

# =============================================================================
# 5. Slave 장애 시뮬레이션 테스트
# =============================================================================

# 5. Slave 장애 시뮬레이션 테스트

# 현재 Master/Slave 확인 (관리 서버에서 실행)
# 현재 Master/Slave 상태 확인 중...
psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();"
psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();"
# 10.164.32.92 결과가 'f'인 경우: Master는 10.164.32.92(운영2번), Slave는 10.164.32.91(운영1번)
# 10.164.32.91 결과가 'f'인 경우: Master는 10.164.32.91(운영1번), Slave는 10.164.32.92(운영2번)

# 현재 상황에 따라 아래 변수를 수동으로 설정하세요
CURRENT_MASTER="10.164.32.92"  # 실제 Master IP로 변경
CURRENT_SLAVE="10.164.32.91"   # 실제 Slave IP로 변경
SLAVE_SERVER="운영1번"          # 실제 Slave 서버명으로 변경

echo ""
echo "🔶 다음 명령어를 $SLAVE_SERVER 서버($CURRENT_SLAVE)에서 실행하세요:"
echo "sudo systemctl stop postgresql"
echo ""
echo "위 명령어를 실행한 후 Enter를 누르세요..."
read -r

# Slave 연결 불가 확인 (관리 서버에서 실행)
# Slave 연결 불가 확인 중...
psql -h "$CURRENT_SLAVE" -U postgres -c "SELECT 1;"
# 연결 성공한 경우: ❌ Slave가 여전히 응답하고 있음
# 연결 실패한 경우: ✅ Slave 서비스가 정상적으로 중지됨

# Master 상태 확인 (관리 서버에서 실행)
# Master 생존 확인 중...
psql -h "$CURRENT_MASTER" -U postgres -c "SELECT 1;"
# 연결 성공한 경우: ✅ Slave 장애 시 Master가 정상 동작 중
# 연결 실패한 경우: ❌ Slave 장애 시 Master도 응답하지 않음

# Master에서 계속 쓰기 작업 테스트 (관리 서버에서 실행)
# Master에서 쓰기 작업 테스트 중...
SLAVE_FAILURE_TEST_ID=$(date +%s)
for i in {1..3}; do
    WRITE_TEST_ID="${SLAVE_FAILURE_TEST_ID}_$i"
    echo "쓰기 테스트 $i 실행 중..."
    psql -h "$CURRENT_MASTER" -U postgres -c "
    INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
    VALUES ('during_slave_failure_$WRITE_TEST_ID', 'during_slave_failure_$WRITE_TEST_ID@example.com', 'hashed_password', NOW(), NOW());"
    # INSERT 성공한 경우: ✅ 쓰기 테스트 $i 성공
    # INSERT 실패한 경우: ❌ 쓰기 테스트 $i 실패
done
# 모든 쓰기 테스트가 성공한 경우: ✅ Slave 장애 중에도 Master 쓰기 작업 정상

echo ""
echo "🔶 다음 명령어를 $SLAVE_SERVER 서버($CURRENT_SLAVE)에서 실행하세요:"
echo "sudo systemctl start postgresql"
echo ""
echo "위 명령어를 실행한 후 Enter를 누르세요..."
read -r

# Slave 복구 확인 (관리 서버에서 실행)
# Slave 복구 상태 확인 중...
psql -h "$CURRENT_SLAVE" -U postgres -c "SELECT 1;"
# 연결이 성공한 경우 다음 명령어 실행:
psql -h "$CURRENT_SLAVE" -U postgres -t -c "SELECT pg_is_in_recovery();"
# 결과가 't'인 경우: ✅ Slave가 정상적으로 복구되어 Recovery 모드로 실행 중
# 결과가 'f'인 경우: ❌ Slave가 Master 모드로 복구됨
# 연결이 실패한 경우: ❌ Slave 서버 복구 실패

# 복제 재연결 확인 (관리 서버에서 실행)

psql -h "$CURRENT_MASTER" -U postgres -t -c "SELECT COUNT(*) FROM pg_stat_replication;"
# 결과가 0보다 큰 경우: ✅ 복제 연결이 재설정됨
psql -h "$CURRENT_MASTER" -U postgres -c "
SELECT application_name, client_addr, state, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
FROM pg_stat_replication;"
# 결과가 0인 경우: ❌ 복제 연결이 재설정되지 않음

# =============================================================================
# 6. 성능 테스트
# =============================================================================

# 6. 성능 테스트

# 대량 데이터 삽입 성능 테스트 (관리 서버에서 실행)
# 대량 데이터 삽입 성능 테스트 중...
BULK_COUNT=1000
echo "시작 시간: $(date)"

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

echo "종료 시간: $(date)"
# INSERT 성공한 경우: ✅ 1000개 레코드 삽입 완료
# INSERT 실패한 경우: ❌ 대량 삽입 실패

# 복제 지연 측정 (관리 서버에서 실행)
# 복제 지연 측정 중...
MARKER_ID=$(date +%s%N)
echo "마커 삽입 시간: $(date)"
psql -h "$CURRENT_MASTER" -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('sync_marker_$MARKER_ID', 'sync_marker_$MARKER_ID@example.com', 'hashed_password', NOW(), NOW());"

# 수동으로 Slave에서 마커 레코드 확인
echo "Slave에서 다음 명령어로 마커 레코드가 동기화될 때까지 확인:"
echo "psql -h \"$CURRENT_SLAVE\" -U postgres -t -c \"SELECT COUNT(*) FROM \\\"Auth\\\" WHERE \\\"emailAddress\\\" = 'sync_marker_$MARKER_ID@example.com';\""
echo "결과가 1이 나올 때까지 반복 실행하고, 동기화 시간을 확인하세요."

# 동시 연결 테스트 (관리 서버에서 실행)
# 동시 연결 테스트 중...
CONCURRENT_CONNECTIONS=10
echo "동시 연결 테스트 시작: $(date)"
for i in $(seq 1 $CONCURRENT_CONNECTIONS); do
    {
        for j in {1..10}; do
            psql -h "$CURRENT_MASTER" -U postgres -c "
            INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
            VALUES ('concurrent_${i}_${j}', 'concurrent_${i}_${j}@example.com', 'hashed_password', NOW(), NOW());" > /dev/null 2>&1
        done
    } &
done

# 모든 백그라운드 작업 완룉 대기
wait
echo "동시 연결 테스트 완료: $(date)"
# 모든 INSERT가 성공한 경우: ✅ 10개 동시 연결에서 각각 10개 레코드 삽입 완료
# 일부 INSERT가 실패한 경우: ❌ 동시 연결 테스트 중 일부 실패

# =============================================================================
# 7. 데이터 일관성 최종 확인
# =============================================================================

# 7. 데이터 일관성 최종 확인

# 복제 완료 대기

# 주요 테이블들의 레코드 수 비교 (관리 서버에서 실행)
# 테이블별 레코드 수 비교 중...
TABLES=("Auth" "User" "ChatRoom" "AccessLog" "Bookmark")

for table in "${TABLES[@]}"; do
    echo "$table 테이블 확인 중..."
    psql -h "$CURRENT_MASTER" -U postgres -t -c "SELECT COUNT(*) FROM \"$table\";"
    psql -h "$CURRENT_SLAVE" -U postgres -t -c "SELECT COUNT(*) FROM \"$table\";"
    # Master와 Slave의 레코드 수가 같은 경우: ✅ $table 테이블 동기화 확인
    # Master와 Slave의 레코드 수가 다른 경우: ❌ $table 테이블 동기화 불일치
done

# 관계 무결성 확인 (관리 서버에서 실행)
# 관계 무결성 확인 중...
psql -h "$CURRENT_SLAVE" -U postgres -t -c "
SELECT COUNT(*) FROM \"User\" u 
LEFT JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.id IS NULL;"
# 결과가 0인 경우: ✅ 고아 레코드가 없음 - 관계 무결성 확인
# 결과가 0보다 큰 경우: ❌ 고아 User 레코드 발견

# =============================================================================
# 최종 결과 출력
# =============================================================================

# 테스트 완료 시간: $(date)
# 현재 서버 상태:

# 최종 서버 상태 확인
psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();"
psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();"
# 각 서버의 결과가 'f'인 경우: Master
# 각 서버의 결과가 't'인 경우: Slave

# 최종 레코드 수 확인
psql -h "$CURRENT_MASTER" -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";"
psql -h "$CURRENT_SLAVE" -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";"
# 각 서버의 Auth 레코드 수를 확인하여 동기화 상태를 점검하세요

# PostgreSQL Master-Slave 테스트가 완료되었습니다!
# 테스트 요약:
# - 초기 연결 및 상태 확인: 완료
# - 복제 상태 확인: 완료
# - 데이터 동기화 테스트: 완료
# - Master 장애 시뮬레이션: 완료
# - Slave 장애 시뮬레이션: 완료
# - 성능 테스트: 완료
# - 데이터 일관성 확인: 완료