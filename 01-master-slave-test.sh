#!/bin/bash
# PostgreSQL Master-Slave 수동 테스트 가이드 (최종 버전)
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

# 복제 사용자 생성
CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicator_password';

# 복제 슬롯 생성
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
SELECT pid, status, receive_start_lsn, 
       last_msg_send_time, last_msg_receipt_time,
       latest_end_lsn, latest_end_time
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
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('test_auth_1671234567', 'sync_test_1671234567@example.com', 'hashed_password_1671234567', NOW(), NOW()) 
RETURNING id;"

# 1번서버에서 테스트 - User 데이터 삽입 (Master에서만 실행)
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"User\" (id, \"authId\", role, language, name, \"createdAt\", \"updatedAt\") 
VALUES ('test_user_1671234567', 'test_auth_1671234567', 'CUSTOMER', 'ko', 'Test User 1671234567', NOW(), NOW()) 
RETURNING id;"

# 동기화 대기 후 Slave에서 데이터 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = 'sync_test_1671234567@example.com';"
# 결과 '1': ✅ 데이터 동기화 됨 / 결과 '0': ❌ 동기화 안됨

# 2번서버에서 테스트 - 관계 데이터 동기화 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT u.id as user_id, u.name, a.\"emailAddress\", u.role
FROM \"User\" u 
JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.\"emailAddress\" = 'sync_test_1671234567@example.com';"

# =============================================================================
# 4. Master 장애 시뮬레이션 테스트
# =============================================================================

# 1번서버에서 테스트 - 장애 전 테스트 데이터 삽입
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('pre_failure_1671234600', 'pre_failure_1671234600@example.com', 'hashed_password', NOW(), NOW());"

# 1번서버에서 테스트 - 장애 전 레코드 수 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"Auth\";"

# 🔶 운영1번 서버(10.164.32.91)에서 PostgreSQL 중지
# docker stop rtt-postgres

# 관리서버에서 테스트 - Master 연결 불가 확인
# 🔶 관리서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT 1;"
# 연결 실패: ✅ Master 중지됨 / 연결 성공: ❌ Master 여전히 실행중

# 2번서버에서 테스트 - Slave 생존 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT 1;"
# 연결 성공: ✅ Slave 정상 동작 / 연결 실패: ❌ Slave도 응답 안함

# 2번서버에서 테스트 - Slave를 Master로 수동 승격
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_promote();"

# 2번서버에서 테스트 - 승격 확인
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 'f': ✅ 승격 성공 / 결과 't': ❌ 아직 Recovery 모드

# 2번서버에서 테스트 - 새 Master에서 쓰기 테스트
# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('post_failover_1671234700', 'post_failover_1671234700@example.com', 'hashed_password', NOW(), NOW()) 
RETURNING id;"
# INSERT 성공: ✅ 새 Master 쓰기 성공 / 실패: ❌ 쓰기 실패

# 🔶 운영1번 서버 PostgreSQL 재시작
# docker start rtt-postgres

# 1번서버에서 테스트 - 복구된 서버 상태 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT 1;"
# 연결 성공: ✅ 서버 복구됨 / 연결 실패: ❌ 서버 복구 안됨

# 1번서버에서 테스트 - 복구 모드 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 't': ✅ Slave로 전환됨 / 결과 'f': ❌ Master로 복구됨 (Split-brain 위험)

# =============================================================================
# 4-1. Split-brain 문제 수동 해결 (두 서버 모두 Master가 된 경우)
# =============================================================================

# 상황: 1번 서버가 재시작되면서 두 서버 모두 Master 모드로 실행되는 경우

# Step 1: 현재 상태 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 확인: 'f' = Master 모드

# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 확인: 'f' = Master 모드

# Step 2: 표준 방법 - Timeline ID 및 WAL 위치 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT 
    pg_control_checkpoint() AS checkpoint_info,
    pg_current_wal_lsn() AS current_wal_lsn,
    pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file;"

# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT 
    pg_control_checkpoint() AS checkpoint_info,
    pg_current_wal_lsn() AS current_wal_lsn,
    pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file;"

# Step 3: 컨트롤 파일 정보 확인 (가장 확실한 방법)
# 🔶 1번서버에서 실행
docker exec rtt-postgres su postgres -c "pg_controldata /var/lib/postgresql/data | grep -E 'Database system identifier|Latest checkpoint location|Latest checkpoint.*timeline|Time of latest checkpoint'"

# 🔶 2번서버에서 실행
docker exec rtt-postgres su postgres -c "pg_controldata /var/lib/postgresql/data | grep -E 'Database system identifier|Latest checkpoint location|Latest checkpoint.*timeline|Time of latest checkpoint'"

