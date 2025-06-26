#!/bin/bash
# PostgreSQL Master-Slave 자동 장애조치 스크립트
# 운영1서버: 10.164.32.91 (Primary Master)
# 운영2서버: 10.164.32.92 (Primary Slave)

set -e

# 설정 변수
SERVER1="10.164.32.91"
SERVER2="10.164.32.92"
CHECK_INTERVAL=5  # 5초마다 체크
LOG_FILE="/var/log/postgres-failover.log"

# 로그 함수
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# DB 상태 확인 함수 (SSH 없이 Docker 직접 접근)
check_db_status() {
    local server_ip="$1"
    
    if [ "$server_ip" = "$SERVER1" ]; then
        # 1번 서버 DB 체크
        if docker exec rtt-postgres psql -U postgres -c 'SELECT 1;' > /dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    else
        # 2번 서버 DB 체크 (원격)
        if curl -f -s "http://$server_ip:8000/api/tests/ip" > /dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    fi
}

# Master 상태 확인 (Recovery 모드 여부)
is_master() {
    local server_ip="$1"
    
    local recovery_status
    if [ "$server_ip" = "$SERVER1" ]; then
        recovery_status=$(docker exec rtt-postgres psql -U postgres -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | tr -d ' ')
    else
        # 2번 서버의 경우 API를 통해 확인하거나 다른 방법 사용
        # 여기서는 DB 연결 가능 여부로 판단
        if check_db_status "$server_ip"; then
            # 추가 로직으로 Master/Slave 구분 필요
            return 0  # 임시로 연결 가능하면 Master로 간주
        else
            return 1
        fi
    fi
    
    if [ "$recovery_status" = "f" ]; then
        return 0  # Master
    else
        return 1  # Slave 또는 연결 실패
    fi
}

# 1번 서버를 Master로 승격
promote_server1_to_master() {
    log_message "INFO" "1번 서버를 Master로 승격 시작"
    
    # 기존 standby.signal 파일 제거 (있다면)
    docker exec rtt-postgres bash -c "rm -f /var/lib/postgresql/data/standby.signal" 2>/dev/null || true
    
    # PostgreSQL 재시작으로 Master 모드로 전환
    docker restart rtt-postgres
    
    # 승격 확인
    sleep 3
    if is_master "$SERVER1"; then
        log_message "SUCCESS" "1번 서버 Master 승격 성공"
        return 0
    else
        log_message "ERROR" "1번 서버 Master 승격 실패"
        return 1
    fi
}

# 2번 서버를 Master로 승격
promote_server2_to_master() {
    log_message "INFO" "2번 서버를 Master로 승격 시작"
    
    # 2번 서버에서 pg_promote 실행 (curl을 통한 API 호출로 대체)
    # 실제 환경에서는 SSH 또는 원격 실행 도구 필요
    log_message "INFO" "2번 서버 승격을 위해 수동 개입 필요"
    log_message "INFO" "2번 서버에서 다음 명령 실행: docker exec -i rtt-postgres psql -U postgres -c 'SELECT pg_promote();'"
    
    return 0
}

# 1번 서버를 Slave로 설정
setup_server1_as_slave() {
    log_message "INFO" "1번 서버를 Slave로 설정 시작"
    
    # PostgreSQL 중지
    docker stop rtt-postgres
    
    # 데이터 디렉토리 백업 및 정리
    docker exec rtt-postgres bash -c "rm -rf /var/lib/postgresql/data_backup && mv /var/lib/postgresql/data /var/lib/postgresql/data_backup" 2>/dev/null || true
    
    # Master(2번 서버)에서 베이스 백업
    docker exec rtt-postgres bash -c "
        PGPASSWORD=replicator_password pg_basebackup -h $SERVER2 -D /var/lib/postgresql/data -U replicator -v -P
        touch /var/lib/postgresql/data/standby.signal
        cat >> /var/lib/postgresql/data/postgresql.conf << 'EOF'
# Slave 복제 설정
primary_conninfo = 'host=$SERVER2 port=5432 user=replicator password=replicator_password application_name=slave_node'
primary_slot_name = 'slave_slot'
EOF
    "
    
    # PostgreSQL 시작
    docker start rtt-postgres
    
    log_message "SUCCESS" "1번 서버 Slave 설정 완료"
}

