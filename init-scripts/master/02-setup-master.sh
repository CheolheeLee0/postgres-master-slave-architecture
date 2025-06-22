#!/bin/bash

# Master 서버 설정
set -e

echo "Setting up Master server..."

# pg_hba.conf 설정 (복제 연결 허용)
echo "host replication replicator postgres_slave md5" >> /var/lib/postgresql/data/pg_hba.conf
echo "host replication replicator 0.0.0.0/0 md5" >> /var/lib/postgresql/data/pg_hba.conf

# 설정 재로드
psql -U postgres -c "SELECT pg_reload_conf();"

echo "Master server setup completed!"