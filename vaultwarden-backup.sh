#!/bin/bash
# ============================================================
# Vaultwarden Auto Backup Script
# - Checks rclone mount, auto-remounts if needed
# - Compresses and backs up /root/vaultwarden
# - Removes backups older than 30 days (one at a time)
# - Sends Telegram notifications
# ============================================================

set -euo pipefail

# -------------------- Configuration --------------------
VAULTWARDEN_DIR="/root/vaultwarden"
MOUNT_POINT="/root/passbackup"
BACKUP_DIR="${MOUNT_POINT}/vaultwarden-backups"
RCLONE_REMOTE="passbackup"
KEEP_DAYS=30

# Telegram
TG_BOT_TOKEN="8299003585:AAGJSLWShUpglLtQol_uBZdu6O4GggOaLiA"
TG_CHAT_ID="548957896"

# Timestamp
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="vaultwarden_${TIMESTAMP}.tar.gz"
HOSTNAME=$(hostname)
LOG_PREFIX="[vaultwarden-backup]"

# -------------------- Functions --------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $1"
}

send_tg() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="HTML" \
        > /dev/null 2>&1 || log "WARNING: Telegram notification failed"
}

check_mount() {
    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        return 0
    fi
    # Double check with df
    if df -h "${MOUNT_POINT}" 2>/dev/null | grep -q "fuse\|rclone"; then
        return 0
    fi
    return 1
}

remount_rclone() {
    log "rclone mount not detected, attempting to remount..."

    # Clean up stale mount
    fusermount -uz "${MOUNT_POINT}" 2>/dev/null || true
    sleep 2

    # Ensure mount point directory exists
    mkdir -p "${MOUNT_POINT}"

    # Remount
    rclone mount "${RCLONE_REMOTE}:" "${MOUNT_POINT}" \
        --allow-other \
        --vfs-cache-mode full \
        --vfs-cache-max-size 10G \
        --buffer-size 256M \
        --dir-cache-time 72h \
        --poll-interval 15s \
        --umask 000 \
        --daemon

    # Wait for mount to become available
    local retries=0
    local max_retries=15
    while [ $retries -lt $max_retries ]; do
        sleep 2
        if check_mount; then
            log "rclone remounted successfully"
            send_tg "🔄 <b>[${HOSTNAME}] rclone 重新挂载成功</b>
挂载点: <code>${MOUNT_POINT}</code>
时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 0
        fi
        retries=$((retries + 1))
        log "Waiting for mount... (${retries}/${max_retries})"
    done

    log "ERROR: Failed to remount rclone after ${max_retries} retries"
    send_tg "🚨 <b>[${HOSTNAME}] rclone 挂载失败!</b>
挂载点: <code>${MOUNT_POINT}</code>
已尝试 ${max_retries} 次，均未成功
时间: $(date '+%Y-%m-%d %H:%M:%S')
⚠️ 备份已中止，请手动检查!"
    return 1
}

cleanup_old_backups() {
    log "Checking for backups older than ${KEEP_DAYS} days..."
    local oldest
    oldest=$(ls -1t "${BACKUP_DIR}"/vaultwarden_*.tar.gz 2>/dev/null | tail -n 1)

    if [ -z "$oldest" ]; then
        log "No backups found, skipping cleanup"
        return
    fi

    # Check if the oldest backup is older than KEEP_DAYS
    local now
    now=$(date +%s)
    local file_mtime
    file_mtime=$(stat -c %Y "$oldest" 2>/dev/null || stat -f %m "$oldest" 2>/dev/null)
    local age_days=$(( (now - file_mtime) / 86400 ))

    if [ "$age_days" -gt "$KEEP_DAYS" ]; then
        log "Deleting oldest backup (${age_days} days old): $(basename "$oldest")"
        rm -f "$oldest"
        log "Cleanup done"
    else
        log "No cleanup needed (oldest backup is ${age_days} days old)"
    fi
}

# -------------------- Main --------------------

log "========== Backup started =========="

# Step 1: Check rclone mount
if ! check_mount; then
    if ! remount_rclone; then
        log "Backup aborted: rclone mount unavailable"
        exit 1
    fi
fi

log "rclone mount is active at ${MOUNT_POINT}"

# Step 2: Ensure backup directory exists
mkdir -p "${BACKUP_DIR}"

# Step 3: Check vaultwarden directory
if [ ! -d "${VAULTWARDEN_DIR}" ]; then
    log "ERROR: Vaultwarden directory not found at ${VAULTWARDEN_DIR}"
    send_tg "❌ <b>[${HOSTNAME}] Vaultwarden 备份失败!</b>
原因: 数据目录不存在
路径: <code>${VAULTWARDEN_DIR}</code>
时间: $(date '+%Y-%m-%d %H:%M:%S')"
    exit 1
fi

# Step 4: Create backup
log "Creating backup: ${BACKUP_FILE}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"

if tar -czf "${BACKUP_PATH}" -C "$(dirname "${VAULTWARDEN_DIR}")" "$(basename "${VAULTWARDEN_DIR}")"; then
    BACKUP_SIZE=$(du -h "${BACKUP_PATH}" | cut -f1)
    log "Backup created successfully: ${BACKUP_FILE} (${BACKUP_SIZE})"

    # Step 5: Clean up old backups
    cleanup_old_backups

    # Count remaining backups
    REMAINING=$(ls -1 "${BACKUP_DIR}"/vaultwarden_*.tar.gz 2>/dev/null | wc -l)

    # Step 6: Send success notification
    send_tg "✅ <b>[${HOSTNAME}] Vaultwarden 备份成功</b>
文件: <code>${BACKUP_FILE}</code>
大小: ${BACKUP_SIZE}
路径: <code>${BACKUP_DIR}</code>
当前备份数: ${REMAINING} (保留 ${KEEP_DAYS} 天)
时间: $(date '+%Y-%m-%d %H:%M:%S')"

    log "Backup completed successfully"
else
    log "ERROR: Backup creation failed"
    # Clean up incomplete backup file
    rm -f "${BACKUP_PATH}"

    send_tg "❌ <b>[${HOSTNAME}] Vaultwarden 备份失败!</b>
原因: tar 压缩过程出错
源目录: <code>${VAULTWARDEN_DIR}</code>
时间: $(date '+%Y-%m-%d %H:%M:%S')
⚠️ 请手动检查磁盘空间和文件权限!"
    exit 1
fi

log "========== Backup finished =========="
