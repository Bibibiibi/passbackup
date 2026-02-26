#!/bin/bash
# ============================================================
# Vaultwarden 自动加密备份脚本
# - 检查 rclone 挂载状态，异常时自动重新挂载
# - 压缩并加密 (GPG AES-256) /root/vaultwarden
# - 上传加密备份到 rclone 挂载盘
# - 自动清理超过 30 天的旧备份（每次清理一个）
# - 发送 Telegram 通知
# ============================================================

set -euo pipefail

# -------------------- 配置区 --------------------
VAULTWARDEN_DIR="/root/vaultwarden"
MOUNT_POINT="/root/passbackup"
BACKUP_DIR="${MOUNT_POINT}/vaultwarden-backups"
RCLONE_REMOTE="passbackup"
KEEP_DAYS=30

# 加密配置 (GPG 对称加密 AES-256)
ENCRYPT_PASSPHRASE="改成自己喜欢的密码"

# Telegram 通知配置
TG_BOT_TOKEN="改成自己的token"
TG_CHAT_ID="改成自己的tgid"

# 时间戳和路径
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="vaultwarden_${TIMESTAMP}.tar.gz.gpg"
TMP_DIR=$(mktemp -d /tmp/vw-backup.XXXXXX)
HOSTNAME=$(hostname)
LOG_PREFIX="[vaultwarden-backup]"

# -------------------- 函数定义 --------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $1"
}

send_tg() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="HTML" \
        > /dev/null 2>&1 || log "警告: Telegram 通知发送失败"
}

check_mount() {
    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        return 0
    fi
    # 用 df 再次确认
    if df -h "${MOUNT_POINT}" 2>/dev/null | grep -q "fuse\|rclone"; then
        return 0
    fi
    return 1
}

remount_rclone() {
    log "未检测到 rclone 挂载，正在尝试重新挂载..."

    # 清理残留挂载
    fusermount -uz "${MOUNT_POINT}" 2>/dev/null || true
    sleep 2

    # 确保挂载点目录存在
    mkdir -p "${MOUNT_POINT}"

    # 重新挂载
    rclone mount "${RCLONE_REMOTE}:" "${MOUNT_POINT}" \
        --allow-other \
        --vfs-cache-mode full \
        --vfs-cache-max-size 10G \
        --buffer-size 256M \
        --dir-cache-time 72h \
        --poll-interval 15s \
        --umask 000 \
        --daemon

    # 等待挂载就绪
    local retries=0
    local max_retries=15
    while [ $retries -lt $max_retries ]; do
        sleep 2
        if check_mount; then
            log "rclone 重新挂载成功"
            send_tg "🔄 <b>[${HOSTNAME}] rclone 重新挂载成功</b>
挂载点: <code>${MOUNT_POINT}</code>
时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 0
        fi
        retries=$((retries + 1))
        log "等待挂载中... (${retries}/${max_retries})"
    done

    log "错误: 重试 ${max_retries} 次后仍无法挂载 rclone"
    send_tg "🚨 <b>[${HOSTNAME}] rclone 挂载失败!</b>
挂载点: <code>${MOUNT_POINT}</code>
已尝试 ${max_retries} 次，均未成功
时间: $(date '+%Y-%m-%d %H:%M:%S')
⚠️ 备份已中止，请手动检查!"
    return 1
}

cleanup_old_backups() {
    log "检查超过 ${KEEP_DAYS} 天的旧备份..."
    local oldest
    oldest=$(ls -1t "${BACKUP_DIR}"/vaultwarden_*.tar.gz.gpg 2>/dev/null | tail -n 1)

    if [ -z "$oldest" ]; then
        log "未找到备份文件，跳过清理"
        return
    fi

    # 检查最旧备份是否超过保留天数
    local now
    now=$(date +%s)
    local file_mtime
    file_mtime=$(stat -c %Y "$oldest" 2>/dev/null || stat -f %m "$oldest" 2>/dev/null)
    local age_days=$(( (now - file_mtime) / 86400 ))

    if [ "$age_days" -gt "$KEEP_DAYS" ]; then
        log "删除最旧备份 (${age_days} 天前): $(basename "$oldest")"
        rm -f "$oldest"
        log "清理完成"
    else
        log "无需清理 (最旧备份为 ${age_days} 天前)"
    fi
}