# 판단 기준:
# 1. Timeline ID가 더 높은 서버가 우선 (timeline이 다르면 분기됨)
# 2. 같은 timeline이면 LSN이 더 큰 서버가 최신
# 3. 'Time of latest checkpoint'가 더 최근인 서버가 최신

# Step 4: 실제 데이터 트랜잭션 확인
# 🔶 1번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT 
    txid_current() AS current_transaction_id,
    pg_current_wal_lsn() AS wal_position,
    now() AS check_time;"

# 🔶 2번서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
SELECT 
    txid_current() AS current_transaction_id,
    pg_current_wal_lsn() AS wal_position,
    now() AS check_time;"

# 최종 판단 우선순위:
# 1순위: Timeline ID가 높은 서버
# 2순위: 같은 timeline에서 LSN이 큰 서버  
# 3순위: 최근 checkpoint 시간이 더 늦은 서버

# Step 4: 결정 - 2번 서버를 Master로, 1번 서버를 Slave로 설정
# (일반적으로 승격된 2번 서버가 최신 데이터를 가지고 있음)

# 🔶 1번서버에서 실행 - PostgreSQL 중지
docker stop rtt-postgres

# 🔶 1번서버에서 실행 - 기존 데이터 백업
docker exec rtt-postgres bash -c "
if [ -d /var/lib/postgresql/data ]; then
    mv /var/lib/postgresql/data /var/lib/postgresql/data_splitbrain_backup_$(date +%Y%m%d_%H%M%S)
fi
mkdir -p /var/lib/postgresql/data
chown postgres:postgres /var/lib/postgresql/data
"

# 🔶 1번서버에서 실행 - 2번 서버(Master)에서 베이스 백업
docker exec rtt-postgres bash -c "
PGPASSWORD=replicator_password pg_basebackup \\
    -h 10.164.32.92 \\
    -D /var/lib/postgresql/data \\
    -U replicator \\
    -v -P
"

# 🔶 1번서버에서 실행 - Slave 설정
docker exec rtt-postgres bash -c "
# standby.signal 파일 생성
touch /var/lib/postgresql/data/standby.signal

# Slave 복제 설정 추가
cat >> /var/lib/postgresql/data/postgresql.conf << 'EOF'

# Split-brain 복구 - Slave 설정
primary_conninfo = 'host=10.164.32.92 port=5432 user=replicator password=replicator_password application_name=server1_slave'
primary_slot_name = 'slave_slot'
recovery_target_timeline = 'latest'
hot_standby = on
EOF
"

# 🔶 2번서버에서 실행 - 1번 서버용 복제 슬롯 생성 (필요시)
docker exec -it rtt-postgres psql -U postgres -c "
SELECT pg_create_physical_replication_slot('slave_slot');
" 
# 이미 존재하면 ERROR 무시

# 🔶 1번서버에서 실행 - PostgreSQL 재시작
docker start rtt-postgres

# Step 5: Split-brain 해결 확인
# 🔶 1번서버에서 실행 - Slave 모드 확인
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 't': ✅ Slave로 설정됨

# 🔶 2번서버에서 실행 - Master 모드 확인
docker exec -it rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 'f': ✅ Master 유지됨

# 🔶 2번서버에서 실행 - 복제 연결 확인
docker exec -it rtt-postgres psql -U postgres -c "
SELECT application_name, client_addr, state, sync_state 
FROM pg_stat_replication;"
# 1번 서버의 연결이 보이면 ✅ 복제 연결 성공

# Step 6: 데이터 동기화 테스트
# 🔶 2번서버에서 실행 - 테스트 데이터 삽입
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('splitbrain_resolved_$(date +%s)', 'splitbrain_test@example.com', 'test_password', NOW(), NOW());"

# 🔶 1번서버에서 실행 - 동기화 확인 (몇 초 후)
docker exec -it rtt-postgres psql -U postgres -c "
SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = 'splitbrain_test@example.com';"
# 결과 1: ✅ Split-brain 해결 및 동기화 성공

# =============================================================================
# 4-2. 예방책: standby.signal 파일 자동 보호
# =============================================================================

# 1번서버에서 실행 - standby.signal 파일 보호 스크립트 생성
# 🔶 1번서버에서 실행
docker exec rtt-postgres bash -c "
cat > /var/lib/postgresql/data/protect_standby.sh << 'PROTECT_EOF'
#!/bin/bash
# standby.signal 파일 보호 스크립트
SIGNAL_FILE=/var/lib/postgresql/data/standby.signal

