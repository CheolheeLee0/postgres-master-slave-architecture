#!/bin/bash
# PostgreSQL Master-Slave 수동 테스트 가이드
# 운영1서버: 10.164.32.91 (Master)
# 운영2서버: 10.164.32.92 (Slave)

# =============================================================================
# 0. Master-Slave 초기 설정 (DB는 기존에 생성되어 있음)
# =============================================================================

# 1번서버에서 실행 - Master 복제 설정
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

# 1번서버에서 실행 - postgresql.conf 설정 (컨테이너 외부에서)
docker exec -it rtt-postgres bash -c "
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
docker exec -it rtt-postgres bash -c "
echo 'host replication replicator 10.164.32.92/32 md5' >> /var/lib/postgresql/data/pg_hba.conf
echo 'host all postgres 10.164.32.92/32 md5' >> /var/lib/postgresql/data/pg_hba.conf
"

# 1번서버에서 실행 - WAL 아카이브 디렉토리 생성
docker exec -it rtt-postgres bash -c "
mkdir -p /var/lib/postgresql/data/pg_wal_archive
chown postgres:postgres /var/lib/postgresql/data/pg_wal_archive
chmod 700 /var/lib/postgresql/data/pg_wal_archive
"

# 1번서버에서 실행 - PostgreSQL 재시작
docker restart rtt-postgres

# 2번서버에서 실행 - Slave 설정 (기존 데이터 백업 후 베이스 백업)
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

# 설정 완료 대기 (10초)


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

# =============================================================================
# 1. 초기 연결 및 상태 확인
# =============================================================================

# 1번서버에서 테스트 - Master 서버 연결 테스트
docker exec -it rtt-postgres bash
su postgres
psql
SELECT version();
\q
exit
exit
# 성공: ✅ Master 연결 성공 / 실패: ❌ Master 연결 실패

# 2번서버에서 테스트 - Slave 서버 연결 테스트
docker exec -it rtt-postgres bash
su postgres
psql
SELECT version();
\q
exit
exit
# 성공: ✅ Slave 연결 성공 / 실패: ❌ Slave 연결 실패

# 1번서버에서 테스트 - Master 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_is_in_recovery();
\q
exit
exit
# 결과 'f': ✅ Master 모드 / 결과 't': ❌ Master 모드 아님

# 2번서버에서 테스트 - Slave 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_is_in_recovery();
\q
exit
exit
# 결과 't': ✅ Slave 모드 / 결과 'f': ❌ Slave 모드 아님

# =============================================================================
# 2. 복제 상태 확인
# =============================================================================

# 1번서버에서 테스트 - 복제 슬롯 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT slot_name, slot_type, active, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
FROM pg_replication_slots;
\q
exit
exit

# 1번서버에서 테스트 - WAL Sender 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pid, usename, application_name, client_addr, state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
FROM pg_stat_replication;
\q
exit
exit

# 2번서버에서 테스트 - WAL Receiver 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pid, status, receive_start_lsn, received_lsn,
       last_msg_send_time, last_msg_receipt_time
FROM pg_stat_wal_receiver;
\q
exit
exit

# =============================================================================
# 3. 데이터 동기화 테스트
# =============================================================================

# 1번서버에서 테스트 - 초기 데이터 개수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Auth";
\q
exit
exit

# 2번서버에서 테스트 - 초기 데이터 개수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Auth";
\q
exit
exit
# 개수 동일: ✅ 초기 데이터 동기화 확인 / 개수 다름: ❌ 동기화 불일치

# 1번서버에서 테스트 - 테스트 데이터 삽입 (Master에서 실행)
docker exec -it rtt-postgres bash
su postgres
psql
INSERT INTO "Auth" (id, "emailAddress", "hashedPassword", "createdAt", "updatedAt") 
VALUES ('test_auth_1640995200', 'sync_test_1640995200@example.com', 'hashed_password_1640995200', NOW(), NOW()) 
RETURNING id;
\q
exit
exit

# 1번서버에서 테스트 - User 데이터 삽입 (Master에서 실행)
docker exec -it rtt-postgres bash
su postgres
psql
INSERT INTO "User" (id, "authId", role, language, name, "createdAt", "updatedAt") 
VALUES ('test_user_1640995200', 'test_auth_1640995200', 'CUSTOMER', 'ko', 'Test User 1640995200', NOW(), NOW()) 
RETURNING id;
\q
exit
exit

# 동기화 대기 (5초)


# 2번서버에서 테스트 - Slave에서 데이터 동기화 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Auth" WHERE "emailAddress" = 'sync_test_1640995200@example.com';
\q
exit
exit
# 결과 '1': ✅ 데이터 동기화 됨 / 결과 '0': ❌ 동기화 안됨

# 2번서버에서 테스트 - 관계 데이터 동기화 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT u.id as user_id, u.name, a."emailAddress", u.role
FROM "User" u 
JOIN "Auth" a ON u."authId" = a.id 
WHERE a."emailAddress" = 'sync_test_1640995200@example.com';
\q
exit
exit

# =============================================================================
# 4. Master 장애 시뮬레이션 테스트
# =============================================================================

