#!/bin/bash
# OCI 免费 ARM 实例自动抢机脚本（Docker 版）
# 所有配置通过环境变量传入

# ============ 从环境变量读取配置 ============
COMPARTMENT_ID="${OCI_COMPARTMENT_ID}"
SUBNET_ID="${OCI_SUBNET_ID}"
IMAGE_ID="${OCI_IMAGE_ID}"
INSTANCE_NAME="${OCI_INSTANCE_NAME:-free-arm-instance}"

SHAPE="VM.Standard.A1.Flex"
OCPUS="${OCI_OCPUS:-1}"
MEMORY_GB="${OCI_MEMORY_GB:-6}"
BOOT_VOLUME_GB="${OCI_BOOT_VOLUME_GB:-50}"

MIN_INTERVAL="${GRAB_MIN_INTERVAL:-60}"
MAX_INTERVAL="${GRAB_MAX_INTERVAL:-120}"
MAX_ATTEMPTS="${GRAB_MAX_ATTEMPTS:-0}"

TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
BARK_URL="${BARK_URL}"

# SSH 公钥直接从环境变量传入
SSH_PUBLIC_KEY="${OCI_SSH_PUBLIC_KEY}"

# 可用性域列表（逗号分隔）
IFS=',' read -ra AVAILABILITY_DOMAINS <<< "${OCI_AVAILABILITY_DOMAINS}"

LOG_FILE="/tmp/oci-grab.log"
ATTEMPT=0

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

notify() {
    local message="$1"
    if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TG_CHAT_ID" \
            -d text="$message" > /dev/null 2>&1
    fi
    if [[ -n "$BARK_URL" ]]; then
        curl -s "${BARK_URL}/OCI抢机成功/${message}" > /dev/null 2>&1
    fi
}

check_config() {
    local missing=0
    for var in OCI_COMPARTMENT_ID OCI_SUBNET_ID OCI_IMAGE_ID OCI_SSH_PUBLIC_KEY OCI_AVAILABILITY_DOMAINS; do
        if [[ -z "${!var}" ]]; then
            log "错误: 缺少环境变量 $var"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        exit 1
    fi

    # 验证 OCI CLI 认证
    if ! oci iam region list --output table > /dev/null 2>&1; then
        log "错误: OCI CLI 认证失败，请检查 OCI 配置文件挂载"
        exit 1
    fi
    log "OCI CLI 验证通过"
    log "可用性域: ${AVAILABILITY_DOMAINS[*]}"
}

AD_INDEX=0
get_next_ad() {
    echo "${AVAILABILITY_DOMAINS[$AD_INDEX]}"
    AD_INDEX=$(( (AD_INDEX + 1) % ${#AVAILABILITY_DOMAINS[@]} ))
}

create_instance() {
    local ad="$1"
    oci compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$ad" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
        --display-name "$INSTANCE_NAME" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
        --assign-public-ip true \
        --metadata "{\"ssh_authorized_keys\": \"$SSH_PUBLIC_KEY\"}" \
        2>&1
}

main() {
    log "========================================="
    log "OCI ARM 实例自动抢机脚本启动 (Docker)"
    log "规格: $SHAPE ($OCPUS OCPU / ${MEMORY_GB}GB RAM)"
    log "重试间隔: ${MIN_INTERVAL}-${MAX_INTERVAL}秒"
    log "========================================="

    check_config

    # 启动通知
    notify "OCI 抢机脚本已启动 | 规格: ${OCPUS}C${MEMORY_GB}G | 间隔: ${MIN_INTERVAL}-${MAX_INTERVAL}s"

    while true; do
        ATTEMPT=$((ATTEMPT + 1))

        if [[ $MAX_ATTEMPTS -gt 0 && $ATTEMPT -gt $MAX_ATTEMPTS ]]; then
            log "已达最大尝试次数 $MAX_ATTEMPTS，退出"
            notify "抢机脚本已停止: 达到最大尝试次数 $MAX_ATTEMPTS"
            exit 1
        fi

        CURRENT_AD=$(get_next_ad)
        log "第 $ATTEMPT 次尝试 | 可用性域: $CURRENT_AD"

        RESULT=$(create_instance "$CURRENT_AD")
        EXIT_CODE=$?

        if [[ $EXIT_CODE -eq 0 ]]; then
            log "===== 创建请求已接受！====="

            INSTANCE_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
            log "实例 ID: $INSTANCE_ID"
            log "实例正在启动，等待获取公网 IP..."

            if [[ -n "$INSTANCE_ID" ]]; then
                for i in $(seq 1 30); do
                    sleep 20
                    STATE=$(oci compute instance get --instance-id "$INSTANCE_ID" \
                        --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
                    log "实例状态: $STATE (${i}/30)"
                    if [[ "$STATE" == "RUNNING" ]]; then
                        break
                    fi
                done

                VNIC_ATTACHMENTS=$(oci compute vnic-attachment list \
                    --compartment-id "$COMPARTMENT_ID" \
                    --instance-id "$INSTANCE_ID" 2>/dev/null)
                VNIC_ID=$(echo "$VNIC_ATTACHMENTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['vnic-id'])" 2>/dev/null)
                if [[ -n "$VNIC_ID" ]]; then
                    PUBLIC_IP=$(oci network vnic get --vnic-id "$VNIC_ID" 2>/dev/null | \
                        python3 -c "import sys,json; print(json.load(sys.stdin)['data']['public-ip'])" 2>/dev/null)
                    log "===== 抢机成功！====="
                    log "公网 IP: $PUBLIC_IP"
                    log "连接命令: ssh ubuntu@$PUBLIC_IP"
                    notify "抢机成功! IP: $PUBLIC_IP | 规格: ${OCPUS}C${MEMORY_GB}G | ssh ubuntu@$PUBLIC_IP"
                else
                    log "===== 抢机成功！====="
                    notify "抢机成功! 请登录控制台查看详情"
                fi
            else
                log "===== 抢机成功！====="
                notify "抢机成功! 请登录控制台查看详情"
            fi
            exit 0
        fi

        if echo "$RESULT" | grep -qi "out of.* capacity\|out of host capacity\|capacity for"; then
            log "容量不足，等待重试..."
        elif echo "$RESULT" | grep -qi "limit\|quota"; then
            log "错误: 已达资源限制"
            notify "抢机脚本停止: 资源限制"
            exit 1
        elif echo "$RESULT" | grep -qi "authorization\|forbidden\|401\|403"; then
            log "错误: 认证/授权失败"
            notify "抢机脚本停止: 认证失败"
            exit 1
        elif echo "$RESULT" | grep -qi "invalid\|not found\|404"; then
            log "错误: 参数有误: $RESULT"
            notify "抢机脚本停止: 参数错误"
            exit 1
        else
            log "未知错误: $RESULT"
            log "继续重试..."
        fi

        WAIT=$((RANDOM % (MAX_INTERVAL - MIN_INTERVAL + 1) + MIN_INTERVAL))
        log "等待 ${WAIT} 秒后重试..."
        sleep "$WAIT"
    done
}

main "$@"
