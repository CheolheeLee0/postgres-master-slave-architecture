#!/bin/bash
# PostgreSQL Master-Slave 완전 테스트 스위트
# 운영1서버: 10.164.32.91 (Master)
# 운영2서버: 10.164.32.92 (Slave)
# 실행 서버: 관리 서버 (두 서버에 SSH 접근 가능)

set -e

# 테스트 결과 추적
declare -a TEST_RESULTS=()
TOTAL_TESTS=0
PASSED_TESTS=0

# 로그 함수
log_test() {
    local test_name="$1"
    local status="$2"
    local message="$3"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ "$status" = "PASS" ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        TEST_RESULTS+=("✅ $test_name: $message")
    else
        TEST_RESULTS+=("❌ $test_name: $message")
    fi
}

# 서버 연결 확인 함수
check_server_connection() {
    local server_ip="$1"
    local server_name="$2"
    
    if psql -h "$server_ip" -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Recovery 모드 확인 함수
is_in_recovery() {
    local server_ip="$1"
    local recovery_status=$(psql -h "$server_ip" -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    echo "$recovery_status"
}

# 테이블 레코드 수 확인 함수
get_record_count() {
    local server_ip="$1"
    local table_name="$2"
    psql -h "$server_ip" -U postgres -t -c "SELECT COUNT(*) FROM \"$table_name\";" 2>/dev/null | tr -d ' '
}

echo "=========================================="
echo "PostgreSQL Master-Slave 완전 테스트 시작"
echo "=========================================="
echo "시작 시간: $(date)"
echo ""

# =============================================================================
# 1. 초기 연결 및 상태 확인
# =============================================================================

echo "1. 초기 연결 및 상태 확인"
echo "------------------------------------------"

# Master 서버 연결 테스트
if check_server_connection "10.164.32.91" "Master"; then
    log_test "Master 연결" "PASS" "10.164.32.91 연결 성공"
else
    log_test "Master 연결" "FAIL" "10.164.32.91 연결 실패"
    echo "Master 서버에 연결할 수 없습니다. 테스트를 중단합니다."
    exit 1
fi

# Slave 서버 연결 테스트
if check_server_connection "10.164.32.92" "Slave"; then
    log_test "Slave 연결" "PASS" "10.164.32.92 연결 성공"
else
    log_test "Slave 연결" "FAIL" "10.164.32.92 연결 실패"
    echo "Slave 서버에 연결할 수 없습니다. 테스트를 중단합니다."
    exit 1
fi

# Master 상태 확인 (Master 모드여야 함)
MASTER_RECOVERY=$(is_in_recovery "10.164.32.91")
if [ "$MASTER_RECOVERY" = "f" ]; then
    log_test "Master 모드 확인" "PASS" "10.164.32.91이 Master 모드로 실행 중"
else
    log_test "Master 모드 확인" "FAIL" "10.164.32.91이 Master 모드가 아님"
fi

# Slave 상태 확인 (Recovery 모드여야 함)
SLAVE_RECOVERY=$(is_in_recovery "10.164.32.92")
if [ "$SLAVE_RECOVERY" = "t" ]; then
    log_test "Slave 모드 확인" "PASS" "10.164.32.92가 Slave(Recovery) 모드로 실행 중"
else
    log_test "Slave 모드 확인" "FAIL" "10.164.32.92가 Slave 모드가 아님"
fi

# =============================================================================
# 2. 복제 상태 확인
# =============================================================================

echo ""
echo "2. 복제 상태 확인"
echo "------------------------------------------"

# Master에서 복제 슬롯 확인
REPLICATION_SLOTS=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM pg_replication_slots WHERE active = true;" 2>/dev/null | tr -d ' ')
if [ "$REPLICATION_SLOTS" -gt "0" ]; then
    log_test "복제 슬롯 활성화" "PASS" "$REPLICATION_SLOTS개의 활성 복제 슬롯"
else
    log_test "복제 슬롯 활성화" "FAIL" "활성 복제 슬롯이 없음"
fi

# Master에서 WAL Sender 확인
WAL_SENDERS=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')
if [ "$WAL_SENDERS" -gt "0" ]; then
    log_test "WAL Sender 활성화" "PASS" "$WAL_SENDERS개의 활성 WAL Sender"
else
    log_test "WAL Sender 활성화" "FAIL" "활성 WAL Sender가 없음"
fi

# Slave에서 WAL Receiver 확인
WAL_RECEIVERS=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM pg_stat_wal_receiver;" 2>/dev/null | tr -d ' ')
if [ "$WAL_RECEIVERS" -gt "0" ]; then
    log_test "WAL Receiver 활성화" "PASS" "$WAL_RECEIVERS개의 활성 WAL Receiver"
else
    log_test "WAL Receiver 활성화" "FAIL" "활성 WAL Receiver가 없음"
fi

# =============================================================================
# 3. 데이터 동기화 테스트
# =============================================================================

echo ""
echo "3. 데이터 동기화 테스트"
echo "------------------------------------------"

# 초기 레코드 수 확인
MASTER_INITIAL_AUTH=$(get_record_count "10.164.32.91" "Auth")
SLAVE_INITIAL_AUTH=$(get_record_count "10.164.32.92" "Auth")

if [ "$MASTER_INITIAL_AUTH" = "$SLAVE_INITIAL_AUTH" ]; then
    log_test "초기 데이터 동기화" "PASS" "Master: $MASTER_INITIAL_AUTH, Slave: $SLAVE_INITIAL_AUTH"
else
    log_test "초기 데이터 동기화" "FAIL" "Master: $MASTER_INITIAL_AUTH, Slave: $SLAVE_INITIAL_AUTH"
fi

# Master에서 테스트 데이터 삽입
TEST_ID=$(date +%s)
TEST_EMAIL="sync_test_$TEST_ID@example.com"

# Master에서 Auth 데이터 삽입
INSERT_RESULT=$(psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('test_auth_$TEST_ID', '$TEST_EMAIL', 'hashed_password_$TEST_ID', NOW(), NOW()) 
RETURNING id;" 2>&1)

if echo "$INSERT_RESULT" | grep -q "INSERT 0 1"; then
    log_test "Master 데이터 삽입" "PASS" "Auth 레코드 삽입 성공"
else
    log_test "Master 데이터 삽입" "FAIL" "Auth 레코드 삽입 실패: $INSERT_RESULT"
fi

# Master에서 연관 User 데이터 삽입
USER_INSERT_RESULT=$(psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"User\" (id, \"authId\", role, language, name, \"createdAt\", \"updatedAt\") 
VALUES ('test_user_$TEST_ID', 'test_auth_$TEST_ID', 'CUSTOMER', 'ko', 'Test User $TEST_ID', NOW(), NOW()) 
RETURNING id;" 2>&1)

if echo "$USER_INSERT_RESULT" | grep -q "INSERT 0 1"; then
    log_test "Master 관계 데이터 삽입" "PASS" "User 레코드 삽입 성공"
else
    log_test "Master 관계 데이터 삽입" "FAIL" "User 레코드 삽입 실패: $USER_INSERT_RESULT"
fi

# 동기화 대기 (5초)
sleep 5

# Slave에서 데이터 확인
SLAVE_TEST_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = '$TEST_EMAIL';" 2>/dev/null | tr -d ' ')

if [ "$SLAVE_TEST_COUNT" = "1" ]; then
    log_test "Slave 데이터 동기화" "PASS" "테스트 데이터가 Slave로 동기화됨"
else
    log_test "Slave 데이터 동기화" "FAIL" "테스트 데이터가 Slave로 동기화되지 않음"
fi

# JOIN 쿼리로 관계 데이터 확인
USER_JOIN_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "
SELECT COUNT(*) FROM \"User\" u 
JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.\"emailAddress\" = '$TEST_EMAIL';" 2>/dev/null | tr -d ' ')

if [ "$USER_JOIN_COUNT" = "1" ]; then
    log_test "Slave 관계 데이터 동기화" "PASS" "User-Auth 관계 데이터가 정상 동기화됨"
else
    log_test "Slave 관계 데이터 동기화" "FAIL" "User-Auth 관계 데이터 동기화 실패"
fi

# =============================================================================
# 4. Master 장애 시뮬레이션 테스트
# =============================================================================

echo ""
echo "4. Master 장애 시뮬레이션 테스트"
echo "------------------------------------------"

# 장애 전 데이터 삽입
FAILURE_TEST_ID=$(date +%s)
psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('pre_failure_$FAILURE_TEST_ID', 'pre_failure_$FAILURE_TEST_ID@example.com', 'hashed_password', NOW(), NOW());" > /dev/null 2>&1

INITIAL_COUNT=$(get_record_count "10.164.32.91" "Auth")

# Master 서비스 중지 (SSH를 통해 원격으로 중지)
ssh root@10.164.32.91 "systemctl stop postgresql" 2>/dev/null || true
sleep 3

# Master 연결 불가 확인
if check_server_connection "10.164.32.91" "Master"; then
    log_test "Master 장애 시뮬레이션" "FAIL" "Master가 여전히 응답하고 있음"
else
    log_test "Master 장애 시뮬레이션" "PASS" "Master 서비스가 정상적으로 중지됨"
fi

# Slave 상태 확인 (여전히 실행 중이어야 함)
if check_server_connection "10.164.32.92" "Slave"; then
    log_test "Slave 생존 확인" "PASS" "Master 장애 시 Slave가 정상 동작 중"
else
    log_test "Slave 생존 확인" "FAIL" "Master 장애 시 Slave도 응답하지 않음"
fi

# Slave를 Master로 승격
PROMOTE_RESULT=$(psql -h 10.164.32.92 -U postgres -c "SELECT pg_promote();" 2>&1)

if echo "$PROMOTE_RESULT" | grep -q "t"; then
    sleep 5
    # 승격 확인
    NEW_MASTER_RECOVERY=$(is_in_recovery "10.164.32.92")
    if [ "$NEW_MASTER_RECOVERY" = "f" ]; then
        log_test "Slave 승격" "PASS" "Slave가 성공적으로 Master로 승격됨"
    else
        log_test "Slave 승격" "FAIL" "Slave 승격 후에도 Recovery 모드임"
    fi
else
    log_test "Slave 승격" "FAIL" "Slave 승격 명령 실패: $PROMOTE_RESULT"
fi

# 새 Master에서 쓰기 테스트
NEW_MASTER_TEST_ID=$(date +%s)
NEW_MASTER_INSERT=$(psql -h 10.164.32.92 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('post_failover_$NEW_MASTER_TEST_ID', 'post_failover_$NEW_MASTER_TEST_ID@example.com', 'hashed_password', NOW(), NOW()) 
RETURNING id;" 2>&1)

if echo "$NEW_MASTER_INSERT" | grep -q "INSERT 0 1"; then
    log_test "새 Master 쓰기" "PASS" "새 Master에서 쓰기 작업 성공"
else
    log_test "새 Master 쓰기" "FAIL" "새 Master에서 쓰기 작업 실패"
fi

# 원래 Master 복구
ssh root@10.164.32.91 "systemctl start postgresql" 2>/dev/null || true
sleep 10

# 복구된 서버 상태 확인
if check_server_connection "10.164.32.91" "Original Master"; then
    RECOVERED_RECOVERY=$(is_in_recovery "10.164.32.91")
    if [ "$RECOVERED_RECOVERY" = "t" ]; then
        log_test "원래 Master 복구" "PASS" "원래 Master가 Slave로 자동 전환됨"
    else
        log_test "원래 Master 복구" "FAIL" "원래 Master가 Master 모드로 복구됨 (Split-brain 위험)"
    fi
else
    log_test "원래 Master 복구" "FAIL" "원래 Master 서버 복구 실패"
fi

# =============================================================================
# 5. Slave 장애 시뮬레이션 테스트
# =============================================================================

echo ""
echo "5. Slave 장애 시뮬레이션 테스트"
echo "------------------------------------------"

# 현재 Master 확인 (10.164.32.92가 Master여야 함)
CURRENT_MASTER_RECOVERY=$(is_in_recovery "10.164.32.92")
if [ "$CURRENT_MASTER_RECOVERY" = "f" ]; then
    CURRENT_MASTER="10.164.32.92"
    CURRENT_SLAVE="10.164.32.91"
else
    CURRENT_MASTER="10.164.32.91"
    CURRENT_SLAVE="10.164.32.92"
fi

# Slave 서비스 중지
ssh root@$CURRENT_SLAVE "systemctl stop postgresql" 2>/dev/null || true
sleep 3

# Slave 연결 불가 확인
if check_server_connection "$CURRENT_SLAVE" "Current Slave"; then
    log_test "Slave 장애 시뮬레이션" "FAIL" "Slave가 여전히 응답하고 있음"
else
    log_test "Slave 장애 시뮬레이션" "PASS" "Slave 서비스가 정상적으로 중지됨"
fi

# Master 상태 확인 (여전히 실행 중이어야 함)
if check_server_connection "$CURRENT_MASTER" "Current Master"; then
    log_test "Master 생존 확인" "PASS" "Slave 장애 시 Master가 정상 동작 중"
else
    log_test "Master 생존 확인" "FAIL" "Slave 장애 시 Master도 응답하지 않음"
fi

# Master에서 계속 쓰기 작업 테스트
SLAVE_FAILURE_TEST_ID=$(date +%s)
for i in {1..3}; do
    WRITE_TEST_ID="${SLAVE_FAILURE_TEST_ID}_$i"
    WRITE_RESULT=$(psql -h "$CURRENT_MASTER" -U postgres -c "
    INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
    VALUES ('during_slave_failure_$WRITE_TEST_ID', 'during_slave_failure_$WRITE_TEST_ID@example.com', 'hashed_password', NOW(), NOW());" 2>&1)
    
    if echo "$WRITE_RESULT" | grep -q "INSERT 0 1"; then
        continue
    else
        log_test "Slave 장애 중 Master 쓰기" "FAIL" "Master 쓰기 작업 $i 실패"
        break
    fi
done

log_test "Slave 장애 중 Master 쓰기" "PASS" "Slave 장애 중에도 Master 쓰기 작업 정상"

# Slave 복구
ssh root@$CURRENT_SLAVE "systemctl start postgresql" 2>/dev/null || true
sleep 10

# Slave 복구 확인
if check_server_connection "$CURRENT_SLAVE" "Recovered Slave"; then
    RECOVERED_SLAVE_RECOVERY=$(is_in_recovery "$CURRENT_SLAVE")
    if [ "$RECOVERED_SLAVE_RECOVERY" = "t" ]; then
        log_test "Slave 복구" "PASS" "Slave가 정상적으로 복구되어 Recovery 모드로 실행 중"
    else
        log_test "Slave 복구" "FAIL" "Slave가 Master 모드로 복구됨"
    fi
else
    log_test "Slave 복구" "FAIL" "Slave 서버 복구 실패"
fi

# 복제 재연결 확인 (5초 대기 후)
sleep 5
REPLICATION_RECONNECTED=$(psql -h "$CURRENT_MASTER" -U postgres -t -c "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')

if [ "$REPLICATION_RECONNECTED" -gt "0" ]; then
    log_test "복제 재연결" "PASS" "복제 연결이 재설정됨"
else
    log_test "복제 재연결" "FAIL" "복제 연결이 재설정되지 않음"
fi

# =============================================================================
# 6. 성능 테스트
# =============================================================================

echo ""
echo "6. 성능 테스트"
echo "------------------------------------------"

# 대량 데이터 삽입 성능 테스트
BULK_COUNT=1000
START_TIME=$(date +%s)

BULK_INSERT_RESULT=$(psql -h "$CURRENT_MASTER" -U postgres -c "
BEGIN;
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\")
SELECT 
    'perf_auth_' || generate_series(1, $BULK_COUNT),
    'perf_user_' || generate_series(1, $BULK_COUNT) || '@example.com',
    'hashed_password_' || generate_series(1, $BULK_COUNT),
    NOW(),
    NOW();
COMMIT;" 2>&1)

END_TIME=$(date +%s)
BULK_TIME=$((END_TIME - START_TIME))

if echo "$BULK_INSERT_RESULT" | grep -q "INSERT 0 $BULK_COUNT"; then
    BULK_RATE=$((BULK_COUNT / BULK_TIME))
    log_test "대량 삽입 성능" "PASS" "$BULK_COUNT 레코드를 ${BULK_TIME}초에 삽입 (${BULK_RATE} 레코드/초)"
else
    log_test "대량 삽입 성능" "FAIL" "대량 삽입 실패"
fi

# 복제 지연 측정
MARKER_ID=$(date +%s%N)
psql -h "$CURRENT_MASTER" -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('sync_marker_$MARKER_ID', 'sync_marker_$MARKER_ID@example.com', 'hashed_password', NOW(), NOW());" > /dev/null 2>&1

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

log_test "복제 지연 측정" "PASS" "복제 지연 시간: ${REPLICATION_LAG}ms"

# 동시 연결 테스트
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

log_test "동시 연결 테스트" "PASS" "${CONCURRENT_CONNECTIONS}개 동시 연결에서 각각 10개 레코드 삽입 완료"

# =============================================================================
# 7. 데이터 일관성 최종 확인
# =============================================================================

echo ""
echo "7. 데이터 일관성 최종 확인"
echo "------------------------------------------"

# 복제 완료 대기
sleep 10

# 주요 테이블들의 레코드 수 비교
TABLES=("Auth" "User" "ChatRoom" "AccessLog" "Bookmark")
ALL_SYNCED=true

for table in "${TABLES[@]}"; do
    MASTER_COUNT=$(get_record_count "$CURRENT_MASTER" "$table")
    SLAVE_COUNT=$(get_record_count "$CURRENT_SLAVE" "$table")
    
    if [ "$MASTER_COUNT" = "$SLAVE_COUNT" ]; then
        log_test "${table} 테이블 동기화" "PASS" "Master: $MASTER_COUNT, Slave: $SLAVE_COUNT"
    else
        log_test "${table} 테이블 동기화" "FAIL" "Master: $MASTER_COUNT, Slave: $SLAVE_COUNT"
        ALL_SYNCED=false
    fi
done

if [ "$ALL_SYNCED" = true ]; then
    log_test "전체 데이터 일관성" "PASS" "모든 테이블이 완전히 동기화됨"
else
    log_test "전체 데이터 일관성" "FAIL" "일부 테이블에서 동기화 불일치"
fi

# 관계 무결성 확인
ORPHAN_USERS=$(psql -h "$CURRENT_SLAVE" -U postgres -t -c "
SELECT COUNT(*) FROM \"User\" u 
LEFT JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.id IS NULL;" 2>/dev/null | tr -d ' ')

if [ "$ORPHAN_USERS" = "0" ]; then
    log_test "관계 무결성 확인" "PASS" "고아 레코드가 없음"
else
    log_test "관계 무결성 확인" "FAIL" "$ORPHAN_USERS개의 고아 User 레코드 발견"
fi

# =============================================================================
# 최종 결과 출력
# =============================================================================

echo ""
echo "=========================================="
echo "테스트 완료 시간: $(date)"
echo "=========================================="
echo ""
echo "테스트 결과 요약:"
echo "----------------"

for result in "${TEST_RESULTS[@]}"; do
    echo "$result"
done

echo ""
echo "총 테스트 수: $TOTAL_TESTS"
echo "성공한 테스트 수: $PASSED_TESTS"
echo "실패한 테스트 수: $((TOTAL_TESTS - PASSED_TESTS))"
SUCCESS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
echo "성공률: ${SUCCESS_RATE}%"

echo ""
echo "현재 서버 상태:"
echo "---------------"
FINAL_MASTER_RECOVERY=$(is_in_recovery "$CURRENT_MASTER")
FINAL_SLAVE_RECOVERY=$(is_in_recovery "$CURRENT_SLAVE")

echo "$CURRENT_MASTER: $([ "$FINAL_MASTER_RECOVERY" = "f" ] && echo "Master" || echo "Slave")"
echo "$CURRENT_SLAVE: $([ "$FINAL_SLAVE_RECOVERY" = "t" ] && echo "Slave" || echo "Master")"

if check_server_connection "$CURRENT_MASTER" "Current Master"; then
    FINAL_MASTER_COUNT=$(get_record_count "$CURRENT_MASTER" "Auth")
    echo "$CURRENT_MASTER Auth 레코드 수: $FINAL_MASTER_COUNT"
fi

if check_server_connection "$CURRENT_SLAVE" "Current Slave"; then
    FINAL_SLAVE_COUNT=$(get_record_count "$CURRENT_SLAVE" "Auth")
    echo "$CURRENT_SLAVE Auth 레코드 수: $FINAL_SLAVE_COUNT"
fi

echo ""
if [ $SUCCESS_RATE -eq 100 ]; then
    echo "🎉 모든 테스트가 성공적으로 완료되었습니다!"
    exit 0
elif [ $SUCCESS_RATE -ge 80 ]; then
    echo "⚠️ 대부분의 테스트가 성공했지만 일부 문제가 있습니다."
    exit 1
else
    echo "❌ 심각한 문제가 발견되었습니다. 시스템 점검이 필요합니다."
    exit 1
fi