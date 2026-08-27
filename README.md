# 糖果屋 · Candy House

> Neo-Brutalism 风格的个人作品集单页，已从「纯静态」升级为「有增删改查的真全栈应用」：
> 数据存 MySQL，后端用 FastAPI 提供 API，前端三页（展示 / 管理 / 调试）经 Nginx 反向代理调用，
> 一套 Docker Compose 编排 db + app，并带负载均衡。本仓库也是初级运维的实战记录。

## 技术栈

- 前端：纯 HTML / CSS / JS（无构建步骤，Neo-Brutalism 风格）
- 后端：FastAPI + SQLAlchemy + PyMySQL
- 数据库：MySQL 8.0（Docker 运行）
- 编排：Docker Compose（db + app）
- 网关：Nginx（**宿主机原生运行**，反向代理 + 负载均衡 `least_conn`，不进容器）
- 部署目标：京东云 ECS

## 架构

```
浏览器 ── http://你的服务器IP:80 ──► [Nginx 宿主机]
                                      ├─ 静态文件：/   /admin.html   /debug.html
                                      └─ /api/* ──► [app 容器 ×N]  FastAPI（least_conn 负载均衡）
                                                            │
                                                            ▼
                                                  [MySQL 容器]  candy_house.works
```

> 设计取舍：Nginx 故意跑在宿主机（systemd 托管），更贴近传统运维习惯；db 与 app 跑在 Docker。

## 目录结构

```
candy-house-portfolio/
├── api/                     # FastAPI 后端
│   ├── main.py              # 入口：路由 + 审计日志中间件（记录每个 CRUD 改了什么）
│   ├── database.py          # SQLAlchemy 引擎 / 会话
│   ├── models.py            # ORM 模型（works 表）
│   ├── schemas.py           # Pydantic 出入参
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── .env.example         # 环境变量模板（复制为 .env 后填写）
│   └── .dockerignore
├── db/
│   └── init.sql             # 首次启动自动建表（无假数据）
├── nginx/
│   ├── nginx-host.conf      # 【当前生效】宿主机 Nginx 配置（反代 + 负载均衡）
│   └── nginx.conf           # 【备选】Docker 版 Nginx 配置（若改用容器跑 Nginx）
├── static/                  # 前端（纯静态）
│   ├── index.html           # 展示页
│   ├── admin.html           # 管理页（增删改查）
│   ├── debug.html           # 调试页
│   └── styles.css
├── docker/
│   └── docker-compose.yml   # 编排 db + app（Nginx 不进容器）
├── deploy/                  # 部署文档与脚本
│   ├── STEP-BY-STEP.md      # 一步一步部署手册（含日志排查）
│   ├── ops-guide.md         # 运维知识讲解
│   ├── README.md            # 部署总览
│   ├── deploy.sh            # 本地一键部署脚本（上传 + 启动）
│   ├── 404.html             # 自定义 404 页
│   └── archive/             # 已弃用配置归档（勿用）
├── .gitignore
├── .editorconfig
├── LICENSE
└── README.md
```

## 快速开始（本地开发）

需要先装好 Docker + Docker Compose。

```bash
# 1) 准备环境变量
cp api/.env.example api/.env        # 按需修改密码（仅本地开发）

# 2) 启动 db + app（app 映射 8000/8001 到本机回环）
docker compose -f docker/docker-compose.yml up -d --scale app=2

# 3) 验证后端
curl http://localhost:8000/api/health      # {"status":"ok","db":true,...}
curl http://localhost:8000/api/works       # []

# 4) 看前端（任选其一）
#    a) 直接用浏览器打开 static/index.html
#    b) 起一个静态服务器：
python -m http.server 5500 -d static       # 然后访问 http://localhost:5500/
```

> 生产环境的前端由宿主机 Nginx 直接托管（见 `nginx/nginx-host.conf`），无需单独起静态服务器。

## 环境变量

所有配置来自 `api/.env`（**不进仓库**，含生产密码）。请以 `api/.env.example` 为模板：

| 变量 | 说明 |
| --- | --- |
| `MYSQL_ROOT_PASSWORD` | MySQL root 密码（MySQL 8 强制要求，缺失起不来） |
| `MYSQL_USER` / `MYSQL_PASSWORD` | 应用使用的库账号 |
| `MYSQL_DATABASE` | 库名（默认 `candy_house`） |
| `DATABASE_URL` | SQLAlchemy 连接串；`db` 为容器内服务名 |

> ⚠️ 数据库密码不要包含 `@ : / # %` 等 URL 特殊字符，会破坏 `DATABASE_URL` 解析。

## 部署到服务器

完整步骤见 [`deploy/STEP-BY-STEP.md`](deploy/STEP-BY-STEP.md)（从零、一步一步、照抄即可），含：
安全组 / 防火墙两道放行 → 上传 → 配置 `.env` → 起 db+app → 装 Nginx → 放配置 → 校验 → 端到端验证 → **日志排查**（审计日志能看到每个 CRUD 改了什么）。

也可用 [`deploy/deploy.sh`](deploy/deploy.sh) 本地一键上传并启动（需先改脚本里的 `SERVER_IP`）。

## 日志与运维

- **后端审计日志**：每个增删改都会打印具体操作内容（字段、旧值 → 新值、真实访客 IP、耗时）。查看：
  ```bash
  docker compose -f docker/docker-compose.yml logs -f app
  ```
- **Nginx 日志**：`tail -f /var/log/nginx/access.log`（状态码）/ `error.log`（报错）。
- 更多见 [`deploy/STEP-BY-STEP.md`](deploy/STEP-BY-STEP.md) 第 11 步。

## 许可证

[MIT](LICENSE) © 2026 Candy House
