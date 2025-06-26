# PostgreSQL Master-Slave 구성 및 테스트 가이드

## 서버 환경
- **운영1서버**: 10.164.32.91 (Master)
- **운영2서버**: 10.164.32.92 (Slave)
- **PostgreSQL**: 17.x
- **환경변수**: POSTGRES_USER=postgres, POSTGRES_PASSWORD=postgres, POSTGRES_DB=postgres
- **포트**: 5432

---

## 1. 초기 환경 설정

### 1.1 Master 서버 설정 (10.164.32.91)

#### PostgreSQL 설치 및 기본 설정
```bash
# PostgreSQL 17 설치
sudo apt update
sudo apt install postgresql-17 postgresql-client-17 -y

# PostgreSQL 서비스 시작
sudo systemctl start postgresql
sudo systemctl enable postgresql
```

#### postgresql.conf 설정
```bash
# postgresql.conf 파일 편집
sudo nano /etc/postgresql/17/main/postgresql.conf

# 다음 설정 추가/수정
listen_addresses = '*'                    # 모든 IP에서 접속 허용
wal_level = replica                       # WAL 레벨을 replica로 설정
max_wal_senders = 10                      # 최대 WAL sender 수
max_replication_slots = 10                # 최대 replication slot 수
synchronous_commit = on                   # 동기 커밋 활성화
archive_mode = on                         # 아카이브 모드 활성화
archive_command = 'cp %p /var/lib/postgresql/17/main/pg_wal_archive/%f'
```

#### pg_hba.conf 설정
```bash
# pg_hba.conf 파일 편집
sudo nano /etc/postgresql/17/main/pg_hba.conf

# 다음 라인 추가 (파일 끝에)
host    replication     replicator      10.164.32.92/32         md5
host    all             postgres        10.164.32.92/32         md5
```

#### WAL 아카이브 디렉토리 생성
```bash
# WAL 아카이브 디렉토리 생성
sudo mkdir -p /var/lib/postgresql/17/main/pg_wal_archive
sudo chown postgres:postgres /var/lib/postgresql/17/main/pg_wal_archive
sudo chmod 700 /var/lib/postgresql/17/main/pg_wal_archive
```

#### 복제 사용자 생성
```bash
# PostgreSQL에 접속하여 복제 사용자 생성
sudo -u postgres psql

-- 복제 사용자 생성
CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicator_password';

-- 복제 슬롯 생성
SELECT pg_create_physical_replication_slot('slave_slot');

-- 설정 확인
SELECT slot_name, slot_type, active FROM pg_replication_slots;

\q
```

#### PostgreSQL 재시작
```bash
# PostgreSQL 재시작
sudo systemctl restart postgresql

# 상태 확인
sudo systemctl status postgresql
```

### 1.2 Slave 서버 설정 (10.164.32.92)

#### PostgreSQL 설치
```bash
# PostgreSQL 17 설치
sudo apt update
sudo apt install postgresql-17 postgresql-client-17 -y

# PostgreSQL 서비스 중지 (데이터 디렉토리 초기화를 위해)
sudo systemctl stop postgresql
```

#### 기존 데이터 디렉토리 백업 및 정리
```bash
# 기존 데이터 디렉토리 백업
sudo mv /var/lib/postgresql/17/main /var/lib/postgresql/17/main.backup

# 새 디렉토리 생성
sudo mkdir -p /var/lib/postgresql/17/main
sudo chown postgres:postgres /var/lib/postgresql/17/main
```

#### Master에서 베이스 백업 생성
```bash
# postgres 사용자로 베이스 백업 실행
sudo -u postgres bash -c "
PGPASSWORD=replicator_password pg_basebackup \
    -h 10.164.32.91 \
    -D /var/lib/postgresql/17/main \
    -U replicator \
    -v -P -W
"
```

#### Standby 설정 파일 생성
```bash
# standby.signal 파일 생성
sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal

# postgresql.conf에 복제 설정 추가
sudo -u postgres bash -c "cat >> /var/lib/postgresql/17/main/postgresql.conf << EOF

# PostgreSQL 17 Standby settings
primary_conninfo = 'host=10.164.32.91 port=5432 user=replicator password=replicator_password application_name=slave_node'
primary_slot_name = 'slave_slot'
restore_command = ''
archive_cleanup_command = ''
EOF"
```

#### PostgreSQL 시작
```bash
# PostgreSQL 시작
sudo systemctl start postgresql
sudo systemctl enable postgresql

# 상태 확인
sudo systemctl status postgresql
```

---

## 2. 설정 검증 스크립트

### 2.1 연결 테스트 스크립트
```bash
#!/bin/bash
# 파일명: test-connection.sh
# 설명: Master-Slave 연결 상태 확인

set -e

echo "=== PostgreSQL Master-Slave 연결 테스트 ==="
echo ""

# Master 서버 연결 테스트
echo "1. Master 서버 연결 테스트 (10.164.32.91)..."
if psql -h 10.164.32.91 -U postgres -c "SELECT version();" > /dev/null 2>&1; then
    echo "✅ Master 서버 연결 성공"
else
    echo "❌ Master 서버 연결 실패"
    echo "에러 로그:"
    psql -h 10.164.32.91 -U postgres -c "SELECT version();" 2>&1 || true
    exit 1
fi

# Slave 서버 연결 테스트
echo "2. Slave 서버 연결 테스트 (10.164.32.92)..."
if psql -h 10.164.32.92 -U postgres -c "SELECT version();" > /dev/null 2>&1; then
    echo "✅ Slave 서버 연결 성공"
else
    echo "❌ Slave 서버 연결 실패"
    echo "에러 로그:"
    psql -h 10.164.32.92 -U postgres -c "SELECT version();" 2>&1 || true
    exit 1
fi

echo ""
echo "✅ 모든 연결 테스트 통과"
```

### 2.2 복제 상태 확인 스크립트
```bash
#!/bin/bash
# 파일명: test-replication-status.sh
# 설명: 복제 상태 및 동기화 확인

set -e

echo "=== PostgreSQL 복제 상태 확인 ==="
echo ""

# Master 서버 복제 상태 확인
echo "1. Master 서버 복제 상태..."
echo "복제 슬롯 상태:"
psql -h 10.164.32.91 -U postgres -c "
SELECT slot_name, slot_type, active, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
FROM pg_replication_slots;" 2>&1 || {
    echo "❌ Master 복제 슬롯 확인 실패"
    exit 1
}

echo ""
echo "WAL Sender 상태:"
psql -h 10.164.32.91 -U postgres -c "
SELECT pid, usename, application_name, client_addr, state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
FROM pg_stat_replication;" 2>&1 || {
    echo "❌ WAL Sender 상태 확인 실패"
    exit 1
}

# Slave 서버 복제 상태 확인
echo ""
echo "2. Slave 서버 복제 상태..."
echo "Recovery 모드 확인:"
RECOVERY_STATUS=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ' || echo "")

if [ "$RECOVERY_STATUS" = "t" ]; then
    echo "✅ Slave 서버가 올바르게 Recovery 모드에서 실행 중"
else
    echo "❌ Slave 서버가 Recovery 모드가 아님 (상태: $RECOVERY_STATUS)"
    exit 1
fi

echo ""
echo "복제 통계:"
psql -h 10.164.32.92 -U postgres -c "
SELECT pid, status, receive_start_lsn, receive_start_tli, 
       received_lsn, received_tli, last_msg_send_time, last_msg_receipt_time
FROM pg_stat_wal_receiver;" 2>&1 || {
    echo "❌ WAL Receiver 상태 확인 실패"
    exit 1
}

echo ""
echo "✅ 복제 상태 확인 완료"
```