# 1번서버에서 테스트 - 장애 전 테스트 데이터 삽입
docker exec -it rtt-postgres bash
su postgres
psql
INSERT INTO "Auth" (id, "emailAddress", "hashedPassword", "createdAt", "updatedAt") 
VALUES ('pre_failure_1640995300', 'pre_failure_1640995300@example.com', 'hashed_password', NOW(), NOW());
\q
exit
exit

# 1번서버에서 테스트 - 장애 전 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Auth";
\q
exit
exit

# 🔶 운영1번 서버(10.164.32.91)에서 실행: sudo systemctl stop postgresql
read -p "Master 중지 후 Enter..."

# 관리서버에서 테스트 - Master 연결 불가 확인
psql -h 10.164.32.91 -U postgres -c "SELECT 1;"
# 연결 실패: ✅ Master 중지됨 / 연결 성공: ❌ Master 여전히 실행중

# 2번서버에서 테스트 - Slave 생존 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT 1;
\q
exit
exit
# 연결 성공: ✅ Slave 정상 동작 / 연결 실패: ❌ Slave도 응답 안함

# 2번서버에서 테스트 - Slave를 Master로 승격
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_promote();
\q
exit
exit

# 승격 완료 대기 (5초)


# 2번서버에서 테스트 - 승격 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_is_in_recovery();
\q
exit
exit
# 결과 'f': ✅ 승격 성공 / 결과 't': ❌ 아직 Recovery 모드

# 2번서버에서 테스트 - 새 Master에서 쓰기 테스트
docker exec -it rtt-postgres bash
su postgres
psql
INSERT INTO "Auth" (id, "emailAddress", "hashedPassword", "createdAt", "updatedAt") 
VALUES ('post_failover_1640995400', 'post_failover_1640995400@example.com', 'hashed_password', NOW(), NOW()) 
RETURNING id;
\q
exit
exit
# INSERT 성공: ✅ 새 Master 쓰기 성공 / 실패: ❌ 쓰기 실패

# 🔶 운영1번 서버(10.164.32.91)에서 실행: sudo systemctl start postgresql
read -p "Master 복구 후 Enter..."

# 원래 Master 복구 대기 (10초)


# 1번서버에서 테스트 - 복구된 서버 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT 1;
\q
exit
exit
# 연결 성공시 다음 명령어 실행:

# 1번서버에서 테스트 - 복구 모드 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_is_in_recovery();
\q
exit
exit
# 결과 't': ✅ Slave로 전환됨 / 결과 'f': ❌ Master로 복구됨 (Split-brain 위험)

# =============================================================================
# 5. Slave 장애 시뮬레이션 테스트
# =============================================================================

# 2번서버에서 테스트 - 현재 Master/Slave 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_is_in_recovery();
\q
exit
exit

# 1번서버에서 테스트 - 현재 Master/Slave 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_is_in_recovery();
\q
exit
exit
# 각 서버의 'f': Master / 't': Slave

# 🔶 운영1번 서버(10.164.32.91)에서 실행: sudo systemctl stop postgresql
read -p "Slave 중지 후 Enter..."

# 관리서버에서 테스트 - Slave 연결 불가 확인
psql -h 10.164.32.91 -U postgres -c "SELECT 1;"
# 연결 실패: ✅ Slave 중지됨 / 연결 성공: ❌ Slave 여전히 실행중

# 2번서버에서 테스트 - Master 생존 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT 1;
\q
exit
exit
# 연결 성공: ✅ Master 정상 동작 / 연결 실패: ❌ Master도 응답 안함

# 2번서버에서 테스트 - Master에서 쓰기 작업 테스트 (1회)
docker exec -it rtt-postgres bash
su postgres
psql
INSERT INTO "Auth" (id, "emailAddress", "hashedPassword", "createdAt", "updatedAt") 
VALUES ('during_slave_failure_1640995500_1', 'during_slave_failure_1640995500_1@example.com', 'hashed_password', NOW(), NOW());
\q
exit
exit

# 2번서버에서 테스트 - Master에서 쓰기 작업 테스트 (2회)
docker exec -it rtt-postgres bash
su postgres
psql
INSERT INTO "Auth" (id, "emailAddress", "hashedPassword", "createdAt", "updatedAt") 
VALUES ('during_slave_failure_1640995500_2', 'during_slave_failure_1640995500_2@example.com', 'hashed_password', NOW(), NOW());
\q
exit
exit

# 2번서버에서 테스트 - Master에서 쓰기 작업 테스트 (3회)
docker exec -it rtt-postgres bash
su postgres
psql
INSERT INTO "Auth" (id, "emailAddress", "hashedPassword", "createdAt", "updatedAt") 
VALUES ('during_slave_failure_1640995500_3', 'during_slave_failure_1640995500_3@example.com', 'hashed_password', NOW(), NOW());
\q
exit
exit
# 모든 INSERT 성공: ✅ Slave 장애 중에도 Master 쓰기 정상

# 🔶 운영1번 서버(10.164.32.91)에서 실행: sudo systemctl start postgresql
read -p "Slave 복구 후 Enter..."