# PostgreSQL 시작 전 standby.signal 파일 존재 여부 확인
if [ ! -f \"\$SIGNAL_FILE\" ] && [ -f /var/lib/postgresql/data/was_slave_marker ]; then
    echo \"[$(date)] standby.signal 파일 복구\" >> /var/lib/postgresql/data/postgresql.log
    touch \"\$SIGNAL_FILE\"
fi
PROTECT_EOF

chmod +x /var/lib/postgresql/data/protect_standby.sh

# Slave 마커 파일 생성
touch /var/lib/postgresql/data/was_slave_marker
"

echo "✅ Split-brain 문제 해결 완료"
echo "📋 해결 과정:"
echo "1. 현재 상태 및 데이터 확인"
echo "2. 최신 데이터를 가진 서버를 Master로 선택"
echo "3. 다른 서버를 Slave로 재설정"
echo "4. 베이스 백업 및 복제 설정"
echo "5. 동기화 확인"

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

# 현재 Master에서 테스트 - Master 지속 동작 확인
# 🔶 현재 Master 서버에서 실행 (2번서버로 예상)
docker exec -it rtt-postgres psql -U postgres -c "SELECT 1;"
# 연결 성공: ✅ Master 정상 동작 / 연결 실패: ❌ Master도 장애

# 현재 Master에서 테스트 - 쓰기 작업 테스트 (1회)
# 🔶 현재 Master 서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('during_slave_failure_1671234800_1', 'during_slave_failure_1671234800_1@example.com', 'hashed_password', NOW(), NOW());"

# 현재 Master에서 테스트 - 쓰기 작업 테스트 (2회)
# 🔶 현재 Master 서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('during_slave_failure_1671234800_2', 'during_slave_failure_1671234800_2@example.com', 'hashed_password', NOW(), NOW());"

# 현재 Master에서 테스트 - 쓰기 작업 테스트 (3회)
# 🔶 현재 Master 서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('during_slave_failure_1671234800_3', 'during_slave_failure_1671234800_3@example.com', 'hashed_password', NOW(), NOW());"
# 모든 INSERT 성공: ✅ Slave 장애 중에도 Master 쓰기 정상

# 🔶 Slave 서버 PostgreSQL 재시작
# docker start rtt-postgres

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

# 현재 Master에서 테스트 - 단일 데이터 성능 테스트
# 🔶 현재 Master 서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('perf_single_1671235000', 'perf_single_1671235000@example.com', 'hashed_password', NOW(), NOW()) 
RETURNING id;"
# INSERT 성공: ✅ 단일 레코드 삽입 완료 / 실패: ❌ 삽입 실패

# 복제 지연 측정 (마커 레코드 사용)
# 🔶 현재 Master 서버에서 실행
docker exec -it rtt-postgres psql -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('sync_marker_1671234900', 'sync_marker_1671234900@example.com', 'hashed_password', NOW(), NOW());"

# 🔶 현재 Slave 서버에서 실행하여 동기화 확인 (수동 반복)
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = 'sync_marker_1671234900@example.com';"
# 결과가 1이 될 때까지 반복 실행하여 동기화 시간 측정

# =============================================================================
# 7. 데이터 일관성 최종 확인
# =============================================================================

# Auth 테이블 레코드 수 비교
# 🔶 현재 Master 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"Auth\";"

# 🔶 현재 Slave 서버에서 실행  
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"Auth\";"
# 개수 동일: ✅ Auth 테이블 동기화 확인 / 개수 다름: ❌ 동기화 불일치

# User 테이블 레코드 수 비교
# 🔶 현재 Master 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"User\";"

# 🔶 현재 Slave 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"User\";"
# 개수 동일: ✅ User 테이블 동기화 확인 / 개수 다름: ❌ 동기화 불일치

# ChatRoom 테이블 레코드 수 비교
# 🔶 현재 Master 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"ChatRoom\";"

# 🔶 현재 Slave 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"ChatRoom\";"
# 개수 동일: ✅ ChatRoom 테이블 동기화 확인 / 개수 다름: ❌ 동기화 불일치

# AccessLog 테이블 레코드 수 비교
# 🔶 현재 Master 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"AccessLog\";"

# 🔶 현재 Slave 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"AccessLog\";"
# 개수 동일: ✅ AccessLog 테이블 동기화 확인 / 개수 다름: ❌ 동기화 불일치

# Bookmark 테이블 레코드 수 비교
# 🔶 현재 Master 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"Bookmark\";"

# 🔶 현재 Slave 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT COUNT(*) FROM \"Bookmark\";"
# 개수 동일: ✅ Bookmark 테이블 동기화 확인 / 개수 다름: ❌ 동기화 불일치

# 관계 무결성 확인 (고아 레코드 검사)
# 🔶 현재 Slave 서버에서 실행
docker exec rtt-postgres psql -U postgres -c "
SELECT COUNT(*) FROM \"User\" u 
LEFT JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.id IS NULL;"
# 결과 0: ✅ 관계 무결성 확인 / 결과 0보다 큼: ❌ 고아 레코드 발견

# 최종 서버 상태 확인
# 🔶 1번서버에서 실행
docker exec rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 확인: 'f' = Master, 't' = Slave

# 🔶 2번서버에서 실행  
docker exec rtt-postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# 결과 확인: 'f' = Master, 't' = Slave

# =============================================================================
# 8. 운영 서버 장애 시나리오 테스트 (API 및 웹 서비스 포함)
# =============================================================================

# 8-1. 운영1번 서버 전체 장애 (서버 다운)
# 장애 발생 전 상태 확인
# 🔶 관리서버에서 실행
curl -f "http://10.164.32.91:80"
# 응답: ✅ 웹서비스 정상 / 실패: ❌ 웹서비스 장애

curl -f "http://10.164.32.91:8000/api/tests/ip"
# 응답: ✅ API서비스 정상 / 실패: ❌ API서비스 장애

# 🔶 물리적 서버 다운 시뮬레이션 (전원 차단 등)

# 서버 장애 확인
curl -f "http://10.164.32.91:80"
# 실패: ✅ 웹서비스 다운 확인 / 응답: ❌ 서버 살아있음

curl -f "http://10.164.32.91:8000/api/tests/ip"
# 실패: ✅ API서비스 다운 확인 / 응답: ❌ API서비스 살아있음

# 2번서버 서비스 지속성 확인
curl -f "http://10.164.32.92:80"
# 응답: ✅ 2번서버 웹서비스 정상 / 실패: ❌ 2번서버 웹서비스 장애

curl -f "http://10.164.32.92:8000/api/tests/ip"
# 응답: ✅ 2번서버 API서비스 정상 / 실패: ❌ 2번서버 API서비스 장애

# 8-2. 운영2번 서버 전체 장애 (서버 다운)
# 장애 발생 전 상태 확인
# 🔶 관리서버에서 실행
curl -f "http://10.164.32.92:80"
# 응답: ✅ 웹서비스 정상 / 실패: ❌ 웹서비스 장애

curl -f "http://10.164.32.92:8000/api/tests/ip"
# 응답: ✅ API서비스 정상 / 실패: ❌ API서비스 장애

# 🔶 물리적 서버 다운 시뮬레이션

# 서버 장애 확인
curl -f "http://10.164.32.92:80"
# 실패: ✅ 웹서비스 다운 확인 / 응답: ❌ 서버 살아있음

curl -f "http://10.164.32.92:8000/api/tests/ip"
# 실패: ✅ API서비스 다운 확인 / 응답: ❌ API서비스 살아있음

# 1번서버 서비스 지속성 확인
curl -f "http://10.164.32.91:80"
# 응답: ✅ 1번서버 웹서비스 정상 / 실패: ❌ 1번서버 웹서비스 장애

curl -f "http://10.164.32.91:8000/api/tests/ip"
# 응답: ✅ 1번서버 API서비스 정상 / 실패: ❌ 1번서버 API서비스 장애

# 8-3. PostgreSQL DB만 장애 (서버는 정상)
# DB 장애 시뮬레이션
# 🔶 해당 서버에서 실행: docker stop rtt-postgres

# 서버는 정상이지만 API는 실패하는지 확인
curl -f "http://10.164.32.91:80"
# 응답: ✅ 웹서비스 정상 (정적파일) / 실패: ❌ 웹서비스 장애

curl -f "http://10.164.32.91:8000/api/tests/ip"
# 실패: ✅ API서비스 DB 의존성 실패 / 응답: ❌ API서비스 정상 (예상치 못함)

# 8-4. PostgreSQL DB만 장애 (서버는 정상)
# DB 장애 시뮬레이션
# 🔶 해당 서버에서 실행: docker stop rtt-postgres

# 서버는 정상이지만 API는 실패하는지 확인
curl -f "http://10.164.32.92:80"
# 응답: ✅ 웹서비스 정상 (정적파일) / 실패: ❌ 웹서비스 장애

curl -f "http://10.164.32.92:8000/api/tests/ip"
# 실패: ✅ API서비스 DB 의존성 실패 / 응답: ❌ API서비스 정상 (예상치 못함)

# =============================================================================
# 9. 자동 장애조치 스크립트 (별도 파일)
# =============================================================================

# 자동 장애조치 스크립트는 auto-failover.sh 파일을 참조
# 실행 방법: ./auto-failover.sh &

# =============================================================================
# 테스트 완료
# =============================================================================
# PostgreSQL Master-Slave 테스트 완료
# 테스트 항목: 연결확인, 복제상태, 데이터동기화, Master장애, Slave장애, 성능, 일관성, 운영장애시나리오