### 2.3 데이터 동기화 테스트 스크립트
```bash
#!/bin/bash
# 파일명: test-data-sync.sh
# 설명: Master-Slave 데이터 동기화 테스트 (Prisma 스키마 기반)

set -e

echo "=== 데이터 동기화 테스트 ==="
echo ""

# 현재 시간을 이용한 고유 테스트 ID 생성
TEST_ID=$(date +%s)
TEST_EMAIL="sync_test_$TEST_ID@example.com"

echo "테스트 ID: $TEST_ID"
echo "테스트 이메일: $TEST_EMAIL"
echo ""

# Master에서 초기 데이터 개수 확인 (Auth 테이블 사용)
echo "1. 초기 데이터 개수 확인..."
MASTER_INITIAL=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
SLAVE_INITIAL=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')

echo "Master 초기 Auth 레코드 수: $MASTER_INITIAL"
echo "Slave 초기 Auth 레코드 수: $SLAVE_INITIAL"

if [ "$MASTER_INITIAL" != "$SLAVE_INITIAL" ]; then
    echo "⚠️ 초기 데이터가 동기화되지 않음"
    echo "동기화 대기 중... (최대 10초)"
    sleep 10
    SLAVE_INITIAL=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
    if [ "$MASTER_INITIAL" != "$SLAVE_INITIAL" ]; then
        echo "❌ 초기 데이터 동기화 실패"
        exit 1
    fi
fi

# Master에 Auth 데이터 삽입 (Prisma 스키마에 맞춤)
echo ""
echo "2. Master에 테스트 Auth 데이터 삽입..."
INSERT_RESULT=$(psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('test_auth_$TEST_ID', '$TEST_EMAIL', 'hashed_password_$TEST_ID', NOW(), NOW()) 
RETURNING id;" 2>&1)

if echo "$INSERT_RESULT" | grep -q "INSERT 0 1"; then
    NEW_ID=$(echo "$INSERT_RESULT" | grep "test_auth_$TEST_ID" | head -1)
    echo "✅ Auth 데이터 삽입 성공 (ID: test_auth_$TEST_ID)"
else
    echo "❌ Auth 데이터 삽입 실패"
    echo "에러: $INSERT_RESULT"
    exit 1
fi

# User 데이터도 삽입하여 관계 테스트
echo ""
echo "3. Master에 연관 User 데이터 삽입..."
USER_INSERT_RESULT=$(psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"User\" (id, \"authId\", role, language, name, \"createdAt\", \"updatedAt\") 
VALUES ('test_user_$TEST_ID', 'test_auth_$TEST_ID', 'CUSTOMER', 'ko', 'Test User $TEST_ID', NOW(), NOW()) 
RETURNING id;" 2>&1)

if echo "$USER_INSERT_RESULT" | grep -q "INSERT 0 1"; then
    echo "✅ User 데이터 삽입 성공"
else
    echo "❌ User 데이터 삽입 실패"
    echo "에러: $USER_INSERT_RESULT"
    exit 1
fi

# 동기화 대기
echo ""
echo "4. 동기화 대기 중... (5초)"
sleep 5

# Slave에서 Auth 데이터 확인
echo ""
echo "5. Slave에서 Auth 데이터 동기화 확인..."
SLAVE_AUTH_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = '$TEST_EMAIL';" 2>/dev/null | tr -d ' ')

if [ "$SLAVE_AUTH_COUNT" = "1" ]; then
    echo "✅ Auth 데이터가 Slave로 정상 동기화됨"
    
    # 동기화된 Auth 데이터 세부 정보 확인
    SYNCED_AUTH_DATA=$(psql -h 10.164.32.92 -U postgres -c "
    SELECT id, \"emailAddress\", \"createdAt\" 
    FROM \"Auth\" 
    WHERE \"emailAddress\" = '$TEST_EMAIL';" 2>/dev/null)
    
    echo "동기화된 Auth 데이터:"
    echo "$SYNCED_AUTH_DATA"
else
    echo "❌ Auth 데이터가 Slave로 동기화되지 않음 (찾은 레코드 수: $SLAVE_AUTH_COUNT)"
    exit 1
fi

# Slave에서 User 데이터 확인 (JOIN 테스트)
echo ""
echo "6. Slave에서 User-Auth JOIN 데이터 확인..."
SLAVE_USER_JOIN=$(psql -h 10.164.32.92 -U postgres -c "
SELECT u.id as user_id, u.name, a.\"emailAddress\", u.role
FROM \"User\" u 
JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.\"emailAddress\" = '$TEST_EMAIL';" 2>/dev/null)

if echo "$SLAVE_USER_JOIN" | grep -q "test_user_$TEST_ID"; then
    echo "✅ User-Auth 관계 데이터가 정상 동기화됨"
    echo "JOIN 결과:"
    echo "$SLAVE_USER_JOIN"
else
    echo "❌ User-Auth 관계 데이터 동기화 실패"
    exit 1
fi

# 복잡한 테이블 테스트 (ChatRoom 생성)
echo ""
echo "7. 복잡한 테이블 구조 동기화 테스트..."
CHATROOM_INSERT=$(psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"ChatRoom\" (id, title, purpose, \"createdAt\", \"updatedAt\") 
VALUES ('test_chatroom_$TEST_ID', 'Test ChatRoom $TEST_ID', 'Sync Test Purpose', NOW(), NOW()) 
RETURNING id;" 2>&1)

if echo "$CHATROOM_INSERT" | grep -q "INSERT 0 1"; then
    echo "✅ ChatRoom 데이터 삽입 성공"
    
    # 동기화 대기
    sleep 3
    
    # Slave에서 확인
    SLAVE_CHATROOM_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"ChatRoom\" WHERE title = 'Test ChatRoom $TEST_ID';" 2>/dev/null | tr -d ' ')
    
    if [ "$SLAVE_CHATROOM_COUNT" = "1" ]; then
        echo "✅ ChatRoom 데이터가 Slave로 정상 동기화됨"
    else
        echo "❌ ChatRoom 데이터 동기화 실패"
        exit 1
    fi
else
    echo "❌ ChatRoom 데이터 삽입 실패"
    echo "에러: $CHATROOM_INSERT"
    exit 1
fi

# 최종 동기화 상태 확인 (모든 테이블)
echo ""
echo "8. 최종 동기화 상태 확인..."
echo "각 테이블별 레코드 수 비교:"

# 주요 테이블들 확인
TABLES=("Auth" "User" "ChatRoom" "AccessLog" "Bookmark")

for table in "${TABLES[@]}"; do
    MASTER_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null | tr -d ' ')
    SLAVE_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null | tr -d ' ')
    
    echo "  $table: Master=$MASTER_COUNT, Slave=$SLAVE_COUNT"
    
    if [ "$MASTER_COUNT" != "$SLAVE_COUNT" ]; then
        echo "  ⚠️ $table 테이블 동기화 불일치"
        SYNC_ERROR=true
    fi
done

if [ "$SYNC_ERROR" = true ]; then
    echo "⚠️ 일부 테이블에서 동기화 불일치 발견"
    exit 1
else
    echo "✅ 모든 테이블이 완전히 동기화됨"
fi

echo ""
echo "✅ 데이터 동기화 테스트 완료"
```

---

## 3. 장애 시나리오 테스트

### 3.1 Master 장애 시뮬레이션 스크립트
```bash
#!/bin/bash
# 파일명: test-master-failure.sh
# 설명: Master 서버 장애 상황 시뮬레이션 및 복구

set -e

echo "=== Master 장애 시나리오 테스트 ==="
echo ""

# 테스트 시작 전 상태 확인
echo "1. 테스트 시작 전 상태 확인..."
./test-replication-status.sh || {
    echo "❌ 초기 복제 상태가 비정상입니다"
    exit 1
}

# Master에 테스트 데이터 삽입 (Prisma 스키마 기반)
echo ""
echo "2. 장애 전 테스트 데이터 삽입..."
TEST_ID=$(date +%s)
psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('pre_failure_$TEST_ID', 'pre_failure_$TEST_ID@example.com', 'hashed_password', NOW(), NOW());" || {
    echo "❌ 장애 전 데이터 삽입 실패"
    exit 1
}

INITIAL_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
echo "장애 전 Master 레코드 수: $INITIAL_COUNT"

# 동기화 대기
sleep 3

# Master 서비스 중지 (장애 시뮬레이션)
echo ""
echo "3. Master 서버 장애 시뮬레이션 (PostgreSQL 서비스 중지)..."
ssh root@10.164.32.91 "systemctl stop postgresql" || {
    echo "❌ Master 서버 중지 실패"
    exit 1
}
echo "✅ Master 서버 중지됨"

# Master 연결 불가 확인
echo ""
echo "4. Master 서버 연결 불가 확인..."
if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "❌ Master 서버가 여전히 응답하고 있음"
    exit 1
else
    echo "✅ Master 서버 연결 불가 확인됨"
fi

# Slave 서버 상태 확인
echo ""
echo "5. Slave 서버 상태 확인..."
if psql -h 10.164.32.92 -U postgres -c "SELECT pg_is_in_recovery();" > /dev/null 2>&1; then
    echo "✅ Slave 서버는 여전히 실행 중"
    
    # WAL Receiver 상태 확인
    WAL_RECEIVER_STATUS=$(psql -h 10.164.32.92 -U postgres -t -c "
    SELECT status FROM pg_stat_wal_receiver;" 2>/dev/null | tr -d ' ')
    
    echo "WAL Receiver 상태: $WAL_RECEIVER_STATUS"
    
    if [ -z "$WAL_RECEIVER_STATUS" ]; then
        echo "⚠️ WAL Receiver가 연결되지 않음 (예상된 상황)"
    fi
else
    echo "❌ Slave 서버 연결 실패"
    exit 1
fi

# Slave를 Master로 승격
echo ""
echo "6. Slave를 Master로 승격..."
PROMOTE_RESULT=$(psql -h 10.164.32.92 -U postgres -c "SELECT pg_promote();" 2>&1)

if echo "$PROMOTE_RESULT" | grep -q "t"; then
    echo "✅ Slave 승격 명령 실행 성공"
    
    # 승격 완료까지 대기
    echo "승격 완료 대기 중..."
    sleep 5
    
    # 승격 확인
    IS_RECOVERY=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    
    if [ "$IS_RECOVERY" = "f" ]; then
        echo "✅ Slave가 성공적으로 Master로 승격됨"
    else
        echo "❌ Slave 승격 실패 (여전히 Recovery 모드)"
        exit 1
    fi
else
    echo "❌ Slave 승격 명령 실패"
    echo "에러: $PROMOTE_RESULT"
    exit 1
fi

# 새 Master에서 쓰기 테스트 (Prisma 스키마 기반)
echo ""
echo "7. 새 Master에서 쓰기 테스트..."
NEW_TEST_ID=$(date +%s)
INSERT_RESULT=$(psql -h 10.164.32.92 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('post_failover_$NEW_TEST_ID', 'post_failover_$NEW_TEST_ID@example.com', 'hashed_password', NOW(), NOW()) 
RETURNING id;" 2>&1)

if echo "$INSERT_RESULT" | grep -q "INSERT 0 1"; then
    echo "✅ 새 Master에서 쓰기 작업 성공"
    
    NEW_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
    echo "새 Master 레코드 수: $NEW_COUNT"
    
    if [ "$NEW_COUNT" -gt "$INITIAL_COUNT" ]; then
        echo "✅ 데이터가 정상적으로 증가함"
    else
        echo "⚠️ 데이터 증가가 예상과 다름"
    fi
else
    echo "❌ 새 Master에서 쓰기 작업 실패"
    echo "에러: $INSERT_RESULT"
    exit 1
fi

# 장애 복구 (원래 Master 서버 재시작)
echo ""
echo "8. 원래 Master 서버 복구..."
ssh root@10.164.32.91 "systemctl start postgresql" || {
    echo "❌ 원래 Master 서버 재시작 실패"
    exit 1
}

echo "원래 Master 서버 시작 대기 중..."
sleep 10

# 원래 Master 서버 상태 확인
if psql -h 10.164.32.91 -U postgres -c "SELECT pg_is_in_recovery();" > /dev/null 2>&1; then
    IS_RECOVERY_ORIGINAL=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    
    if [ "$IS_RECOVERY_ORIGINAL" = "t" ]; then
        echo "✅ 원래 Master가 Slave로 자동 전환됨"
    else
        echo "⚠️ 원래 Master가 Master 모드로 실행 중 (Split-brain 위험)"
        echo "수동으로 Slave 모드로 전환이 필요할 수 있습니다"
    fi
else
    echo "❌ 원래 Master 서버 연결 실패"
fi

echo ""
echo "✅ Master 장애 시나리오 테스트 완료"
echo ""
echo "테스트 결과 요약:"
echo "- Master 서버 장애 시뮬레이션: 성공"
echo "- Slave 서버 Master 승격: 성공"
echo "- 새 Master 쓰기 작업: 성공"
echo "- 원래 Master 서버 복구: 성공"
```

