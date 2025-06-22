#!/bin/bash

# Master-Slave 복제 설정 스크립트
set -e

echo "PostgreSQL Master-Slave 복제 설정을 시작합니다..."

# 기존 컨테이너 정리
echo "기존 컨테이너 정리 중..."
docker compose down -v || true

# Master 컨테이너 먼저 시작
echo "Master 컨테이너 시작 중..."
docker compose up -d postgres_master

# Master 서버가 준비될 때까지 대기
echo "Master 서버 준비 대기 중..."
until docker exec postgres_master pg_isready -U postgres; do
  echo "Master 서버가 준비될 때까지 대기 중..."
  sleep 1
done

echo "Master 서버가 준비되었습니다!"

# Master 서버 추가 설정
echo "Master 서버 복제 설정 중..."
docker exec postgres_master bash -c "
echo 'host replication replicator postgres_slave md5' >> /var/lib/postgresql/data/pg_hba.conf
echo 'host replication replicator 0.0.0.0/0 md5' >> /var/lib/postgresql/data/pg_hba.conf
"

# Master 서버 설정 재로드
docker exec postgres_master psql -U postgres -c "SELECT pg_reload_conf();"

# 복제 슬롯 생성 (PostgreSQL 17)
echo "복제 슬롯 생성 중..."
docker exec postgres_master psql -U postgres -c "SELECT pg_create_physical_replication_slot('slave_slot');" || echo "복제 슬롯이 이미 존재합니다."

echo "Master 서버 설정이 완료되었습니다!"

# Slave 컨테이너 시작
echo "Slave 컨테이너 시작 중..."
docker compose up -d postgres_slave

# Slave가 준비될 때까지 대기
echo "Slave 서버 준비 대기 중..."
sleep 1

until docker exec postgres_slave pg_isready -U postgres; do
  echo "Slave 서버가 준비될 때까지 대기 중..."
  sleep 1
done

echo "Slave를 복제 모드로 설정 중..."

# Slave 컨테이너 중지
echo "Slave 컨테이너 중지 중..."
docker stop postgres_slave || true

# 베이스 백업을 위한 임시 컨테이너 실행
echo "베이스 백업 생성 중..."
docker run --rm \
  --network test-db_test_network \
  -v test-db_postgres_slave_data:/var/lib/postgresql/data \
  postgres:latest bash -c "
    rm -rf /var/lib/postgresql/data/*
    PGPASSWORD=replicator_password pg_basebackup -h postgres_master -D /var/lib/postgresql/data -U replicator -v -P
    touch /var/lib/postgresql/data/standby.signal
    echo 'primary_conninfo = '\''host=postgres_master port=5432 user=replicator password=replicator_password application_name=slave_node'\''' >> /var/lib/postgresql/data/postgresql.conf
    echo 'primary_slot_name = '\''slave_slot'\''' >> /var/lib/postgresql/data/postgresql.conf
    echo 'restore_command = '\'''\''' >> /var/lib/postgresql/data/postgresql.conf
    echo 'archive_cleanup_command = '\'''\''' >> /var/lib/postgresql/data/postgresql.conf
    chown -R postgres:postgres /var/lib/postgresql/data
"

# Slave 컨테이너를 복제 모드로 재시작
echo "Slave 컨테이너를 복제 모드로 재시작 중..."
docker start postgres_slave

# Slave가 복제 모드로 시작될 때까지 대기
sleep 1
until docker exec postgres_slave pg_isready -U postgres; do
  echo "Slave 서버 복제 모드 시작 대기 중..."
  sleep 1
done

echo "Master-Slave 복제 설정이 완료되었습니다!"

# 복제 상태 확인
echo "복제 상태 확인 중..."
echo "Master 서버 상태:"
docker exec postgres_master psql -U postgres -c "
SELECT client_addr, state, sync_state FROM pg_stat_replication;
"

echo "Slave 서버 상태:"
docker exec postgres_slave psql -U postgres -c "
SELECT pg_is_in_recovery();
"