cleanup_tmp() {
    rm -rf "${TMP_DIR}"
}

# -------------------- 主流程 --------------------

# 确保临时目录始终被清理
trap cleanup_tmp EXIT

log "========== 备份开始 =========="

# 步骤 1: 检查 rclone 挂载
if ! check_mount; then
    if ! remount_rclone; then
        log "备份中止: rclone 挂载不可用"
        exit 1
    fi
fi

log "rclone 挂载正常: ${MOUNT_POINT}"

# 步骤 2: 确保备份目录存在
mkdir -p "${BACKUP_DIR}"

# 步骤 3: 检查 Vaultwarden 数据目录
if [ ! -d "${VAULTWARDEN_DIR}" ]; then
    log "错误: Vaultwarden 数据目录不存在: ${VAULTWARDEN_DIR}"
    send_tg "❌ <b>[${HOSTNAME}] Vaultwarden 备份失败!</b>
原因: 数据目录不存在
路径: <code>${VAULTWARDEN_DIR}</code>
时间: $(date '+%Y-%m-%d %H:%M:%S')"
    exit 1
fi

# 步骤 4: 压缩
log "正在压缩 Vaultwarden 数据..."
TMP_TAR="${TMP_DIR}/vaultwarden_${TIMESTAMP}.tar.gz"

if ! tar -czf "${TMP_TAR}" -C "$(dirname "${VAULTWARDEN_DIR}")" "$(basename "${VAULTWARDEN_DIR}")"; then
    log "错误: 压缩失败"
    send_tg "❌ <b>[${HOSTNAME}] Vaultwarden 备份失败!</b>
原因: tar 压缩过程出错
源目录: <code>${VAULTWARDEN_DIR}</code>
时间: $(date '+%Y-%m-%d %H:%M:%S')
⚠️ 请手动检查磁盘空间和文件权限!"
    exit 1
fi

log "压缩完成: $(du -h "${TMP_TAR}" | cut -f1)"

# 步骤 5: 使用 GPG (AES-256) 加密
log "正在使用 GPG AES-256 加密..."
TMP_ENC="${TMP_DIR}/${BACKUP_FILE}"

if ! gpg --batch --yes --passphrase "${ENCRYPT_PASSPHRASE}" \
        --symmetric --cipher-algo AES256 \
        -o "${TMP_ENC}" "${TMP_TAR}"; then
    log "错误: 加密失败"
    send_tg "❌ <b>[${HOSTNAME}] Vaultwarden 备份失败!</b>
原因: GPG 加密过程出错
时间: $(date '+%Y-%m-%d %H:%M:%S')"
    exit 1
fi

# 立即删除未加密的压缩包
rm -f "${TMP_TAR}"
BACKUP_SIZE=$(du -h "${TMP_ENC}" | cut -f1)
log "加密完成: ${BACKUP_FILE} (${BACKUP_SIZE})"

# 步骤 6: 上传加密备份到 rclone 挂载盘
log "正在上传加密备份到 rclone 挂载盘..."
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"

if ! cp "${TMP_ENC}" "${BACKUP_PATH}"; then
    log "错误: 拷贝加密备份到挂载盘失败"
    send_tg "❌ <b>[${HOSTNAME}] Vaultwarden 备份失败!</b>
原因: 拷贝到 rclone 挂载盘出错
时间: $(date '+%Y-%m-%d %H:%M:%S')
⚠️ 请检查挂载状态和磁盘空间!"
    exit 1
fi

log "上传完成"

# 步骤 7: 清理旧备份
cleanup_old_backups

# 统计剩余备份数
REMAINING=$(ls -1 "${BACKUP_DIR}"/vaultwarden_*.tar.gz.gpg 2>/dev/null | wc -l)

# 步骤 8: 发送成功通知
send_tg "✅ <b>[${HOSTNAME}] Vaultwarden 备份成功</b>
🔒 已加密 (GPG AES-256)
文件: <code>${BACKUP_FILE}</code>
大小: ${BACKUP_SIZE}
路径: <code>${BACKUP_DIR}</code>
当前备份数: ${REMAINING} (保留 ${KEEP_DAYS} 天)
时间: $(date '+%Y-%m-%d %H:%M:%S')"

log "备份全部完成"
log "========== 备份结束 =========="