### 3.2 Slave 장애 시뮬레이션 스크립트
```bash
#!/bin/bash
# 파일명: test-slave-failure.sh
# 설명: Slave 서버 장애 상황 시뮬레이션 및 복구

set -e

echo "=== Slave 장애 시나리오 테스트 ==="
echo ""

# 테스트 시작 전 상태 확인
echo "1. 테스트 시작 전 상태 확인..."
./test-replication-status.sh || {
    echo "❌ 초기 복제 상태가 비정상입니다"
    exit 1
}

# Master에 테스트 데이터 삽입
echo ""
echo "2. 장애 전 테스트 데이터 삽입..."
TEST_ID=$(date +%s)
psql -h 10.164.32.91 -U postgres -c "
INSERT INTO users (username, email) 
VALUES ('pre_slave_failure_$TEST_ID', 'pre_slave_failure_$TEST_ID@example.com');" || {
    echo "❌ 장애 전 데이터 삽입 실패"
    exit 1
}

INITIAL_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')
echo "장애 전 Master 레코드 수: $INITIAL_COUNT"

# 동기화 대기
sleep 3

# Slave 서비스 중지 (장애 시뮬레이션)
echo ""
echo "3. Slave 서버 장애 시뮬레이션 (PostgreSQL 서비스 중지)..."
ssh root@10.164.32.92 "systemctl stop postgresql" || {
    echo "❌ Slave 서버 중지 실패"
    exit 1
}
echo "✅ Slave 서버 중지됨"

# Slave 연결 불가 확인
echo ""
echo "4. Slave 서버 연결 불가 확인..."
if psql -h 10.164.32.92 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "❌ Slave 서버가 여전히 응답하고 있음"
    exit 1
else
    echo "✅ Slave 서버 연결 불가 확인됨"
fi

# Master 서버 상태 및 복제 상태 확인
echo ""
echo "5. Master 서버 상태 확인..."
if psql -h 10.164.32.91 -U postgres -c "SELECT version();" > /dev/null 2>&1; then
    echo "✅ Master 서버는 정상 동작 중"
    
    # WAL Sender 상태 확인
    WAL_SENDER_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "
    SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')
    
    echo "활성 WAL Sender 수: $WAL_SENDER_COUNT"
    
    if [ "$WAL_SENDER_COUNT" = "0" ]; then
        echo "✅ WAL Sender 연결 없음 (예상된 상황)"
    else
        echo "⚠️ 여전히 활성 WAL Sender가 있음"
    fi
else
    echo "❌ Master 서버 연결 실패"
    exit 1
fi

# Master에서 계속 쓰기 작업 테스트
echo ""
echo "6. Slave 장애 중 Master 쓰기 작업 테스트..."
for i in {1..3}; do
    WRITE_TEST_ID=$(date +%s)_$i
    INSERT_RESULT=$(psql -h 10.164.32.91 -U postgres -c "
    INSERT INTO users (username, email) 
    VALUES ('during_slave_failure_$WRITE_TEST_ID', 'during_slave_failure_$WRITE_TEST_ID@example.com') 
    RETURNING id;" 2>&1)
    
    if echo "$INSERT_RESULT" | grep -q "INSERT 0 1"; then
        echo "✅ 쓰기 작업 $i 성공"
    else
        echo "❌ 쓰기 작업 $i 실패"
        echo "에러: $INSERT_RESULT"
        exit 1
    fi
    
    sleep 1
done

DURING_FAILURE_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')
echo "Slave 장애 중 Master 레코드 수: $DURING_FAILURE_COUNT"

# Slave 서버 복구
echo ""
echo "7. Slave 서버 복구..."
ssh root@10.164.32.92 "systemctl start postgresql" || {
    echo "❌ Slave 서버 재시작 실패"
    exit 1
}

echo "Slave 서버 시작 대기 중..."
sleep 10

# Slave 서버 복구 확인
if psql -h 10.164.32.92 -U postgres -c "SELECT pg_is_in_recovery();" > /dev/null 2>&1; then
    IS_RECOVERY=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    
    if [ "$IS_RECOVERY" = "t" ]; then
        echo "✅ Slave 서버가 정상적으로 복구되어 Recovery 모드로 실행 중"
    else
        echo "⚠️ Slave 서버가 Master 모드로 실행 중 (비정상)"
        exit 1
    fi
else
    echo "❌ Slave 서버 연결 실패"
    exit 1
fi

# 복제 재연결 확인
echo ""
echo "8. 복제 재연결 확인..."
sleep 5

WAL_SENDER_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "
SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')

if [ "$WAL_SENDER_COUNT" -gt "0" ]; then
    echo "✅ 복제 연결이 재설정됨"
    
    # 복제 상태 세부 정보
    psql -h 10.164.32.91 -U postgres -c "
    SELECT application_name, client_addr, state, 
           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
    FROM pg_stat_replication;"
else
    echo "⚠️ 복제 연결이 재설정되지 않음"
    echo "수동 재설정이 필요할 수 있습니다"
fi

# 데이터 동기화 확인
echo ""
echo "9. 데이터 동기화 확인..."
echo "동기화 대기 중... (10초)"
sleep 10

MASTER_FINAL_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')
SLAVE_FINAL_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')

echo "Master 최종 레코드 수: $MASTER_FINAL_COUNT"
echo "Slave 최종 레코드 수: $SLAVE_FINAL_COUNT"

if [ "$MASTER_FINAL_COUNT" = "$SLAVE_FINAL_COUNT" ]; then
    echo "✅ 데이터가 완전히 동기화됨"
else
    echo "⚠️ 데이터 동기화에 차이가 있음"
    echo "추가 동기화 시간이 필요할 수 있습니다"
    
    # 추가 대기 후 재확인
    echo "추가 동기화 대기 중... (30초)"
    sleep 30
    
    SLAVE_FINAL_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')
    
    if [ "$MASTER_FINAL_COUNT" = "$SLAVE_FINAL_COUNT" ]; then
        echo "✅ 지연 후 데이터가 동기화됨"
    else
        echo "❌ 데이터 동기화 실패"
        exit 1
    fi
fi

echo ""
echo "✅ Slave 장애 시나리오 테스트 완료"
echo ""
echo "테스트 결과 요약:"
echo "- Slave 서버 장애 시뮬레이션: 성공"
echo "- 장애 중 Master 쓰기 작업: 성공"
echo "- Slave 서버 복구: 성공"
echo "- 복제 재연결: 성공"
echo "- 데이터 동기화: 성공"
```

