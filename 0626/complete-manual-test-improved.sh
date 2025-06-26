#!/bin/bash
# PostgreSQL Master-Slave 수동 테스트 가이드 (개선 버전)
# 운영1서버: 10.164.32.91 (Master)
# 운영2서버: 10.164.32.92 (Slave)

# =============================================================================
# 0. Master-Slave 초기 설정 (DB는 기존에 생성되어 있음)
# =============================================================================

# 1번서버에서 실행 - Master 복제 설정
# 🔶 1번서버 SSH 접속 후 실행
docker exec -it rtt-postgres bash
su postgres
psql

# 복제 사용자 생성 (이미 존재하면 무시)
CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicator_password';

# 복제 슬롯 생성 (이미 존재하면 무시)
SELECT pg_create_physical_replication_slot('slave_slot');

# 설정 확인
SELECT slot_name, slot_type, active FROM pg_replication_slots;

\q
exit
exit

# 1번서버에서 실행 - postgresql.conf 설정
docker exec rtt-postgres bash -c "
cat >> /var/lib/postgresql/data/postgresql.conf << 'EOF'

# Master-Slave 복제 설정
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
synchronous_commit = on
archive_mode = on
archive_command = 'cp %p /var/lib/postgresql/data/pg_wal_archive/%f || true'
EOF
"

# 1번서버에서 실행 - pg_hba.conf 설정
docker exec rtt-postgres bash -c "
echo 'host replication replicator 10.164.32.92/32 md5' >> /var/lib/postgresql/data/pg_hba.conf
echo 'host all postgres 10.164.32.92/32 md5' >> /var/lib/postgresql/data/pg_hba.conf
"

# 1번서버에서 실행 - WAL 아카이브 디렉토리 생성
docker exec rtt-postgres bash -c "
mkdir -p /var/lib/postgresql/data/pg_wal_archive
chown postgres:postgres /var/lib/postgresql/data/pg_wal_archive
chmod 700 /var/lib/postgresql/data/pg_wal_archive
"

# 1번서버에서 실행 - PostgreSQL 재시작
docker restart rtt-postgres

# 2번서버에서 실행 - Slave 설정
# 🔶 2번서버 SSH 접속 후 실행
docker exec -it rtt-postgres bash
su postgres

