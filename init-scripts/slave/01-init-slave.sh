#!/bin/bash

# Slave 서버 초기화 스크립트
set -e

echo "Initializing Slave server..."

# Master가 준비될 때까지 대기
until pg_isready -h postgres_master -p 5432 -U postgres; do
  echo "Waiting for master to be ready..."
  sleep 2
done

echo "Master is ready, starting slave setup..."

# 기존 데이터 디렉토리 정리
rm -rf /var/lib/postgresql/data/*

# Master에서 베이스 백업 생성
echo "Creating base backup from master..."
PGPASSWORD=replicator_password pg_basebackup -h postgres_master -D /var/lib/postgresql/data -U replicator -v -P -W

# recovery 설정 파일 생성
echo "Creating standby.signal..."
touch /var/lib/postgresql/data/standby.signal

# postgresql.conf에 복제 설정 추가
cat >> /var/lib/postgresql/data/postgresql.conf << EOF

# Slave specific settings
primary_conninfo = 'host=postgres_master port=5432 user=replicator password=replicator_password'
promote_trigger_file = '/tmp/promote_to_master'
EOF

echo "Slave initialization completed!"