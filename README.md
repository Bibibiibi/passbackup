# Vaultwarden 备份脚本 — 部署指南

## 文件

- [vaultwarden-backup.sh](file:///Users/dogdi/.gemini/antigravity/scratch/vaultwarden-backup/vaultwarden-backup.sh) — 主备份脚本

## 功能

| 功能 | 说明 |
|---|---|
| rclone 挂载检测 | 自动检查 `/root/passbackup` 是否挂载 |
| 自动重新挂载 | 挂载掉线时自动重挂，最多重试 15 次 |
| 压缩备份 | `tar.gz` 打包整个 `/root/vaultwarden` |
| 备份清理 | 自动保留最近 3 次备份 |
| Telegram 通知 | ✅ 成功 / ❌ 失败 / 🔄 重挂成功 / 🚨 挂载失败 |

## 部署步骤

### 1. 上传脚本到服务器

```bash
scp /Users/dogdi/.gemini/antigravity/scratch/vaultwarden-backup/vaultwarden-backup.sh root@你的服务器IP:/root/
```

### 2. 赋予执行权限

```bash
chmod +x /root/vaultwarden-backup.sh
```

### 3. 手动测试

```bash
bash /root/vaultwarden-backup.sh
```

检查：
- Telegram 是否收到通知
- `/root/passbackup/vaultwarden-backups/` 是否有备份文件

### 4. 添加 cron 定时任务

```bash
crontab -e
```

添加以下行（每天凌晨 3:00 执行）：

```cron
0 3 * * * /root/vaultwarden-backup.sh >> /var/log/vaultwarden-backup.log 2>&1
```

### 5. 测试自动重挂功能（可选）

```bash
# 手动卸载挂载
fusermount -uz /root/passbackup

# 运行脚本，应自动重新挂载并发送通知
bash /root/vaultwarden-backup.sh
```

## 日志

备份日志记录在 `/var/log/vaultwarden-backup.log`，可随时查看：

```bash
tail -50 /var/log/vaultwarden-backup.log
```