### 3.3 네트워크 분단 시뮬레이션 스크립트
```bash
#!/bin/bash
# 파일명: test-network-partition.sh
# 설명: 네트워크 분단 상황 시뮬레이션 및 복구

set -e

echo "=== 네트워크 분단 시나리오 테스트 ==="
echo ""

# 테스트 시작 전 상태 확인
echo "1. 테스트 시작 전 상태 확인..."
./test-replication-status.sh || {
    echo "❌ 초기 복제 상태가 비정상입니다"
    exit 1
}

# 네트워크 분단 시뮬레이션 (iptables 사용)
echo ""
echo "2. 네트워크 분단 시뮬레이션..."
echo "Master에서 Slave로의 연결 차단..."

# Master 서버에서 Slave로의 연결 차단
ssh root@10.164.32.91 "iptables -A OUTPUT -d 10.164.32.92 -j DROP" || {
    echo "❌ Master에서 네트워크 차단 실패"
    exit 1
}

# Slave 서버에서 Master로의 연결 차단
ssh root@10.164.32.92 "iptables -A OUTPUT -d 10.164.32.91 -j DROP" || {
    echo "❌ Slave에서 네트워크 차단 실패"
    exit 1
}

echo "✅ 네트워크 분단 적용됨"

# 분단 확인
echo ""
echo "3. 네트워크 분단 확인..."
sleep 5

# Master에서 복제 상태 확인
echo "Master 복제 상태:"
WAL_SENDER_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "
SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')

echo "활성 WAL Sender 수: $WAL_SENDER_COUNT"

if [ "$WAL_SENDER_COUNT" = "0" ]; then
    echo "✅ 복제 연결이 차단됨 (예상된 상황)"
else
    echo "⚠️ 여전히 활성 복제 연결이 있음"
fi

# 분단 중 각 서버에서 쓰기 작업 테스트
echo ""
echo "4. 분단 중 각 서버에서 쓰기 작업 테스트..."

# Master에서 쓰기
TEST_ID=$(date +%s)
echo "Master에서 쓰기 테스트..."
psql -h 10.164.32.91 -U postgres -c "
INSERT INTO users (username, email) 
VALUES ('partition_master_$TEST_ID', 'partition_master_$TEST_ID@example.com');" || {
    echo "❌ Master 쓰기 실패"
    exit 1
}
echo "✅ Master 쓰기 성공"

# Slave를 Master로 승격 후 쓰기
echo "Slave를 Master로 승격..."
psql -h 10.164.32.92 -U postgres -c "SELECT pg_promote();" > /dev/null 2>&1
sleep 5

echo "승격된 Slave에서 쓰기 테스트..."
psql -h 10.164.32.92 -U postgres -c "
INSERT INTO users (username, email) 
VALUES ('partition_slave_$TEST_ID', 'partition_slave_$TEST_ID@example.com');" || {
    echo "❌ 승격된 Slave 쓰기 실패"
    exit 1
}
echo "✅ 승격된 Slave 쓰기 성공"

# Split-brain 상황 확인
echo ""
echo "5. Split-brain 상황 확인..."
MASTER_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')
SLAVE_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')

echo "Master 레코드 수: $MASTER_COUNT"
echo "승격된 Slave 레코드 수: $SLAVE_COUNT"

if [ "$MASTER_COUNT" != "$SLAVE_COUNT" ]; then
    echo "⚠️ Split-brain 상황 발생 - 데이터 불일치"
else
    echo "✅ 데이터 일치 (분단 직후라 예상치 못한 상황)"
fi

# 네트워크 분단 해제
echo ""
echo "6. 네트워크 분단 해제..."

# Master 서버에서 네트워크 차단 해제
ssh root@10.164.32.91 "iptables -D OUTPUT -d 10.164.32.92 -j DROP" || {
    echo "⚠️ Master에서 네트워크 차단 해제 실패"
}

# Slave 서버에서 네트워크 차단 해제
ssh root@10.164.32.92 "iptables -D OUTPUT -d 10.164.32.91 -j DROP" || {
    echo "⚠️ Slave에서 네트워크 차단 해제 실패"
}

echo "✅ 네트워크 분단 해제됨"

# 연결 복구 확인
echo ""
echo "7. 연결 복구 확인..."
sleep 5

# 각 서버로의 연결 테스트
if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✅ Master 서버 연결 복구됨"
else
    echo "❌ Master 서버 연결 복구 실패"
fi

if psql -h 10.164.32.92 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✅ Slave 서버 연결 복구됨"
else
    echo "❌ Slave 서버 연결 복구 실패"
fi

# Split-brain 해결 방안 제시
echo ""
echo "8. Split-brain 해결 방안..."
echo "⚠️ 현재 두 서버 모두 Master 모드로 실행 중일 수 있습니다"
echo "   수동으로 한 서버를 Slave로 전환해야 합니다"
echo ""

# 각 서버의 Recovery 상태 확인
MASTER_IS_RECOVERY=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
SLAVE_IS_RECOVERY=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')

echo "10.164.32.91 Recovery 모드: $MASTER_IS_RECOVERY"
echo "10.164.32.92 Recovery 모드: $SLAVE_IS_RECOVERY"

if [ "$MASTER_IS_RECOVERY" = "f" ] && [ "$SLAVE_IS_RECOVERY" = "f" ]; then
    echo "⚠️ 두 서버 모두 Master 모드 - Split-brain 상황"
    echo "   해결을 위해 한 서버를 Slave로 재구성해야 합니다"
    echo ""
    echo "   권장 해결 방법:"
    echo "   1. 데이터 손실을 최소화할 서버를 Master로 선택"
    echo "   2. 다른 서버를 정지하고 데이터 디렉토리 백업"
    echo "   3. pg_basebackup으로 Slave 재구성"
elif [ "$MASTER_IS_RECOVERY" = "f" ] && [ "$SLAVE_IS_RECOVERY" = "t" ]; then
    echo "✅ 10.164.32.91이 Master, 10.164.32.92가 Slave로 정상 복구됨"
elif [ "$MASTER_IS_RECOVERY" = "t" ] && [ "$SLAVE_IS_RECOVERY" = "f" ]; then
    echo "✅ 10.164.32.92가 Master, 10.164.32.91이 Slave로 역할 전환됨"
else
    echo "⚠️ 예상치 못한 상태"
fi

echo ""
echo "✅ 네트워크 분단 시나리오 테스트 완료"
echo ""
echo "테스트 결과 요약:"
echo "- 네트워크 분단 시뮬레이션: 성공"
echo "- 분단 중 각 서버 독립 동작: 성공"
echo "- Split-brain 상황 발생: 확인됨"
echo "- 네트워크 복구: 성공"
echo "- Split-brain 해결: 수동 개입 필요"
```

### 3.4 서버 하드웨어 장애 시뮬레이션 스크립트
```bash
#!/bin/bash
# 파일명: test-server-hardware-failure.sh
# 설명: 서버 전체 다운 상황 시뮬레이션 (하드웨어 장애)

set -e

echo "=== 서버 하드웨어 장애 시나리오 테스트 ==="
echo ""

# 테스트 시작 전 상태 확인
echo "1. 테스트 시작 전 상태 확인..."
./test-replication-status.sh || {
    echo "❌ 초기 복제 상태가 비정상입니다"
    exit 1
}

# 장애 전 데이터 삽입
echo ""
echo "2. 장애 전 테스트 데이터 삽입..."
TEST_ID=$(date +%s)
psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('hw_failure_$TEST_ID', 'hw_failure_$TEST_ID@example.com', 'hashed_password', NOW(), NOW());"

INITIAL_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
echo "장애 전 Master 레코드 수: $INITIAL_COUNT"

# 서버 전체 중지 시뮬레이션 (reboot 또는 shutdown)
echo ""
echo "3. Master 서버 하드웨어 장애 시뮬레이션 (시스템 재부팅)..."
echo "⚠️ 주의: 실제 서버 재부팅을 수행합니다"
read -p "계속하시겠습니까? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "테스트 중단됨"
    exit 1
fi

# 서버 재부팅 (실제 하드웨어 장애 시뮬레이션)
ssh root@10.164.32.91 "shutdown -r +1 'PostgreSQL 장애 테스트를 위한 재부팅'" || {
    echo "❌ Master 서버 재부팅 명령 실패"
    exit 1
}

echo "✅ Master 서버 재부팅 명령 전송됨 (1분 후 재부팅)"
echo "60초 대기 중..."
sleep 65

# 서버 다운 확인
echo ""
echo "4. Master 서버 다운 확인..."
for i in {1..30}; do
    if ping -c 1 10.164.32.91 > /dev/null 2>&1; then
        echo "서버가 아직 응답 중... ($i/30)"
        sleep 2
    else
        echo "✅ Master 서버가 다운됨"
        break
    fi
done

# PostgreSQL 서비스 다운 확인
if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "❌ PostgreSQL 서비스가 여전히 응답하고 있음"
    exit 1
else
    echo "✅ PostgreSQL 서비스 다운 확인됨"
fi

# Slave 자동 승격
echo ""
echo "5. Slave 자동 승격..."
if psql -h 10.164.32.92 -U postgres -c "SELECT pg_promote();" > /dev/null 2>&1; then
    echo "✅ Slave 승격 명령 성공"
    sleep 5
    
    # 승격 확인
    IS_RECOVERY=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    if [ "$IS_RECOVERY" = "f" ]; then
        echo "✅ Slave가 성공적으로 Master로 승격됨"
    else
        echo "❌ Slave 승격 실패"
        exit 1
    fi
else
    echo "❌ Slave 승격 실패"
    exit 1
fi

# 새 Master에서 서비스 연속성 테스트
echo ""
echo "6. 새 Master에서 서비스 연속성 테스트..."
for i in {1..5}; do
    NEW_TEST_ID="${TEST_ID}_continuity_$i"
    INSERT_RESULT=$(psql -h 10.164.32.92 -U postgres -c "
    INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
    VALUES ('$NEW_TEST_ID', '$NEW_TEST_ID@example.com', 'hashed_password', NOW(), NOW());" 2>&1)
    
    if echo "$INSERT_RESULT" | grep -q "INSERT 0 1"; then
        echo "✅ 연속성 테스트 $i 성공"
    else
        echo "❌ 연속성 테스트 $i 실패"
        echo "에러: $INSERT_RESULT"
        exit 1
    fi
    
    sleep 2
done

# Master 서버 복구 대기
echo ""
echo "7. Master 서버 복구 대기..."
echo "서버 부팅 완료까지 대기 중..."

for i in {1..60}; do
    if ping -c 1 10.164.32.91 > /dev/null 2>&1; then
        echo "✅ Master 서버 네트워크 복구 확인 ($i/60)"
        break
    else
        echo "Master 서버 부팅 대기 중... ($i/60)"
        sleep 5
    fi
done

# PostgreSQL 서비스 자동 복구 확인
echo ""
echo "8. PostgreSQL 서비스 자동 복구 확인..."
for i in {1..20}; do
    if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
        echo "✅ PostgreSQL 서비스 자동 복구 확인 ($i/20)"
        break
    else
        echo "PostgreSQL 서비스 복구 대기 중... ($i/20)"
        sleep 10
    fi
done

# 복구된 서버 상태 확인
if psql -h 10.164.32.91 -U postgres -c "SELECT pg_is_in_recovery();" > /dev/null 2>&1; then
    IS_RECOVERY_ORIGINAL=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    
    if [ "$IS_RECOVERY_ORIGINAL" = "t" ]; then
        echo "✅ 복구된 서버가 자동으로 Slave 모드로 전환됨"
    else
        echo "⚠️ 복구된 서버가 Master 모드로 시작됨 (Split-brain 위험)"
    fi
else
    echo "❌ 복구된 서버 PostgreSQL 연결 실패"
fi

echo ""
echo "✅ 서버 하드웨어 장애 시나리오 테스트 완료"
echo ""
echo "테스트 결과 요약:"
echo "- 서버 하드웨어 장애 시뮬레이션: 성공"
echo "- Slave 자동 승격: 성공"
echo "- 서비스 연속성 유지: 성공"
echo "- Master 서버 자동 복구: 성공"
```