# 기존 데이터 정리 (주의: 데이터 손실)
rm -rf /var/lib/postgresql/data/*

# Master에서 베이스 백업 생성
PGPASSWORD=replicator_password pg_basebackup -h 10.164.32.91 -D /var/lib/postgresql/data -U replicator -v -P

# standby.signal 파일 생성
touch /var/lib/postgresql/data/standby.signal

# postgresql.conf에 복제 설정 추가
cat >> /var/lib/postgresql/data/postgresql.conf << 'EOF'

# Slave 복제 설정
primary_conninfo = 'host=10.164.32.91 port=5432 user=replicator password=replicator_password application_name=slave_node'
primary_slot_name = 'slave_slot'
restore_command = ''
archive_cleanup_command = ''
EOF

exit
exit

# 2번서버에서 실행 - PostgreSQL 재시작
docker restart rtt-postgres

# =============================================================================
# 목차
# =============================================================================
# 1. 초기 연결 및 상태 확인
# 2. 복제 상태 확인  
# 3. 데이터 동기화 테스트
# 4. Master 장애 시뮬레이션 테스트
# 5. Slave 장애 시뮬레이션 테스트
# 6. 성능 테스트
# 7. 데이터 일관성 최종 확인
# 8. 운영 서버 장애 시나리오 테스트
#    8-1. 운영1번 서버 전체 장애 (서버 다운)
#    8-2. 운영2번 서버 전체 장애 (서버 다운)
#    8-3. 운영1번 PostgreSQL DB만 장애
#    8-4. 운영2번 PostgreSQL DB만 장애

# =============================================================================
# 1. 초기 연결 및 상태 확인
# =============================================================================

# 1번서버에서 테스트 - Master 서버 연결 테스트
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT version();"
# 성공: ✅ Master 연결 성공 / 실패: ❌ Master 연결 실패

# 2번서버에서 테스트 - Slave 서버 연결 테스트
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT version();"
# 성공: ✅ Slave 연결 성공 / 실패: ❌ Slave 연결 실패

# 1번서버에서 테스트 - Master 상태 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 'f': ✅ Master 모드 / 결과 't': ❌ Master 모드 아님

# 2번서버에서 테스트 - Slave 상태 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 't': ✅ Slave 모드 / 결과 'f': ❌ Slave 모드 아님

# =============================================================================
# 2. 복제 상태 확인
# =============================================================================

# 1번서버에서 테스트 - 복제 슬롯 상태 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT slot_name, slot_type, active, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
FROM pg_replication_slots;"

# 1번서버에서 테스트 - WAL Sender 상태 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT pid, usename, application_name, client_addr, state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
FROM pg_stat_replication;"

# 2번서버에서 테스트 - WAL Receiver 상태 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT pid, status, receive_start_lsn, received_lsn,
       last_msg_send_time, last_msg_receipt_time
FROM pg_stat_wal_receiver;"

# =============================================================================
# 3. 데이터 동기화 테스트
# =============================================================================

# 1번서버에서 테스트 - 초기 데이터 개수 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"Auth\";"

# 2번서버에서 테스트 - 초기 데이터 개수 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"Auth\";"
# 개수 동일: ✅ 초기 데이터 동기화 확인 / 개수 다름: ❌ 동기화 불일치

# 1번서버에서 테스트 - 테스트 데이터 삽입 (Master에서만 실행)
# 🔶 1번서버에서 실행
TIMESTAMP=$(date +%s)
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('test_auth_$TIMESTAMP', 'sync_test_$TIMESTAMP@example.com', 'hashed_password_$TIMESTAMP', NOW(), NOW()) 
RETURNING id;"

# 1번서버에서 테스트 - User 데이터 삽입 (Master에서만 실행)
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"User\" (id, \"authId\", role, language, name, \"createdAt\", \"updatedAt\") 
VALUES ('test_user_$TIMESTAMP', 'test_auth_$TIMESTAMP', 'CUSTOMER', 'ko', 'Test User $TIMESTAMP', NOW(), NOW()) 
RETURNING id;"

# 동기화 대기 (3초)
echo "동기화 대기 중..."
sleep 3

# 2번서버에서 테스트 - Slave에서 데이터 동기화 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = 'sync_test_$TIMESTAMP@example.com';"
# 결과 '1': ✅ 데이터 동기화 됨 / 결과 '0': ❌ 동기화 안됨

# 2번서버에서 테스트 - 관계 데이터 동기화 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT u.id as user_id, u.name, a.\"emailAddress\", u.role
FROM \"User\" u 
JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.\"emailAddress\" = 'sync_test_$TIMESTAMP@example.com';"

# =============================================================================
# 4. Master 장애 시뮬레이션 테스트
# =============================================================================

# 1번서버에서 테스트 - 장애 전 테스트 데이터 삽입
# 🔶 1번서버에서 실행
FAILURE_TIMESTAMP=$(date +%s)
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('pre_failure_$FAILURE_TIMESTAMP', 'pre_failure_$FAILURE_TIMESTAMP@example.com', 'hashed_password', NOW(), NOW());"

# 1번서버에서 테스트 - 장애 전 레코드 수 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"Auth\";"

# 🔶 운영1번 서버(10.164.32.91)에서 PostgreSQL 중지
# docker stop rtt-postgres
echo "🔶 운영1번 서버에서 'docker stop rtt-postgres' 실행 후 계속..."

# 관리서버에서 테스트 - Master 연결 불가 확인
# 🔶 관리서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT 1;" 2>/dev/null || echo "✅ Master 중지됨"

# 2번서버에서 테스트 - Slave 생존 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT 1;"
# 연결 성공: ✅ Slave 정상 동작 / 연결 실패: ❌ Slave도 응답 안함

# 2번서버에서 테스트 - Slave를 Master로 수동 승격
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_promote();"

# 승격 완료 대기 (3초)
echo "승격 대기 중..."
sleep 3

# 2번서버에서 테스트 - 승격 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 'f': ✅ 승격 성공 / 결과 't': ❌ 아직 Recovery 모드

# 2번서버에서 테스트 - 새 Master에서 쓰기 테스트
# 🔶 2번서버에서 실행
FAILOVER_TIMESTAMP=$(date +%s)
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('post_failover_$FAILOVER_TIMESTAMP', 'post_failover_$FAILOVER_TIMESTAMP@example.com', 'hashed_password', NOW(), NOW()) 
RETURNING id;"
# INSERT 성공: ✅ 새 Master 쓰기 성공 / 실패: ❌ 쓰기 실패

# 🔶 운영1번 서버 PostgreSQL 재시작
# docker start rtt-postgres
echo "🔶 운영1번 서버에서 'docker start rtt-postgres' 실행 후 계속..."

# 복구 대기 (5초)
echo "복구 대기 중..."
sleep 5

# 1번서버에서 테스트 - 복구된 서버 상태 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT 1;" && echo "✅ 서버 복구됨"

# 1번서버에서 테스트 - 복구 모드 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 't': ✅ Slave로 전환됨 / 결과 'f': ❌ Master로 복구됨 (Split-brain 위험)

# =============================================================================
# 5. Slave 장애 시뮬레이션 테스트
# =============================================================================

# 현재 Master/Slave 상태 확인
# 🔶 2번서버에서 실행 (현재 Master로 예상)
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"

# 🔶 1번서버에서 실행 (현재 Slave로 예상)
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 각 서버의 'f': Master / 't': Slave

# 🔶 현재 Slave 서버에서 PostgreSQL 중지
# 1번서버가 Slave라면: docker stop rtt-postgres
echo "🔶 현재 Slave 서버에서 'docker stop rtt-postgres' 실행 후 계속..."

# 현재 Master에서 테스트 - Master 지속 동작 확인
# 🔶 현재 Master 서버에서 실행 (2번서버로 예상)
docker exec -it rtt-postgres psql -U postgres -c "SELECT 1;"
# 연결 성공: ✅ Master 정상 동작 / 연결 실패: ❌ Master도 장애

# 현재 Master에서 테스트 - 쓰기 작업 테스트 (3회)
# 🔶 현재 Master 서버에서 실행
SLAVE_FAILURE_TIMESTAMP=$(date +%s)
for i in {1..3}; do
    docker exec -it rtt-postgres psql -U postgres -c "
    INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
    VALUES ('during_slave_failure_${SLAVE_FAILURE_TIMESTAMP}_$i', 'during_slave_failure_${SLAVE_FAILURE_TIMESTAMP}_$i@example.com', 'hashed_password', NOW(), NOW());"
    echo "쓰기 테스트 $i/3 완료"
done
# 모든 INSERT 성공: ✅ Slave 장애 중에도 Master 쓰기 정상

# 🔶 Slave 서버 PostgreSQL 재시작
# docker start rtt-postgres
echo "🔶 Slave 서버에서 'docker start rtt-postgres' 실행 후 계속..."

# Slave 복구 대기 (5초)
echo "Slave 복구 대기 중..."
sleep 5

# Slave 서버에서 테스트 - 복구 모드 확인
# 🔶 복구된 Slave 서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 't': ✅ Slave로 복구됨 / 결과 'f': ❌ Master로 복구됨

# 복제 재연결 확인
# 🔶 현재 Master 서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM pg_stat_replication;"
# 결과 1 이상: ✅ 복제 연결 재설정됨 / 0: ❌ 복제 연결 안됨

# =============================================================================
# 6. 성능 테스트
# =============================================================================

# 현재 Master에서 테스트 - 대량 데이터 삽입 성능 테스트 (1000개)
# 🔶 현재 Master 서버에서 실행
echo "대량 데이터 삽입 테스트 시작..."
docker exec -it rtt-postgres psql -U postgres -c "
BEGIN;
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\")
SELECT 
    'perf_auth_' || generate_series(1, 1000),
    'perf_user_' || generate_series(1, 1000) || '@example.com',
    'hashed_password_' || generate_series(1, 1000),
    NOW(),
    NOW();
COMMIT;"
# INSERT 성공: ✅ 1000개 레코드 삽입 완료 / 실패: ❌ 대량 삽입 실패

# 복제 지연 측정 (마커 레코드 사용)
# 🔶 현재 Master 서버에서 실행
MARKER_TIMESTAMP=$(date +%s%N)
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('sync_marker_$MARKER_TIMESTAMP', 'sync_marker_$MARKER_TIMESTAMP@example.com', 'hashed_password', NOW(), NOW());"

echo "복제 지연 측정 중..."
start_time=$(date +%s)
while true; do
    # 🔶 현재 Slave 서버에서 실행하여 동기화 확인
    count=$(docker exec rtt-postgres psql -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = 'sync_marker_$MARKER_TIMESTAMP@example.com';" 2>/dev/null | tr -d ' ')
    if [ "$count" = "1" ]; then
        end_time=$(date +%s)
        lag=$((end_time - start_time))
        echo "✅ 복제 지연 시간: ${lag}초"
        break
    fi
    sleep 1
    # 10초 타임아웃
    if [ $(($(date +%s) - start_time)) -gt 10 ]; then
        echo "❌ 복제 지연 측정 타임아웃"
        break
    fi
done

# =============================================================================
# 7. 데이터 일관성 최종 확인
# =============================================================================

echo "최종 데이터 일관성 확인 중..."

# 복제 완료 대기 (5초)
sleep 5

# 주요 테이블들의 레코드 수 비교
TABLES=("Auth" "User" "ChatRoom" "AccessLog" "Bookmark")

for table in "${TABLES[@]}"; do
    echo "테이블 $table 동기화 확인 중..."
    
    # 🔶 현재 Master 서버에서 실행
    master_count=$(docker exec rtt-postgres psql -U postgres -t -c "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null | tr -d ' ')
    
    # 🔶 현재 Slave 서버에서 실행  
    slave_count=$(docker exec rtt-postgres psql -U postgres -t -c "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null | tr -d ' ')
    
    if [ "$master_count" = "$slave_count" ]; then
        echo "✅ $table 테이블 동기화 확인 - Master: $master_count, Slave: $slave_count"
    else
        echo "❌ $table 테이블 동기화 불일치 - Master: $master_count, Slave: $slave_count"
    fi
done

# 관계 무결성 확인 (고아 레코드 검사)
# 🔶 현재 Slave 서버에서 실행
orphan_count=$(docker exec rtt-postgres psql -U postgres -t -c "
SELECT COUNT(*) FROM \"User\" u 
LEFT JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.id IS NULL;" 2>/dev/null | tr -d ' ')

if [ "$orphan_count" = "0" ]; then
    echo "✅ 관계 무결성 확인 - 고아 레코드 없음"
else
    echo "❌ 관계 무결성 실패 - $orphan_count개의 고아 레코드 발견"
fi

# 최종 서버 상태 확인
echo "최종 서버 상태:"
# 🔶 1번서버에서 실행
status1=$(docker exec rtt-postgres psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
echo "1번서버: $([ "$status1" = "f" ] && echo "Master" || echo "Slave")"

# 🔶 2번서버에서 실행  
status2=$(docker exec rtt-postgres psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
echo "2번서버: $([ "$status2" = "f" ] && echo "Master" || echo "Slave")"

# =============================================================================
# 8. 운영 서버 장애 시나리오 테스트 (API 및 웹 서비스 포함)
# =============================================================================

# 8-1. 운영1번 서버 전체 장애 (서버 다운)
echo "=== 8-1. 운영1번 서버 전체 장애 테스트 ==="

# 장애 발생 전 상태 확인
# 🔶 관리서버에서 실행
echo "1번서버 서비스 상태 확인 중..."
curl -f "http://10.164.32.91:80" && echo "✅ 웹서비스 정상" || echo "❌ 웹서비스 장애"
curl -f "http://10.164.32.91:8000/api/tests/ip" && echo "✅ API서비스 정상" || echo "❌ API서비스 장애"

# 🔶 물리적 서버 다운 시뮬레이션 (전원 차단 등)
echo "🔶 운영1번 서버 물리적 다운 시뮬레이션 후 계속..."

# 서버 장애 확인
curl -f "http://10.164.32.91:80" && echo "❌ 서버 살아있음" || echo "✅ 웹서비스 다운 확인"
curl -f "http://10.164.32.91:8000/api/tests/ip" && echo "❌ API서비스 살아있음" || echo "✅ API서비스 다운 확인"

# 2번서버 서비스 지속성 확인
curl -f "http://10.164.32.92:80" && echo "✅ 2번서버 웹서비스 정상" || echo "❌ 2번서버 웹서비스 장애"
curl -f "http://10.164.32.92:8000/api/tests/ip" && echo "✅ 2번서버 API서비스 정상" || echo "❌ 2번서버 API서비스 장애"

# 수동 승격 및 서비스 지속성 확인은 위의 4번 섹션과 동일

# 8-2. 운영2번 서버 전체 장애 (서버 다운) - 필요시 동일하게 진행

# 8-3. PostgreSQL DB만 장애 (서버는 정상)
echo "=== 8-3. PostgreSQL DB만 장애 테스트 ==="

# DB 장애 시뮬레이션
# 🔶 해당 서버에서 실행: docker stop rtt-postgres
echo "🔶 PostgreSQL 컨테이너 중지 후 계속..."

# 서버는 정상이지만 API는 실패하는지 확인
curl -f "http://10.164.32.91:80" && echo "✅ 웹서비스 정상 (정적파일)" || echo "❌ 웹서비스 장애"
curl -f "http://10.164.32.91:8000/api/tests/ip" && echo "❌ API서비스 정상 (예상치 못함)" || echo "✅ API서비스 DB 의존성 실패"

# =============================================================================
# 9. 자동 장애조치 스크립트 (별도 파일)
# =============================================================================

echo "자동 장애조치 스크립트는 auto-failover.sh 파일을 참조하세요."
echo "실행 방법: ./auto-failover.sh &"

# =============================================================================
# 테스트 완료
# =============================================================================
echo "🎉 PostgreSQL Master-Slave 테스트 완료"
echo "테스트 항목: 연결확인, 복제상태, 데이터동기화, Master장애, Slave장애, 성능, 일관성, 운영장애시나리오"