# Slave 복구 대기 (10초)


# 1번서버에서 테스트 - Slave 복구 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT 1;
\q
exit
exit
# 연결 성공시 다음 명령어 실행:

# 1번서버에서 테스트 - Slave 복구 모드 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_is_in_recovery();
\q
exit
exit
# 결과 't': ✅ Slave로 복구됨 / 결과 'f': ❌ Master로 복구됨

# 복제 재연결 확인 (5초 대기)


# 2번서버에서 테스트 - 복제 재연결 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM pg_stat_replication;
\q
exit
exit
# 결과 0보다 큼: ✅ 복제 연결 재설정됨

# 2번서버에서 테스트 - 복제 상태 상세 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT application_name, client_addr, state, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
FROM pg_stat_replication;
\q
exit
exit
# 결과 0: ❌ 복제 연결 재설정 안됨

# =============================================================================
# 6. 성능 테스트
# =============================================================================

# 2번서버에서 테스트 - 대량 데이터 삽입 성능 테스트 (1000개)
docker exec -it rtt-postgres bash
su postgres
psql
BEGIN;
INSERT INTO "Auth" (id, "emailAddress", "hashedPassword", "createdAt", "updatedAt")
SELECT 
    'perf_auth_' || generate_series(1, 1000),
    'perf_user_' || generate_series(1, 1000) || '@example.com',
    'hashed_password_' || generate_series(1, 1000),
    NOW(),
    NOW();
COMMIT;
\q
exit
exit
# INSERT 성공: ✅ 1000개 레코드 삽입 완료 / 실패: ❌ 대량 삽입 실패

# 2번서버에서 테스트 - 복제 지연 측정 (마커 레코드 사용)
docker exec -it rtt-postgres bash
su postgres
psql
INSERT INTO "Auth" (id, "emailAddress", "hashedPassword", "createdAt", "updatedAt") 
VALUES ('sync_marker_1640995600123456789', 'sync_marker_1640995600123456789@example.com', 'hashed_password', NOW(), NOW());
\q
exit
exit

# 1번서버에서 테스트 - Slave에서 마커 레코드 확인 (수동)
# docker exec -it rtt-postgres bash
# su postgres
# psql
# SELECT COUNT(*) FROM "Auth" WHERE "emailAddress" = 'sync_marker_1640995600123456789@example.com';
# \q
# exit
# exit
# 결과가 1이 될 때까지 반복 실행하여 동기화 시간 측정

# =============================================================================
# 7. 데이터 일관성 최종 확인
# =============================================================================

# 복제 완료 대기 (10초)


# 2번서버에서 테스트 - Auth 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Auth";
\q
exit
exit

# 1번서버에서 테스트 - Auth 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Auth";
\q
exit
exit
# 개수 동일: ✅ Auth 테이블 동기화 확인

# 2번서버에서 테스트 - User 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "User";
\q
exit
exit

# 1번서버에서 테스트 - User 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "User";
\q
exit
exit
# 개수 동일: ✅ User 테이블 동기화 확인

# 2번서버에서 테스트 - ChatRoom 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "ChatRoom";
\q
exit
exit

# 1번서버에서 테스트 - ChatRoom 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "ChatRoom";
\q
exit
exit
# 개수 동일: ✅ ChatRoom 테이블 동기화 확인

# 2번서버에서 테스트 - AccessLog 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "AccessLog";
\q
exit
exit

# 1번서버에서 테스트 - AccessLog 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "AccessLog";
\q
exit
exit
# 개수 동일: ✅ AccessLog 테이블 동기화 확인

# 2번서버에서 테스트 - Bookmark 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Bookmark";
\q
exit
exit

# 1번서버에서 테스트 - Bookmark 테이블 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Bookmark";
\q
exit
exit
# 개수 동일: ✅ Bookmark 테이블 동기화 확인

# 1번서버에서 테스트 - 관계 무결성 확인 (고아 레코드 검사)
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "User" u 
LEFT JOIN "Auth" a ON u."authId" = a.id 
WHERE a.id IS NULL;
\q
exit
exit
# 결과 0: ✅ 관계 무결성 확인 / 결과 0보다 큼: ❌ 고아 레코드 발견

# 1번서버에서 테스트 - 최종 서버 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_is_in_recovery();
\q
exit
exit

# 2번서버에서 테스트 - 최종 서버 상태 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT pg_is_in_recovery();
\q
exit
exit
# 각 서버의 'f': Master / 't': Slave

# 2번서버에서 테스트 - 최종 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Auth";
\q
exit
exit

# 1번서버에서 테스트 - 최종 레코드 수 확인
docker exec -it rtt-postgres bash
su postgres
psql
SELECT COUNT(*) FROM "Auth";
\q
exit
exit
# 각 서버의 Auth 레코드 수를 확인하여 동기화 상태 점검

# =============================================================================
# 테스트 완료
# =============================================================================
# PostgreSQL Master-Slave 테스트 완료
# 테스트 항목: 연결확인, 복제상태, 데이터동기화, Master장애, Slave장애, 성능, 일관성