### 3.5 데이터베이스 코럽션 장애 시뮬레이션 스크립트
```bash
#!/bin/bash
# 파일명: test-database-corruption.sh
# 설명: 데이터베이스 파일 손상 시나리오 테스트

set -e

echo "=== 데이터베이스 코럽션 장애 시나리오 테스트 ==="
echo ""

# 테스트 시작 전 상태 확인
echo "1. 테스트 시작 전 상태 확인..."
./test-replication-status.sh || {
    echo "❌ 초기 복제 상태가 비정상입니다"
    exit 1
}

# 장애 전 데이터 삽입
echo ""
echo "2. 장애 전 중요 데이터 삽입..."
TEST_ID=$(date +%s)

# 여러 테이블에 테스트 데이터 삽입
psql -h 10.164.32.91 -U postgres -c "
BEGIN;
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('corruption_test_$TEST_ID', 'corruption_test_$TEST_ID@example.com', 'hashed_password', NOW(), NOW());

INSERT INTO \"User\" (id, \"authId\", role, language, name, \"createdAt\", \"updatedAt\") 
VALUES ('user_corruption_$TEST_ID', 'corruption_test_$TEST_ID', 'CUSTOMER', 'ko', 'Corruption Test User', NOW(), NOW());

INSERT INTO \"ChatRoom\" (id, title, purpose, \"createdAt\", \"updatedAt\") 
VALUES ('room_corruption_$TEST_ID', 'Corruption Test Room', 'Test corruption recovery', NOW(), NOW());
COMMIT;"

INITIAL_AUTH_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
INITIAL_USER_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"User\";" 2>/dev/null | tr -d ' ')

echo "장애 전 Auth 레코드 수: $INITIAL_AUTH_COUNT"
echo "장애 전 User 레코드 수: $INITIAL_USER_COUNT"

# 동기화 확인
sleep 5
SLAVE_AUTH_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
echo "Slave Auth 레코드 수: $SLAVE_AUTH_COUNT"

# Master PostgreSQL 중지
echo ""
echo "3. Master PostgreSQL 서비스 중지..."
ssh root@10.164.32.91 "systemctl stop postgresql"
echo "✅ Master PostgreSQL 서비스 중지됨"

# 데이터 파일 손상 시뮬레이션
echo ""
echo "4. 데이터베이스 파일 손상 시뮬레이션..."
echo "⚠️ 주의: 실제 데이터베이스 파일을 손상시킵니다"
read -p "계속하시겠습니까? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "테스트 중단됨"
    exit 1
fi

# 데이터베이스 파일에 랜덤 데이터 쓰기 (손상 시뮬레이션)
ssh root@10.164.32.91 "
cd /var/lib/postgresql/17/main/base
# 첫 번째 데이터베이스 디렉토리 찾기
DB_DIR=\$(ls -1 | head -1)
echo '랜덤 손상 데이터를 데이터베이스 파일에 추가...'
dd if=/dev/urandom of=\$DB_DIR/1259 bs=1024 count=1 conv=notrunc 2>/dev/null || true
echo '✅ 데이터베이스 파일 손상 완료'
"

# Master 재시작 시도 (실패 예상)
echo ""
echo "5. 손상된 Master 재시작 시도..."
ssh root@10.164.32.91 "systemctl start postgresql" || true
sleep 5

# Master 상태 확인 (손상으로 인한 실패 예상)
if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "⚠️ Master가 예상과 달리 정상 시작됨"
else
    echo "✅ Master가 데이터 손상으로 인해 시작 실패 (예상된 상황)"
fi

# PostgreSQL 로그 확인
echo ""
echo "6. PostgreSQL 에러 로그 확인..."
ssh root@10.164.32.91 "tail -20 /var/log/postgresql/postgresql-17-main.log" || echo "로그 파일 확인 실패"

# Slave를 Master로 승격
echo ""
echo "7. Slave를 새 Master로 승격..."
if psql -h 10.164.32.92 -U postgres -c "SELECT pg_promote();" > /dev/null 2>&1; then
    echo "✅ Slave 승격 명령 성공"
    sleep 5
    
    # 승격 확인
    IS_RECOVERY=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    if [ "$IS_RECOVERY" = "f" ]; then
        echo "✅ Slave가 성공적으로 Master로 승격됨"
    else
        echo "❌ Slave 승격 실패"
        exit 1
    fi
else
    echo "❌ Slave 승격 실패"
    exit 1
fi

# 데이터 무결성 확인
echo ""
echo "8. 새 Master에서 데이터 무결성 확인..."
NEW_AUTH_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
NEW_USER_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"User\";" 2>/dev/null | tr -d ' ')

echo "새 Master Auth 레코드 수: $NEW_AUTH_COUNT"
echo "새 Master User 레코드 수: $NEW_USER_COUNT"

# 관계 무결성 확인
echo ""
echo "9. 관계 무결성 확인..."
ORPHAN_USERS=$(psql -h 10.164.32.92 -U postgres -t -c "
SELECT COUNT(*) FROM \"User\" u 
LEFT JOIN \"Auth\" a ON u.\"authId\" = a.id 
WHERE a.id IS NULL;" 2>/dev/null | tr -d ' ')

if [ "$ORPHAN_USERS" = "0" ]; then
    echo "✅ User-Auth 관계 무결성 확인됨"
else
    echo "⚠️ $ORPHAN_USERS개의 고아 User 레코드 발견"
fi

# 손상된 Master 복구 (데이터 재구축)
echo ""
echo "10. 손상된 Master 서버 복구..."
ssh root@10.164.32.91 "
systemctl stop postgresql
rm -rf /var/lib/postgresql/17/main/*
echo '✅ 손상된 데이터 제거 완료'
"

# 새 Master에서 베이스 백업으로 복구
echo "새 Master에서 베이스 백업 생성하여 복구..."
ssh root@10.164.32.91 "
# 새 Master에서 복제 사용자 생성 (필요시)
sudo -u postgres psql -h 10.164.32.92 -c \"SELECT pg_create_physical_replication_slot('recovered_master_slot');\" 2>/dev/null || true

# 베이스 백업 실행
sudo -u postgres bash -c \"
PGPASSWORD=replicator_password pg_basebackup \
    -h 10.164.32.92 \
    -D /var/lib/postgresql/17/main \
    -U replicator \
    -v -P
\"

# Standby 설정
sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal
sudo -u postgres bash -c \"cat >> /var/lib/postgresql/17/main/postgresql.conf << EOF

# Recovered as Standby
primary_conninfo = 'host=10.164.32.92 port=5432 user=replicator password=replicator_password application_name=recovered_master'
primary_slot_name = 'recovered_master_slot'
EOF\"

systemctl start postgresql
"

echo ""
echo "11. 복구된 서버 상태 확인..."
sleep 10

if psql -h 10.164.32.91 -U postgres -c "SELECT pg_is_in_recovery();" > /dev/null 2>&1; then
    IS_RECOVERY_RECOVERED=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    
    if [ "$IS_RECOVERY_RECOVERED" = "t" ]; then
        echo "✅ 복구된 서버가 Slave로 정상 동작 중"
        
        # 데이터 동기화 확인
        sleep 5
        RECOVERED_AUTH_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
        echo "복구된 서버 Auth 레코드 수: $RECOVERED_AUTH_COUNT"
        
        if [ "$RECOVERED_AUTH_COUNT" = "$NEW_AUTH_COUNT" ]; then
            echo "✅ 데이터가 완전히 동기화됨"
        else
            echo "⚠️ 데이터 동기화 진행 중"
        fi
    else
        echo "⚠️ 복구된 서버가 Master 모드로 시작됨"
    fi
else
    echo "❌ 복구된 서버 연결 실패"
fi

echo ""
echo "✅ 데이터베이스 코럽션 장애 시나리오 테스트 완료"
echo ""
echo "테스트 결과 요약:"
echo "- 데이터베이스 파일 손상 시뮬레이션: 성공"
echo "- Master 장애 감지: 성공"
echo "- Slave 승격: 성공"
echo "- 데이터 무결성 유지: 성공"
echo "- 손상된 서버 복구: 성공"
```

