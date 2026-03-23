# RaySpeaki 部署指南

## 架构概览

```
浏览器
 ├── HTTP / WebSocket ──→ app容器:4000  (Node.js MediaSoup SFU + 网页客户端)
 │                            └── 内部代理 ──→ goapi容器:3000 (Go REST API)
 └── WebRTC ────────────→ app容器 (MediaSoup + coturn TURN中继)

app容器内部：
  supervisord
  ├── Node.js (MediaSoup + Socket.IO)
  └── coturn  (STUN/TURN，IP在启动时自动检测)
```

## 快速开始

### 1. 准备配置

```bash
cp .env.example .env
```

编辑 `.env`，至少修改以下内容：

```env
SERVER_PASSWORD=你的服务器密码    # 普通用户登录密码
ADMIN_PASSWORD=你的管理员密码      # 管理员密码（可创建/删除频道）
DB_PASSWORD=数据库密码
TURN_CREDENTIAL=TURN服务器密码
```

### 2. 启动

```bash
docker compose up -d --build
```

首次启动会编译 Go、Node.js 和 Web 客户端，需要 5-15 分钟。

### 3. 访问

打开浏览器访问：`http://你的服务器IP:4000`

---

## 端口说明

| 端口 | 协议 | 用途 |
|------|------|------|
| 4000 | TCP | 网页客户端 + Socket.IO 信令 |
| 3000 | TCP | Go REST API（可仅内网暴露） |
| 3478 | UDP | STUN/TURN |
| 40000-40100 | UDP | MediaSoup WebRTC RTP |
| 49152-65535 | UDP | TURN 中继端口 |

> 防火墙需要放行以上所有端口。

---

## 动态 IP 处理

`app` 容器每次启动时自动从 `ipify.org` 获取当前公网 IP，无需手动配置。

当公网 IP 变化后，只需重启容器：

```bash
docker restart rayspeaki-app
```

如果服务器无法访问 ipify（无公网出口），在 `.env` 中手动指定 IP：

```env
MEDIASOUP_ANNOUNCED_IP=1.2.3.4
```

---

## 数据持久化

数据存储在 Docker named volumes 中：

- `rayspeaki_postgres_data` — 用户、频道数据
- `rayspeaki_redis_data` — 会话数据

备份：
```bash
docker run --rm -v rayspeaki_postgres_data:/data -v $(pwd):/backup \
  alpine tar czf /backup/postgres_backup.tar.gz -C /data .
```

恢复：
```bash
docker run --rm -v rayspeaki_postgres_data:/data -v $(pwd):/backup \
  alpine tar xzf /backup/postgres_backup.tar.gz -C /data
```

---

## 常用命令

```bash
# 查看所有容器状态
docker compose ps

# 查看日志
docker compose logs -f app
docker compose logs -f goapi

# 重启单个服务
docker restart rayspeaki-app
docker restart rayspeaki-api

# 停止
docker compose down

# 停止并删除数据（危险！）
docker compose down -v
```

---

## 从旧版本（LiveKit）迁移

旧版数据库结构与新版兼容，Go API 启动时会自动创建缺少的表，已有数据不受影响。

如果旧版 PostgreSQL 数据需要迁移：
1. 从旧环境导出：`docker exec rayspeaki-db pg_dump -U rayspeaki rayspeaki > old_data.sql`
2. 导入新环境：`docker exec -i rayspeaki-db psql -U rayspeaki rayspeaki < old_data.sql`

---

## TrueNAS 部署

将 `docker-compose.yml` 和 `.env` 放置于 TrueNAS 的 App 目录，
volumes 路径会自动映射到 TrueNAS 数据集。

若使用外部路径挂载数据（替代 named volumes），在 `docker-compose.yml` 中
修改 volumes 部分：

```yaml
volumes:
  postgres_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/SSD/appdata/rayspeaki/postgres
  redis_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/SSD/appdata/rayspeaki/redis
```