# 메인 모니터링 루프
main_monitor() {
    log_message "INFO" "PostgreSQL 자동 장애조치 모니터링 시작"
    log_message "INFO" "서버1: $SERVER1"
    log_message "INFO" "서버2: $SERVER2"
    log_message "INFO" "체크 간격: ${CHECK_INTERVAL}초"
    
    while true; do
        local server1_alive=false
        local server2_alive=false
        local server1_is_master=false
        local server2_is_master=false
        
        # 1번 서버 상태 확인
        if check_db_status "$SERVER1"; then
            server1_alive=true
            if is_master "$SERVER1"; then
                server1_is_master=true
            fi
        fi
        
        # 2번 서버 상태 확인
        if check_db_status "$SERVER2"; then
            server2_alive=true
            if is_master "$SERVER2"; then
                server2_is_master=true
            fi
        fi
        
        log_message "DEBUG" "상태체크 - 1번서버: alive=$server1_alive, master=$server1_is_master | 2번서버: alive=$server2_alive, master=$server2_is_master"
        
        # 상황별 처리
        if $server1_alive && $server2_alive; then
            # 두 서버 모두 살아있음 - 1번을 Master, 2번을 Slave로 설정
            if ! $server1_is_master; then
                log_message "INFO" "두 서버 모두 정상 - 1번 서버를 Master로 승격"
                promote_server1_to_master || log_message "ERROR" "1번 서버 Master 승격 실패"
            fi
            
        elif ! $server1_alive && $server2_alive; then
            # 1번 서버 죽음, 2번 서버 살아있음 - 2번을 Master로 승격
            if ! $server2_is_master; then
                log_message "CRITICAL" "1번 서버 장애 감지 - 2번 서버를 Master로 승격"
                promote_server2_to_master || log_message "ERROR" "2번 서버 Master 승격 실패"
            fi
            
        elif $server1_alive && ! $server2_alive; then
            # 2번 서버 죽음, 1번 서버 살아있음 - 1번을 Master로 사용
            if ! $server1_is_master; then
                log_message "WARNING" "2번 서버 장애 감지 - 1번 서버를 Master로 승격"
                promote_server1_to_master || log_message "ERROR" "1번 서버 Master 승격 실패"
            fi
            
        else
            # 두 서버 모두 죽음
            log_message "CRITICAL" "두 서버 모두 장애 상태 - 시스템 전체 다운"
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# 스크립트 종료시 정리
cleanup() {
    log_message "INFO" "PostgreSQL 자동 장애조치 모니터링 종료"
    exit 0
}

# 신호 처리
trap cleanup SIGTERM SIGINT

# 예외 처리
handle_error() {
    local line_number=$1
    local error_code=$2
    log_message "ERROR" "스크립트 오류 발생 - 라인: $line_number, 에러코드: $error_code"
}

trap 'handle_error ${LINENO} $?' ERR

# 사용법 출력
usage() {
    echo "사용법: $0 [옵션]"
    echo "옵션:"
    echo "  -h, --help          이 도움말 출력"
    echo "  -i, --interval SEC  체크 간격 설정 (기본값: 5초)"
    echo "  -l, --log FILE      로그 파일 경로"
    echo ""
    echo "예시:"
    echo "  $0                           # 기본 설정으로 실행"
    echo "  $0 -i 10                     # 10초 간격"
    echo "  $0 -l /custom/path/log.txt  # 커스텀 로그 파일"
}

# 명령행 인수 처리
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -i|--interval)
            CHECK_INTERVAL="$2"
            shift 2
            ;;
        -l|--log)
            LOG_FILE="$2"
            shift 2
            ;;
        *)
            echo "알 수 없는 옵션: $1"
            usage
            exit 1
            ;;
    esac
done

# 로그 디렉토리 생성
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || {
    echo "로그 디렉토리 생성 실패, 기본 경로 사용: ./postgres-failover.log"
    LOG_FILE="./postgres-failover.log"
}

# 메인 실행
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_monitor
fi