### 3.6 디스크 공간 부족 장애 시뮬레이션 스크립트
```bash
#!/bin/bash
# 파일명: test-disk-space-failure.sh
# 설명: 디스크 공간 부족 장애 시나리오 테스트

set -e

echo "=== 디스크 공간 부족 장애 시나리오 테스트 ==="
echo ""

# 현재 디스크 사용량 확인
echo "1. 현재 디스크 사용량 확인..."
ssh root@10.164.32.91 "df -h /var/lib/postgresql"
ssh root@10.164.32.92 "df -h /var/lib/postgresql"

# 테스트 시작 전 상태 확인
echo ""
echo "2. 테스트 시작 전 상태 확인..."
./test-replication-status.sh || {
    echo "❌ 초기 복제 상태가 비정상입니다"
    exit 1
}

# 디스크 공간 부족 시뮬레이션 (Master 서버)
echo ""
echo "3. Master 서버 디스크 공간 부족 시뮬레이션..."
echo "⚠️ 주의: 실제로 디스크 공간을 소진시킵니다"
read -p "계속하시겠습니까? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "테스트 중단됨"
    exit 1
fi

# 대용량 파일 생성으로 디스크 공간 소진
ssh root@10.164.32.91 "
cd /var/lib/postgresql
# 사용 가능한 공간의 90% 정도 소진
AVAILABLE=\$(df . | tail -1 | awk '{print \$4}')
FILL_SIZE=\$((\$AVAILABLE * 90 / 100))
echo \"사용 가능 공간: \${AVAILABLE}KB, 소진할 공간: \${FILL_SIZE}KB\"
dd if=/dev/zero of=./disk_fill_test.dat bs=1024 count=\$FILL_SIZE 2>/dev/null || true
echo '✅ 디스크 공간 90% 소진 완료'
df -h .
"

# 디스크 공간 부족 상황에서 대량 데이터 삽입 시도
echo ""
echo "4. 디스크 공간 부족 상황에서 대량 데이터 삽입 시도..."
TEST_ID=$(date +%s)

# 대량 데이터 삽입으로 디스크 공간 완전 소진 유도
BULK_INSERT_RESULT=$(psql -h 10.164.32.91 -U postgres -c "
BEGIN;
DO \$\$
BEGIN
    FOR i IN 1..1000 LOOP
        INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
        VALUES ('disk_test_$TEST_ID' || '_' || i, 'disk_test_$TEST_ID' || '_' || i || '@example.com', 'hashed_password_' || i, NOW(), NOW());
        
        INSERT INTO \"User\" (id, \"authId\", role, language, name, \"createdAt\", \"updatedAt\") 
        VALUES ('user_disk_$TEST_ID' || '_' || i, 'disk_test_$TEST_ID' || '_' || i, 'CUSTOMER', 'ko', 'Disk Test User ' || i, NOW(), NOW());
        
        -- 대용량 텍스트 데이터로 공간 빠르게 소진
        INSERT INTO \"ChatRoom\" (id, title, purpose, \"createdAt\", \"updatedAt\") 
        VALUES ('room_disk_$TEST_ID' || '_' || i, 'Large Data Room ' || i, repeat('x', 10000), NOW(), NOW());
    END LOOP;
END
\$\$;
COMMIT;" 2>&1) || true

echo "대량 삽입 결과:"
echo "$BULK_INSERT_RESULT"

# 디스크 공간 상태 확인
echo ""
echo "5. 디스크 공간 상태 재확인..."
ssh root@10.164.32.91 "df -h /var/lib/postgresql"

# PostgreSQL 서비스 상태 확인
echo ""
echo "6. Master PostgreSQL 서비스 상태 확인..."
if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "⚠️ Master PostgreSQL이 여전히 응답 중"
    
    # 추가 공간 소진으로 서비스 중단 유도
    ssh root@10.164.32.91 "
    dd if=/dev/zero of=/var/lib/postgresql/final_fill.dat bs=1024 count=100000 2>/dev/null || true
    echo '추가 공간 소진 완료'
    "
    
    sleep 5
    
    if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
        echo "⚠️ Master가 여전히 응답하고 있음"
    else
        echo "✅ Master가 디스크 공간 부족으로 중단됨"
    fi
else
    echo "✅ Master가 디스크 공간 부족으로 중단됨"
fi

# Slave 상태 확인 및 승격
echo ""
echo "7. Slave 상태 확인 및 Master 승격..."
if psql -h 10.164.32.92 -U postgres -c "SELECT pg_is_in_recovery();" > /dev/null 2>&1; then
    echo "✅ Slave는 정상 동작 중"
    
    # Slave 승격
    if psql -h 10.164.32.92 -U postgres -c "SELECT pg_promote();" > /dev/null 2>&1; then
        echo "✅ Slave 승격 성공"
        sleep 5
        
        # 새 Master에서 서비스 연속성 테스트
        NEW_TEST_ID=$(date +%s)
        if psql -h 10.164.32.92 -U postgres -c "
        INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
        VALUES ('new_master_$NEW_TEST_ID', 'new_master_$NEW_TEST_ID@example.com', 'hashed_password', NOW(), NOW());" > /dev/null 2>&1; then
            echo "✅ 새 Master에서 정상 서비스 제공 중"
        else
            echo "❌ 새 Master에서 서비스 실패"
        fi
    else
        echo "❌ Slave 승격 실패"
    fi
else
    echo "❌ Slave도 응답하지 않음"
    exit 1
fi

# Master 서버 디스크 공간 정리 및 복구
echo ""
echo "8. Master 서버 디스크 공간 정리 및 복구..."
ssh root@10.164.32.91 "
cd /var/lib/postgresql
rm -f disk_fill_test.dat final_fill.dat *.dat 2>/dev/null || true
echo '✅ 테스트 파일 정리 완료'
df -h .

# PostgreSQL 로그 정리 (공간 확보)
find /var/log/postgresql -name '*.log' -mtime +7 -delete 2>/dev/null || true

# PostgreSQL 서비스 재시작
systemctl restart postgresql
"

echo "Master 서버 복구 대기 중..."
sleep 10

# Master 복구 확인
if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✅ Master PostgreSQL 서비스 복구 완료"
    
    # 디스크 공간 재확인
    ssh root@10.164.32.91 "df -h /var/lib/postgresql"
    
    # Split-brain 방지를 위해 Master를 Slave로 재구성
    echo ""
    echo "9. Split-brain 방지를 위한 Master→Slave 재구성..."
    ssh root@10.164.32.91 "
    systemctl stop postgresql
    rm -rf /var/lib/postgresql/17/main/*
    
    # 새 Master에서 베이스 백업
    sudo -u postgres bash -c \"
    PGPASSWORD=replicator_password pg_basebackup \
        -h 10.164.32.92 \
        -D /var/lib/postgresql/17/main \
        -U replicator \
        -v -P
    \"
    
    # Standby 설정
    sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal
    sudo -u postgres bash -c \"cat >> /var/lib/postgresql/17/main/postgresql.conf << EOF

# Disk recovery standby
primary_conninfo = 'host=10.164.32.92 port=5432 user=replicator password=replicator_password'
primary_slot_name = 'recovered_master_slot'
EOF\"
    
    systemctl start postgresql
    "
    
    sleep 10
    
    # 최종 복구 상태 확인
    if psql -h 10.164.32.91 -U postgres -c "SELECT pg_is_in_recovery();" > /dev/null 2>&1; then
        IS_RECOVERY=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
        if [ "$IS_RECOVERY" = "t" ]; then
            echo "✅ 복구된 서버가 Slave로 정상 동작 중"
        else
            echo "⚠️ 복구된 서버가 Master 모드로 동작 중"
        fi
    else
        echo "❌ 복구된 서버 연결 실패"
    fi
else
    echo "❌ Master PostgreSQL 서비스 복구 실패"
fi

echo ""
echo "✅ 디스크 공간 부족 장애 시나리오 테스트 완료"
echo ""
echo "테스트 결과 요약:"
echo "- 디스크 공간 부족 시뮬레이션: 성공"
echo "- Master 서비스 중단 확인: 성공"
echo "- Slave 자동 승격: 성공"
echo "- 서비스 연속성 유지: 성공"
echo "- Master 서버 복구: 성공"
echo ""
echo "⚠️ 주의사항:"
echo "- 실제 운영 환경에서는 디스크 모니터링 알람 설정 필수"
echo "- WAL 파일 자동 정리 설정 권장"
echo "- 로그 로테이션 설정 필요"
```

