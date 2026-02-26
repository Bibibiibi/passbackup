#!/bin/bash
# ============================================================
# Vaultwarden 恢复脚本
# - 将加密备份 (.tar.gz.gpg) 放入恢复目录
# - 运行此脚本自动解密并恢复
# ============================================================

set -euo pipefail

# -------------------- 配置区 --------------------
# 备份文件存放目录（将 .tar.gz.gpg 放在这里）
RESTORE_DIR="/root/vaultwarden-restore"

# Vaultwarden 数据恢复目标路径
RESTORE_TARGET="/root/vaultwarden"

# 加密密码（必须与备份时使用的密码一致）
ENCRYPT_PASSPHRASE="改成跟backup的密码一致"

# -------------------- 函数定义 --------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [vaultwarden-restore] $1"
}

cleanup_tmp() {
    [ -n "${TMP_DIR:-}" ] && rm -rf "${TMP_DIR}"
}

# -------------------- 主流程 --------------------

trap cleanup_tmp EXIT

log "========== 恢复开始 =========="

# 步骤 1: 检查恢复目录
if [ ! -d "${RESTORE_DIR}" ]; then
    log "恢复目录不存在，正在创建: ${RESTORE_DIR}"
    mkdir -p "${RESTORE_DIR}"
    log "请将加密备份文件 (.tar.gz.gpg) 放入 ${RESTORE_DIR} 后重新运行此脚本"
    exit 0
fi

# 步骤 2: 查找备份文件
BACKUP_FILES=($(ls -1t "${RESTORE_DIR}"/vaultwarden_*.tar.gz.gpg 2>/dev/null || true))

if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
    log "错误: 在 ${RESTORE_DIR} 中未找到备份文件 (*.tar.gz.gpg)"
    log "请将加密备份文件放入 ${RESTORE_DIR} 后重新运行此脚本"
    exit 1
fi

# 步骤 3: 让用户选择备份文件
if [ ${#BACKUP_FILES[@]} -eq 1 ]; then
    SELECTED="${BACKUP_FILES[0]}"
    log "找到 1 个备份文件: $(basename "${SELECTED}")"
else
    echo ""
    echo "找到 ${#BACKUP_FILES[@]} 个备份文件 (最新的在前):"
    echo "──────────────────────────────────────────────────"
    for i in "${!BACKUP_FILES[@]}"; do
        local_size=$(du -h "${BACKUP_FILES[$i]}" | cut -f1)
        echo "  [$((i+1))] $(basename "${BACKUP_FILES[$i]}") (${local_size})"
    done
    echo "──────────────────────────────────────────────────"
    echo ""
    read -r -p "请选择要恢复的文件 [1-${#BACKUP_FILES[@]}, 默认=1 (最新)]: " choice
    choice=${choice:-1}

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#BACKUP_FILES[@]} ]; then
        log "错误: 无效的选择"
        exit 1
    fi

    SELECTED="${BACKUP_FILES[$((choice-1))]}"
fi

log "已选择: $(basename "${SELECTED}")"

# 步骤 4: 如果目标目录已存在，确认是否覆盖
if [ -d "${RESTORE_TARGET}" ]; then
    echo ""
    echo "⚠️  警告: ${RESTORE_TARGET} 已存在!"
    echo "   恢复操作将会覆盖现有数据。"
    echo ""
    read -r -p "是否继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "用户取消恢复"
        exit 0
    fi
    # 以防万一，先备份现有数据
    EXISTING_BACKUP="${RESTORE_TARGET}.pre-restore.$(date +%Y%m%d_%H%M%S)"
    log "备份现有数据到: ${EXISTING_BACKUP}"
    mv "${RESTORE_TARGET}" "${EXISTING_BACKUP}"
fi

# 步骤 5: 创建临时目录并解密
TMP_DIR=$(mktemp -d /tmp/vw-restore.XXXXXX)
log "正在解密备份..."

if ! gpg --batch --yes --passphrase "${ENCRYPT_PASSPHRASE}" \
        --decrypt "${SELECTED}" > "${TMP_DIR}/backup.tar.gz"; then
    log "错误: 解密失败! 请检查密码是否正确。"
    exit 1
fi

log "解密成功"

# 步骤 6: 解压
log "正在解压到 ${RESTORE_TARGET}..."
mkdir -p "$(dirname "${RESTORE_TARGET}")"

if ! tar -xzf "${TMP_DIR}/backup.tar.gz" -C "$(dirname "${RESTORE_TARGET}")"; then
    log "错误: 解压失败"
    exit 1
fi

log "解压成功"

# 步骤 7: 验证恢复结果
if [ -d "${RESTORE_TARGET}" ]; then
    FILE_COUNT=$(find "${RESTORE_TARGET}" -type f | wc -l)
    DIR_SIZE=$(du -sh "${RESTORE_TARGET}" | cut -f1)
    log "✅ 恢复完成!"
    log "   路径:  ${RESTORE_TARGET}"
    log "   文件数: ${FILE_COUNT}"
    log "   大小:  ${DIR_SIZE}"
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "  ✅ Vaultwarden 数据恢复成功!"
    echo "  📁 路径: ${RESTORE_TARGET}"
    echo "  📊 文件数: ${FILE_COUNT} | 大小: ${DIR_SIZE}"
    echo ""
    echo "  🔧 接下来你可能需要:"
    echo "     1. 启动 Vaultwarden 容器"
    echo "     2. 检查数据完整性"
    echo "══════════════════════════════════════════════════"
else
    log "错误: 解压后未找到目标目录"
    log "备份文件的目录结构可能不同"
    log "请检查 ${TMP_DIR} 中的解压内容"
    trap - EXIT  # 保留临时目录供检查
    exit 1
fi

log "========== 恢复结束 =========="
