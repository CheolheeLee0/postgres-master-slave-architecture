#!/bin/bash
# PostgreSQL Master-Slave 자동 장애조치 스크립트
# 운영1서버: 10.164.32.91 (Primary Master)
# 운영2서버: 10.164.32.92 (Primary Slave)

set -e

# 설정 변수
PRIMARY_MASTER="10.164.32.91"
PRIMARY_SLAVE="10.164.32.92"
CHECK_INTERVAL=30  # 30초마다 체크
MAX_RETRY=3       # 최대 재시도 횟수
LOG_FILE="/var/log/postgres-failover.log"

# 로그 함수
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# 서버 상태 확인 함수 (웹 서비스 기반)
check_server_status() {
    local server_ip="$1"
    local service_name="$2"
    
    if curl -f -s "http://$server_ip:80" > /dev/null 2>&1; then
        return 0  # 서버 정상
    else
        return 1  # 서버 장애
    fi
}

# DB 상태 확인 함수
check_db_status() {
    local server_ip="$1"
    
    # Docker를 통한 DB 상태 확인
    if [ "$server_ip" = "$PRIMARY_MASTER" ]; then
        # 1번 서버에서 실행
        if ssh "$server_ip" "docker exec -i rtt-postgres psql -U postgres -c 'SELECT 1;'" > /dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    else
        # 2번 서버에서 실행
        if ssh "$server_ip" "docker exec -i rtt-postgres psql -U postgres -c 'SELECT 1;'" > /dev/null 2>&1; then
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
    if [ "$server_ip" = "$PRIMARY_MASTER" ]; then
        recovery_status=$(ssh "$server_ip" "docker exec -i rtt-postgres psql -U postgres -t -c 'SELECT pg_is_in_recovery();'" 2>/dev/null | tr -d ' ')
    else
        recovery_status=$(ssh "$server_ip" "docker exec -i rtt-postgres psql -U postgres -t -c 'SELECT pg_is_in_recovery();'" 2>/dev/null | tr -d ' ')
    fi
    
    if [ "$recovery_status" = "f" ]; then
        return 0  # Master
    else
        return 1  # Slave 또는 연결 실패
    fi
}

# Slave 승격 함수
promote_slave() {
    local slave_ip="$1"
    
    log_message "INFO" "Slave 승격 시작: $slave_ip"
    
    # Slave를 Master로 승격
    if ssh "$slave_ip" "docker exec -i rtt-postgres psql -U postgres -c 'SELECT pg_promote();'" > /dev/null 2>&1; then
        log_message "INFO" "Slave 승격 명령 실행 완료"
        
        # 승격 확인 (최대 30초 대기)
        local wait_count=0
        while [ $wait_count -lt 30 ]; do
            if is_master "$slave_ip"; then
                log_message "SUCCESS" "Slave 승격 성공: $slave_ip가 새로운 Master가 됨"
                return 0
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        log_message "ERROR" "Slave 승격 시간 초과"
        return 1
    else
        log_message "ERROR" "Slave 승격 명령 실패"
        return 1
    fi
}

# 알림 발송 함수 (선택사항)
send_notification() {
    local event="$1"
    local message="$2"
    
    # 여기에 슬랙, 이메일, SMS 등의 알림 로직 추가 가능
    log_message "NOTIFICATION" "$event: $message"
    
    # 예시: 슬랙 웹훅 (실제 환경에서는 웹훅 URL 설정 필요)
    # curl -X POST -H 'Content-type: application/json' \
    #   --data "{\"text\":\"$event: $message\"}" \
    #   YOUR_SLACK_WEBHOOK_URL
}

# 메인 모니터링 루프
main_monitor() {
    log_message "INFO" "PostgreSQL 자동 장애조치 모니터링 시작"
    log_message "INFO" "Primary Master: $PRIMARY_MASTER"
    log_message "INFO" "Primary Slave: $PRIMARY_SLAVE"
    log_message "INFO" "체크 간격: ${CHECK_INTERVAL}초"
    
    local consecutive_failures=0
    
    while true; do
        log_message "DEBUG" "Master 서버 상태 체크 시작"
        
        # Primary Master 상태 확인
        if check_server_status "$PRIMARY_MASTER" "Master"; then
            if check_db_status "$PRIMARY_MASTER"; then
                if is_master "$PRIMARY_MASTER"; then
                    # Master 정상
                    consecutive_failures=0
                    log_message "DEBUG" "Master 서버 정상: $PRIMARY_MASTER"
                else
                    log_message "WARNING" "Master 서버가 Slave 모드로 실행 중: $PRIMARY_MASTER"
                fi
            else
                # DB만 장애
                log_message "WARNING" "Master 서버 DB 장애: $PRIMARY_MASTER"
                consecutive_failures=$((consecutive_failures + 1))
            fi
        else
            # 서버 전체 장애
            log_message "ERROR" "Master 서버 장애: $PRIMARY_MASTER"
            consecutive_failures=$((consecutive_failures + 1))
        fi
        
        # 연속 장애 발생시 자동 승격 실행
        if [ $consecutive_failures -ge $MAX_RETRY ]; then
            log_message "CRITICAL" "Master 서버 $consecutive_failures회 연속 장애, 자동 승격 시작"
            send_notification "FAILOVER_START" "Master 장애로 인한 자동 승격 시작"
            
            # Slave 상태 확인 후 승격
            if check_server_status "$PRIMARY_SLAVE" "Slave"; then
                if check_db_status "$PRIMARY_SLAVE"; then
                    if promote_slave "$PRIMARY_SLAVE"; then
                        send_notification "FAILOVER_SUCCESS" "Slave 승격 성공: $PRIMARY_SLAVE"
                        log_message "SUCCESS" "자동 장애조치 완료"
                        
                        # 역할 교체: 기존 Slave가 새로운 Master가 됨
                        local temp="$PRIMARY_MASTER"
                        PRIMARY_MASTER="$PRIMARY_SLAVE"
                        PRIMARY_SLAVE="$temp"
                        
                        log_message "INFO" "역할 교체 완료 - 새 Master: $PRIMARY_MASTER, 새 Slave: $PRIMARY_SLAVE"
                        consecutive_failures=0
                    else
                        send_notification "FAILOVER_FAILED" "Slave 승격 실패"
                        log_message "ERROR" "자동 장애조치 실패"
                    fi
                else
                    log_message "ERROR" "Slave DB도 장애 상태, 승격 불가"
                    send_notification "SYSTEM_DOWN" "Master, Slave 모두 장애"
                fi
            else
                log_message "ERROR" "Slave 서버도 장애 상태, 승격 불가"
                send_notification "SYSTEM_DOWN" "Master, Slave 모두 장애"
            fi
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

# 사용법 출력
usage() {
    echo "사용법: $0 [옵션]"
    echo "옵션:"
    echo "  -h, --help          이 도움말 출력"
    echo "  -i, --interval SEC  체크 간격 설정 (기본값: 30초)"
    echo "  -r, --retry COUNT   최대 재시도 횟수 (기본값: 3)"
    echo "  -l, --log FILE      로그 파일 경로"
    echo ""
    echo "예시:"
    echo "  $0                           # 기본 설정으로 실행"
    echo "  $0 -i 60 -r 5               # 60초 간격, 5회 재시도"
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
        -r|--retry)
            MAX_RETRY="$2"
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
mkdir -p "$(dirname "$LOG_FILE")"

# 메인 실행
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_monitor
fi