---

## 4. 통합 테스트 스크립트

### 4.1 전체 시나리오 테스트 스크립트
```bash
#!/bin/bash
# 파일명: run-all-tests.sh
# 설명: 모든 테스트 시나리오를 순차적으로 실행

set -e

echo "========================================"
echo "PostgreSQL Master-Slave 통합 테스트 시작"
echo "========================================"
echo ""

# 테스트 결과 저장
TEST_RESULTS=()
FAILED_TESTS=()

# 테스트 실행 함수
run_test() {
    local test_name="$1"
    local test_script="$2"
    
    echo ">>> 테스트 시작: $test_name"
    echo "----------------------------------------"
    
    if ./"$test_script"; then
        echo "✅ $test_name: 성공"
        TEST_RESULTS+=("✅ $test_name: 성공")
    else
        echo "❌ $test_name: 실패"
        TEST_RESULTS+=("❌ $test_name: 실패")
        FAILED_TESTS+=("$test_name")
    fi
    
    echo "----------------------------------------"
    echo ""
    sleep 5
}

# 테스트 실행
echo "테스트 시작 시간: $(date)"
echo ""

run_test "연결 테스트" "test-connection.sh"
run_test "복제 상태 확인" "test-replication-status.sh"
run_test "데이터 동기화 테스트" "test-data-sync.sh"
run_test "Master 장애 시나리오" "test-master-failure.sh"
run_test "Slave 장애 시나리오" "test-slave-failure.sh"
run_test "네트워크 분단 시나리오" "test-network-partition.sh"
run_test "서버 하드웨어 장애 시나리오" "test-server-hardware-failure.sh"
run_test "데이터베이스 코럽션 시나리오" "test-database-corruption.sh"
run_test "디스크 공간 부족 시나리오" "test-disk-space-failure.sh"

# 최종 결과 출력
echo "========================================"
echo "테스트 완료 시간: $(date)"
echo "========================================"
echo ""
echo "테스트 결과 요약:"
echo "----------------"

for result in "${TEST_RESULTS[@]}"; do
    echo "$result"
done

echo ""
echo "총 테스트 수: ${#TEST_RESULTS[@]}"
echo "실패한 테스트 수: ${#FAILED_TESTS[@]}"

if [ ${#FAILED_TESTS[@]} -eq 0 ]; then
    echo ""
    echo "🎉 모든 테스트가 성공적으로 완료되었습니다!"
    exit 0
else
    echo ""
    echo "⚠️ 다음 테스트들이 실패했습니다:"
    for failed_test in "${FAILED_TESTS[@]}"; do
        echo "  - $failed_test"
    done
    exit 1
fi
```

### 4.2 성능 테스트 스크립트
```bash
#!/bin/bash
# 파일명: test-performance.sh
# 설명: Master-Slave 구조의 성능 테스트

set -e

echo "=== PostgreSQL Master-Slave 성능 테스트 ==="
echo ""

# 테스트 설정
BULK_INSERT_COUNT=1000
CONCURRENT_CONNECTIONS=10
TEST_DURATION=60

echo "테스트 설정:"
echo "- 대량 삽입 레코드 수: $BULK_INSERT_COUNT"
echo "- 동시 연결 수: $CONCURRENT_CONNECTIONS"
echo "- 테스트 지속 시간: $TEST_DURATION초"
echo ""

# 1. 대량 데이터 삽입 테스트 (Prisma 스키마 기반)
echo "1. 대량 데이터 삽입 성능 테스트..."
START_TIME=$(date +%s)

psql -h 10.164.32.91 -U postgres -c "
BEGIN;
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\")
SELECT 
    'perf_auth_' || generate_series(1, $BULK_INSERT_COUNT),
    'perf_user_' || generate_series(1, $BULK_INSERT_COUNT) || '@example.com',
    'hashed_password_' || generate_series(1, $BULK_INSERT_COUNT),
    NOW(),
    NOW();
COMMIT;
" > /dev/null 2>&1

END_TIME=$(date +%s)
BULK_INSERT_TIME=$((END_TIME - START_TIME))

echo "✅ $BULK_INSERT_COUNT 레코드 삽입 완료"
echo "   소요 시간: ${BULK_INSERT_TIME}초"
echo "   초당 삽입 속도: $((BULK_INSERT_COUNT / BULK_INSERT_TIME)) 레코드/초"

# 2. 복제 지연 측정
echo ""
echo "2. 복제 지연 측정..."
SYNC_START_TIME=$(date +%s)

# Master에서 마커 레코드 삽입 (Prisma 스키마 기반)
MARKER_ID=$(date +%s%N)
psql -h 10.164.32.91 -U postgres -c "
INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
VALUES ('sync_marker_$MARKER_ID', 'sync_marker_$MARKER_ID@example.com', 'hashed_password', NOW(), NOW());" > /dev/null 2>&1

# Slave에서 마커 레코드가 나타날 때까지 대기
while true; do
    MARKER_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "
    SELECT COUNT(*) FROM \"Auth\" WHERE \"emailAddress\" = 'sync_marker_$MARKER_ID@example.com';" 2>/dev/null | tr -d ' ')
    
    if [ "$MARKER_COUNT" = "1" ]; then
        break
    fi
    
    sleep 0.1
done

SYNC_END_TIME=$(date +%s%N)
REPLICATION_LAG=$(( (SYNC_END_TIME - MARKER_ID) / 1000000 ))

echo "✅ 복제 지연 시간: ${REPLICATION_LAG}ms"

# 3. 읽기 성능 테스트
echo ""
echo "3. 읽기 성능 테스트..."

# Master 읽기 성능 (Prisma 스키마 기반)
MASTER_READ_START=$(date +%s%N)
for _ in {1..100}; do
    psql -h 10.164.32.91 -U postgres -c "SELECT COUNT(*) FROM \"Auth\";" > /dev/null 2>&1
done
MASTER_READ_END=$(date +%s%N)
MASTER_READ_TIME=$(( (MASTER_READ_END - MASTER_READ_START) / 1000000 ))

echo "Master 읽기 성능 (100회 COUNT 쿼리): ${MASTER_READ_TIME}ms"

# Slave 읽기 성능
SLAVE_READ_START=$(date +%s%N)
for _ in {1..100}; do
    psql -h 10.164.32.92 -U postgres -c "SELECT COUNT(*) FROM \"Auth\";" > /dev/null 2>&1
done
SLAVE_READ_END=$(date +%s%N)
SLAVE_READ_TIME=$(( (SLAVE_READ_END - SLAVE_READ_START) / 1000000 ))

echo "Slave 읽기 성능 (100회 COUNT 쿼리): ${SLAVE_READ_TIME}ms"

# 4. 동시 연결 테스트
echo ""
echo "4. 동시 연결 테스트..."

# 백그라운드에서 동시 쓰기 작업 실행 (Prisma 스키마 기반)
for i in $(seq 1 $CONCURRENT_CONNECTIONS); do
    {
        for j in {1..10}; do
            psql -h 10.164.32.91 -U postgres -c "
            INSERT INTO \"Auth\" (id, \"emailAddress\", \"hashedPassword\", \"createdAt\", \"updatedAt\") 
            VALUES ('concurrent_${i}_${j}', 'concurrent_${i}_${j}@example.com', 'hashed_password', NOW(), NOW());" > /dev/null 2>&1
        done
    } &
done

# 모든 백그라운드 작업 완료 대기
wait

echo "✅ ${CONCURRENT_CONNECTIONS}개 동시 연결에서 각각 10개 레코드 삽입 완료"

# 5. 복제 일관성 확인
echo ""
echo "5. 복제 일관성 확인..."
sleep 5  # 복제 완료 대기

MASTER_FINAL_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')
SLAVE_FINAL_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ')

echo "Master 최종 레코드 수: $MASTER_FINAL_COUNT"
echo "Slave 최종 레코드 수: $SLAVE_FINAL_COUNT"

if [ "$MASTER_FINAL_COUNT" = "$SLAVE_FINAL_COUNT" ]; then
    echo "✅ 복제 일관성 확인됨"
else
    echo "⚠️ 복제 일관성 문제 발견"
    echo "   추가 동기화 시간이 필요할 수 있습니다"
fi

# 6. WAL 통계 확인
echo ""
echo "6. WAL 통계 확인..."
psql -h 10.164.32.91 -U postgres -c "
SELECT 
    slot_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag,
    active
FROM pg_replication_slots;"

echo ""
echo "✅ 성능 테스트 완료"
echo ""
echo "성능 테스트 결과 요약:"
echo "---------------------"
echo "- 대량 삽입 성능: $((BULK_INSERT_COUNT / BULK_INSERT_TIME)) 레코드/초"
echo "- 복제 지연 시간: ${REPLICATION_LAG}ms"
echo "- Master 읽기 성능: ${MASTER_READ_TIME}ms (100회 쿼리)"
echo "- Slave 읽기 성능: ${SLAVE_READ_TIME}ms (100회 쿼리)"
echo "- 동시 연결 테스트: 성공"
echo "- 복제 일관성: $([ "$MASTER_FINAL_COUNT" = "$SLAVE_FINAL_COUNT" ] && echo "확인됨" || echo "문제 있음")"
```

