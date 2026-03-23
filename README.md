# RaySpeaki

Self-hosted voice chat platform — like a lightweight, self-deployable Discord voice server.

自部署语音聊天平台 —— 类似轻量级、可自行部署的 Discord 语音服务器。

---

## Features / 功能

- **Voice Channels** — Real-time voice chat powered by MediaSoup SFU (Selective Forwarding Unit)
- **Screen Sharing** — Share your screen with other users in the channel
- **Camera** — Video calls with camera support on mobile and desktop
- **RNNoise** — AI-powered noise suppression on Web and Electron clients
- **Multi-Platform** — Web, Windows (Electron), Android (Flutter) clients
- **Self-Hosted** — Deploy with Docker in minutes, own your data
- **Channel Management** — Create password-protected channels, manage members
- **TURN Server** — Built-in coturn for NAT traversal

---

- **语音频道** — 基于 MediaSoup SFU 的实时语音通话
- **屏幕共享** — 在频道内共享屏幕
- **摄像头** — 移动端和桌面端支持视频通话
- **RNNoise** — Web 和 Electron 客户端内置 AI 降噪
- **多平台** — Web、Windows（Electron）、Android（Flutter）客户端
- **自部署** — Docker 一键部署，数据完全自主
- **频道管理** — 创建加密频道、管理成员
- **TURN 服务器** — 内置 coturn，穿透 NAT

## Architecture / 架构

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   Electron   │  │  Flutter App │  │  Web Client  │
│   (Windows)  │  │  (Android)   │  │  (Browser)   │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       └─────────────────┼─────────────────┘
                         │  Socket.IO + WebRTC
                         ▼
              ┌─────────────────────┐
              │   Node.js Server    │
              │  (MediaSoup + S.IO) │
              └──────────┬──────────┘
                         │
              ┌──────────┼──────────┐
              ▼          ▼          ▼
         ┌────────┐ ┌────────┐ ┌────────┐
         │ Go API │ │ PgSQL  │ │ Redis  │
         └────────┘ └────────┘ └────────┘
```

## Tech Stack / 技术栈

| Component | Technology |
|-----------|-----------|
| Signaling Server | Node.js, Express, Socket.IO, MediaSoup 3 |
| REST API | Go, pgx, go-redis |
| Web Client | TypeScript, Vite, mediasoup-client, RNNoise |
| Desktop Client | Electron 33, mediasoup-client, RNNoise |
| Mobile Client | Flutter, flutter_webrtc, mediasoup-client |
| Database | PostgreSQL 16 |
| Cache | Redis 7 |
| TURN | coturn |
| Deployment | Docker Compose |

## Project Structure / 项目结构

```
rayspeaki/
├── server/                 # Node.js signaling + MediaSoup + coturn + web client
│   ├── server/src/         # TypeScript source
│   ├── server/web/         # Web client source
│   └── Dockerfile          # All-in-one container
├── goapi/                  # Go REST API (auth, users, channels)
├── electron/               # Electron desktop client
│   ├── src/                # Main process
│   └── renderer/           # Renderer (shared with web client)
├── flutter_client/         # Flutter Android client
│   ├── lib/                # Dart source
│   └── packages/           # Local mediasoup client package
├── docker-compose.yml      # Development deployment
├── docker-compose.truenas.yml  # TrueNAS/single-container deployment
└── .env.example            # Environment variable template
```

## Quick Start / 快速开始

### Prerequisites / 前置条件

- Docker & Docker Compose
- A server with public IP (or use TURN for NAT traversal)

### Deploy / 部署

#### Option 1: Pull from Docker Hub / 从 Docker Hub 拉取（推荐）

Pre-built image available at [`raykii/rayspeaki`](https://hub.docker.com/r/raykii/rayspeaki).

预构建镜像已发布到 Docker Hub，无需本地编译。

```bash
# Download compose file and env template
curl -O https://raw.githubusercontent.com/SumiRayki/rayspeaki/main/docker-compose.truenas.yml
curl -O https://raw.githubusercontent.com/SumiRayki/rayspeaki/main/.env.example

cp .env.example .env
# Edit .env — set your passwords / 编辑 .env 设置密码
nano .env

# Start (pulls image automatically)
docker compose -f docker-compose.truenas.yml up -d

# Access web client at http://your-server-ip:4000
```

#### Option 2: Build from source / 从源码构建

```bash
git clone https://github.com/SumiRayki/rayspeaki.git
cd rayspeaki

cp .env.example .env
# Edit .env — set your passwords and TURN credentials
nano .env

# Build and start all services
docker compose up -d --build

# Access web client at http://your-server-ip:4000
```

### Environment Variables / 环境变量

| Variable | Description | 说明 |
|----------|-------------|------|
| `SERVER_PASSWORD` | Password for user registration | 用户注册密码 |
| `ADMIN_PASSWORD` | Admin password | 管理员密码 |
| `DB_PASSWORD` | PostgreSQL password | 数据库密码 |
| `TURN_USER` | TURN server username | TURN 用户名 |
| `TURN_CREDENTIAL` | TURN server password | TURN 密码 |
| `MEDIASOUP_ANNOUNCED_IP` | Public IP (auto-detected if empty) | 公网 IP（留空自动检测） |

### Ports / 端口

| Port | Protocol | Usage | 用途 |
|------|----------|-------|------|
| 4000 | TCP | Web client + Socket.IO | Web 客户端 + 信令 |
| 3478 | UDP | STUN/TURN | NAT 穿透 |
| 40000-40100 | UDP/TCP | MediaSoup WebRTC RTP | 媒体传输 |
| 49152-49252 | UDP | TURN relay | TURN 中继 |

## Clients / 客户端

### Web Client / Web 客户端
Built into the server container. Access at `http://your-server:4000`.

内置于服务端容器，访问 `http://服务器地址:4000`。

### Electron (Windows) / 桌面客户端
Set server URL via environment variable before launching:
```bash
set RAYSPEAKI_SERVER_URL=https://your-server:4000
RaySpeaki.exe
```
Or download from [Releases](https://github.com/SumiRayki/rayspeaki/releases).

### Flutter (Android) / 安卓客户端
Download APK from [Releases](https://github.com/SumiRayki/rayspeaki/releases). Server URL can be configured on the login screen.

从 [Releases](https://github.com/SumiRayki/rayspeaki/releases) 下载 APK，服务器地址可在登录界面配置。

#### Build from source / 从源码构建
```bash
cd flutter_client
flutter pub get
flutter build apk --release
```

## License / 许可

MIT