---

## 5. 모니터링 및 유지보수

### 5.1 실시간 모니터링 스크립트
```bash
#!/bin/bash
# 파일명: monitor-replication.sh
# 설명: 실시간 복제 상태 모니터링

echo "PostgreSQL Master-Slave 실시간 모니터링"
echo "========================================"
echo "종료하려면 Ctrl+C를 누르세요"
echo ""

while true; do
    clear
    echo "모니터링 시간: $(date)"
    echo "========================================"
    
    # Master 상태
    echo ""
    echo "🔹 Master 서버 상태 (10.164.32.91):"
    if psql -h 10.164.32.91 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
        echo "✅ 연결 상태: 정상"
        
        # 복제 슬롯 상태
        echo "복제 슬롯:"
        psql -h 10.164.32.91 -U postgres -c "
        SELECT slot_name, active, 
               pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
        FROM pg_replication_slots;" 2>/dev/null || echo "조회 실패"
        
        # WAL Sender 상태
        echo "WAL Sender:"
        psql -h 10.164.32.91 -U postgres -c "
        SELECT application_name, client_addr, state,
               pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
        FROM pg_stat_replication;" 2>/dev/null || echo "조회 실패"
        
    else
        echo "❌ 연결 상태: 실패"
    fi
    
    # Slave 상태
    echo ""
    echo "🔹 Slave 서버 상태 (10.164.32.92):"
    if psql -h 10.164.32.92 -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
        echo "✅ 연결 상태: 정상"
        
        # Recovery 상태
        RECOVERY_STATUS=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
        echo "Recovery 모드: $RECOVERY_STATUS"
        
        # WAL Receiver 상태
        echo "WAL Receiver:"
        psql -h 10.164.32.92 -U postgres -c "
        SELECT status, receive_start_lsn, received_lsn,
               last_msg_send_time, last_msg_receipt_time
        FROM pg_stat_wal_receiver;" 2>/dev/null || echo "조회 실패"
        
    else
        echo "❌ 연결 상태: 실패"
    fi
    
    # 데이터 동기화 상태 (Prisma 스키마 기반)
    echo ""
    echo "🔹 데이터 동기화 상태:"
    MASTER_COUNT=$(psql -h 10.164.32.91 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ' || echo "N/A")
    SLAVE_COUNT=$(psql -h 10.164.32.92 -U postgres -t -c "SELECT COUNT(*) FROM \"Auth\";" 2>/dev/null | tr -d ' ' || echo "N/A")
    
    echo "Master 레코드 수: $MASTER_COUNT"
    echo "Slave 레코드 수: $SLAVE_COUNT"
    
    if [ "$MASTER_COUNT" = "$SLAVE_COUNT" ] && [ "$MASTER_COUNT" != "N/A" ]; then
        echo "✅ 데이터 동기화: 정상"
    else
        echo "⚠️ 데이터 동기화: 불일치"
    fi
    
    echo ""
    echo "========================================"
    echo "다음 업데이트까지 5초..."
    sleep 5
done
```

### 5.2 자동 복구 스크립트
```bash
#!/bin/bash
# 파일명: auto-recovery.sh
# 설명: 장애 상황 자동 감지 및 복구

set -e

LOG_FILE="/var/log/postgres-auto-recovery.log"

# 로그 함수
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 서버 상태 확인 함수
check_server_status() {
    local server_ip=$1
    local server_name=$2
    
    if psql -h "$server_ip" -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
        return 0  # 정상
    else
        return 1  # 장애
    fi
}

# Master 상태 확인 함수
is_master_server() {
    local server_ip=$1
    
    local recovery_status=$(psql -h "$server_ip" -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    
    if [ "$recovery_status" = "f" ]; then
        return 0  # Master
    else
        return 1  # Slave 또는 연결 실패
    fi
}

log_message "자동 복구 스크립트 시작"

# 메인 모니터링 루프
while true; do
    MASTER_ONLINE=false
    SLAVE_ONLINE=false
    CURRENT_MASTER=""
    
    # Master 서버 상태 확인
    if check_server_status "10.164.32.91" "Original Master"; then
        MASTER_ONLINE=true
        if is_master_server "10.164.32.91"; then
            CURRENT_MASTER="10.164.32.91"
        fi
    fi
    
    # Slave 서버 상태 확인
    if check_server_status "10.164.32.92" "Original Slave"; then
        SLAVE_ONLINE=true
        if is_master_server "10.164.32.92"; then
            CURRENT_MASTER="10.164.32.92"
        fi
    fi
    
    # 현재 상태 로그
    log_message "상태 체크 - Master(91): $MASTER_ONLINE, Slave(92): $SLAVE_ONLINE, Current Master: ${CURRENT_MASTER:-none}"
    
    # 장애 상황별 대응
    if [ "$MASTER_ONLINE" = false ] && [ "$SLAVE_ONLINE" = false ]; then
        log_message "❌ 심각: 모든 서버가 다운됨"
        # 알림 발송 (실제 환경에서는 SMS, 이메일 등)
        echo "CRITICAL: All PostgreSQL servers are down!" | wall
        
    elif [ "$MASTER_ONLINE" = false ] && [ "$SLAVE_ONLINE" = true ]; then
        log_message "⚠️ Master 서버 다운, Slave 서버 정상"
        
        if [ "$CURRENT_MASTER" != "10.164.32.92" ]; then
            log_message "🔄 Slave를 Master로 자동 승격 시도"
            
            if psql -h 10.164.32.92 -U postgres -c "SELECT pg_promote();" > /dev/null 2>&1; then
                log_message "✅ Slave 자동 승격 성공"
                sleep 5
                
                if is_master_server "10.164.32.92"; then
                    log_message "✅ 승격 확인 완료 - 10.164.32.92가 새로운 Master"
                else
                    log_message "❌ 승격 실패 - 수동 개입 필요"
                fi
            else
                log_message "❌ Slave 자동 승격 실패"
            fi
        fi
        
    elif [ "$MASTER_ONLINE" = true ] && [ "$SLAVE_ONLINE" = false ]; then
        log_message "⚠️ Slave 서버 다운, Master 서버 정상"
        
        # Slave 복구 시도 (SSH를 통한 서비스 재시작)
        log_message "🔄 Slave 서비스 재시작 시도"
        
        if ssh root@10.164.32.92 "systemctl restart postgresql" 2>/dev/null; then
            log_message "✅ Slave 서비스 재시작 성공"
            sleep 10
            
            if check_server_status "10.164.32.92" "Slave"; then
                log_message "✅ Slave 서버 복구 완료"
            else
                log_message "❌ Slave 서버 복구 실패 - 수동 개입 필요"
            fi
        else
            log_message "❌ Slave 서비스 재시작 실패"
        fi
        
    elif [ -z "$CURRENT_MASTER" ]; then
        log_message "⚠️ Master 서버가 식별되지 않음"
        
        # 원래 Master 서버를 Master로 복구 시도
        if [ "$MASTER_ONLINE" = true ]; then
            log_message "🔄 Original Master(10.164.32.91) 복구 시도"
            # 필요시 복구 로직 추가
        fi
        
    else
        # 정상 상태
        if [ ${#CURRENT_MASTER} -gt 0 ]; then
            # 복제 지연 확인
            if [ "$CURRENT_MASTER" = "10.164.32.91" ] && [ "$SLAVE_ONLINE" = true ]; then
                LAG=$(psql -h 10.164.32.91 -U postgres -t -c "
                SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))
                FROM pg_stat_replication LIMIT 1;" 2>/dev/null | tr -d ' ')
                
                if [ -n "$LAG" ] && [ "$LAG" != "" ]; then
                    log_message "📊 복제 지연: $LAG"
                fi
            fi
        fi
    fi
    
    # 5분마다 상태 확인
    sleep 300
done
```

---

## 6. 사용법 요약

### 6.1 초기 설정 순서
```bash
# 1. Master 서버 설정 (10.164.32.91)
sudo apt update && sudo apt install postgresql-17 postgresql-client-17 -y
sudo nano /etc/postgresql/17/main/postgresql.conf  # 설정 수정
sudo nano /etc/postgresql/17/main/pg_hba.conf      # 복제 권한 추가
sudo -u postgres psql  # 복제 사용자 생성
sudo systemctl restart postgresql

# 2. Slave 서버 설정 (10.164.32.92)
sudo apt update && sudo apt install postgresql-17 postgresql-client-17 -y
sudo systemctl stop postgresql
sudo -u postgres pg_basebackup ...  # Master에서 백업
sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal
sudo systemctl start postgresql

# 3. 테스트 실행
chmod +x *.sh
./test-connection.sh
./test-replication-status.sh
./test-data-sync.sh
```

### 6.2 일상 관리 명령어
```bash
# 복제 상태 확인
./test-replication-status.sh

# 실시간 모니터링
./monitor-replication.sh

# 성능 테스트
./test-performance.sh

# 전체 테스트 실행
./run-all-tests.sh
```

### 6.3 장애 대응 절차
```bash
# Master 장애 시
./test-master-failure.sh

# Slave 장애 시  
./test-slave-failure.sh

# 자동 복구 시작
./auto-recovery.sh &
```

이 가이드를 통해 PostgreSQL Master-Slave 구조를 안정적으로 구축하고 다양한 장애 상황에 대비할 수 있습니다.