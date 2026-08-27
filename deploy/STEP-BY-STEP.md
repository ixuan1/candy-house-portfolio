# 糖果屋部署操作手册（一步一步，照抄即可）

> 本手册只讲「一条能跑通的路」：  
> **MySQL + 后端(FastAPI) 跑在 Docker；Nginx 跑在宿主机**（你选的方案）。  
> 从零开始，按顺序执行第 0 步到第 10 步，每步都有「执行命令 + 怎么验证」。

---

## 约定（先读）

- `<公网IP>`：换成你京东云服务器的公网 IP。
- `本地终端`：你 Windows 上的命令行（推荐 **Git Bash**，PowerShell 也行）。
- `服务器`：你 `ssh` 进去后的命令行。
- 命令里如果看到 `sudo`，说明你当前不是 root；用 root 登录可省去。
- 两条红线（少一条都访问不了）：
  1. 京东云**安全组**要放行 80（和 22）。
  2. 服务器**系统防火墙**要放行 80（下面第 6 步会做）。

---

## 第 0 步：京东云控制台放行安全组（不在命令行操作）

1. 登录京东云控制台 → 找到你的云主机 → **安全组** → 入站规则。
2. 放行两条：
   - `TCP 22` （SSH，你已经能登录说明已开）
   - `TCP 80` （网站访问，最常被漏掉）
3. 保存。

> 这是「云的第一道墙」。没放行 80，后面全白搭。

---

## 第 1 步：SSH 登录服务器

```bash
# 本地终端执行
ssh root@<公网IP>
```

连上后，后面的命令都在「服务器」里敲。

---

## 第 2 步：安装 Docker（含 Compose 插件）

```bash
# 服务器执行（一键装，CentOS / Ubuntu 通用）
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# 验证
docker --version
docker compose version
```

- 看到 `Docker version ...` 和 `Docker Compose version v2...` 即成功。
- 如果 `docker compose version` 报错说找不到插件，补装：
  - Ubuntu：`apt install -y docker-compose-plugin`
  - CentOS：`yum install -y docker-compose-plugin`

---

## 第 3 步：把项目传到服务器

方式 A（推荐，一次性传整个目录）：

```bash
# 本地终端执行（Git Bash 用 /f/... 这种路径；PowerShell 直接用 F:\...）
scp -r /f/005_code/WORKbuddy/candy-house-portfolio root@<公网IP>:/opt/candy-house-portfolio
```

方式 B（如果目录已存在，只更新改过的文件）：

```bash
scp /f/005_code/WORKbuddy/candy-house-portfolio/docker/docker-compose.yml root@<公网IP>:/opt/candy-house-portfolio/docker/
scp /f/005_code/WORKbuddy/candy-house-portfolio/nginx/nginx-host.conf root@<公网IP>:/opt/candy-house-portfolio/nginx/
```

回到服务器确认结构：

```bash
# 服务器执行
ls /opt/candy-house-portfolio
# 期望看到：api  db  deploy  docker  nginx  static  README.md
```



---

## 第 4 步：配置 .env 密码（必做）

```bash
# 服务器执行
cd /opt/candy-house-portfolio
cp api/.env.example api/.env
vi api/.env
```

把文件里所有 `change_me_strong` / `root_strong_please_change` 改成你自己的强密码（两处密码要一致）。  
改完确认有这一行（**MySQL 8 强制要求，缺失会起不来**）：

```
MYSQL_ROOT_PASSWORD=你改后的强密码
```

> 记住：这份 `api/.env` 是「密码唯一来源」，db 和 app 都读它，所以只要改这一处。

---

## 第 5 步：启动 MySQL + 后端（Docker）

```bash
# 服务器执行（务必在项目根目录 /opt/candy-house-portfolio 下运行）
cd /opt/candy-house-portfolio

# 第一次启动：清掉可能失败的数据卷，重新拉起
docker compose -f docker/docker-compose.yml down -v
docker compose -f docker/docker-compose.yml up -d --scale app=2

# 看状态（db、app-1、app-2 都应是 Up）
docker compose -f docker/docker-compose.yml ps
```

验证 MySQL 真的好了：

```bash
docker compose -f docker/docker-compose.yml exec db mysqladmin ping -h 127.0.0.1 -uroot -p"你改后的强密码"
# 期望输出：mysqld is alive
```

验证后端健康：

```bash
curl -s http://localhost:8000/api/health
# 期望输出：{"status":"ok","db":true,...}
```

> 如果 `db` 一直 `Restarting` 或 `app` 起不来：  
> `docker compose -f docker/docker-compose.yml logs db` 和 `... logs app` 看报错，多半是 `.env` 密码没配对。

---

## 第 6 步：在宿主机安装并放行 Nginx

```bash
# 服务器执行
# —— Ubuntu / Debian ——
apt update && apt install -y nginx

# —— CentOS / Rocky ——
yum install -y nginx

# 放行防火墙（系统这层，和安全组是两道）
# Ubuntu：
ufw allow 80
# CentOS：
firewall-cmd --permanent --add-port=80/tcp && firewall-cmd --reload

# 开机自启并启动
systemctl enable --now nginx
```

---

## 第 7 步：放入 Nginx 配置（用宿主机版）

```bash
# 服务器执行
cd /opt/candy-house-portfolio

# 关键点：用 nginx/nginx-host.conf（宿主机版）。deploy/nginx-candy-house.conf 是已弃用的 Docker 版旧配置，已归档到 deploy/archive/，请勿使用。
# 先确认 main 配置实际 include 哪个目录（CentOS 是 conf.d/，Ubuntu 是 sites-enabled/）
grep -n "include" /etc/nginx/nginx.conf

# —— CentOS / Rocky：放到 conf.d/ ——
cp nginx/nginx-host.conf /etc/nginx/conf.d/candy-house.conf
rm -f /etc/nginx/conf.d/default.conf

# —— Ubuntu / Debian：放到 sites-enabled/（用软链，main 配置只 include sites-enabled/*）——
cp nginx/nginx-host.conf /etc/nginx/sites-available/candy-house.conf
ln -sf /etc/nginx/sites-available/candy-house.conf /etc/nginx/sites-enabled/candy-house.conf
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/conf.d/candy-house.conf        # 避免两个发行版都放导致重复监听 80

# 把 404 错误页也放进静态目录（配置里引用了它）
cp deploy/404.html static/404.html
```
> ⚠️ **跨发行版大坑（实测踩过）**：Ubuntu 的 `nginx.conf` 默认只 `include /etc/nginx/sites-enabled/*`，**不读 `conf.d/`**。若把配置放 `conf.d/` 而系统是 Ubuntu，Nginx 实际还在跑默认配置，`/api/*` 不会被代理 → `curl http://localhost/api/health` 返回 404 页。判断方法：`grep include /etc/nginx/nginx.conf` 看它到底加载哪个目录，配置就放哪；放错目录 = “写了但没生效”。

---

## 第 8 步：校验并启动 Nginx

```bash
# 服务器执行
nginx -t                      # 语法检查，必须看到 "syntax is ok" 和 "test is successful"
nginx -s reload               # 优雅热加载（向 master 发信号，不中断连接）
# 首次启动若 Nginx 还没跑，用：systemctl start nginx  （或 nginx 直接起）
systemctl status nginx --no-pager | head -5    # 期望 active (running)
```

> 改 Nginx 配置后永远是：`nginx -t && nginx -s reload`（`reload` 优雅热加载、不断连接；`restart`/`systemctl restart` 会先停后起、瞬间断所有连接，非必要不用）。

---

## 第 9 步：端到端验证（浏览器 / curl）

```bash
# 服务器执行
curl -s http://localhost/api/health     # {"status":"ok","db":true,...}
curl -s http://localhost/api/works      # []   （空数组，表是空的，没假数据）
```

然后在你**本地电脑浏览器**打开：

```
http://<公网IP>/            ← 展示页（Bento 网格，目前空）
http://<公网IP>/admin.html  ← 管理页（在这里添加第一个作品）
http://<公网IP>/docs        ← FastAPI 自动文档（调试用）
```

进 `/admin.html` 填一条作品保存，再回 `/` 刷新，应能看到刚加的内容。

---

## 第 10 步：日常运维命令（记这组就够）

```bash
# 全部在 /opt/candy-house-portfolio 下执行

# 启动 / 停止 / 重启整套
docker compose -f docker/docker-compose.yml up -d --scale app=2
docker compose -f docker/docker-compose.yml down
docker compose -f docker/docker-compose.yml restart

# 看日志（排错第一现场）
docker compose -f docker/docker-compose.yml logs -f app     # 后端（实时滚动）
docker compose -f docker/docker-compose.yml logs -f db      # 数据库
# Nginx 有两套日志：
# ① 文件日志（最常用，看访问/报错细节）：
tail -f /var/log/nginx/access.log                          # 访问日志（谁访问了什么、返回码）
tail -f /var/log/nginx/error.log                           # 错误日志（404/502 根因都在这）
# ② systemd 日志（看 Nginx 进程本身有没有起得来）：
journalctl -u nginx -n 50 --no-pager

# 扩容 / 缩容后端（改数量后改 nginx-host.conf 的 upstream 行数对应）
docker compose -f docker/docker-compose.yml up -d --scale app=3
# 若只跑 1 个 app，编辑 /etc/nginx/conf.d/candy-house.conf 删掉 server 127.0.0.1:8001; 再 nginx -t && nginx -s reload

# 更新代码后重新部署
# 1) 本地 scp 更新文件上来
# 2) 服务器：docker compose -f docker/docker-compose.yml up -d --build --scale app=2
# 3) 若改了 nginx 配置：nginx -t && nginx -s reload

# 备份数据库（重要！）
docker compose -f docker/docker-compose.yml exec -T db \
  mysqldump -uroot -p"你改后的强密码" candy_house > backup_$(date +%F).sql
```

---

## 第 11 步：日志怎么看（排错第一现场）

日志是运维的「监控探头」，出问题**第一件事就是看日志**，别瞎猜。下面三类日志分开看。

### 11.1 Nginx 访问日志（access.log）——看「请求结果」

```bash
tail -f /var/log/nginx/access.log          # 实时滚动看新访问
tail -n 20 /var/log/nginx/access.log       # 只贴最近 20 行
```

每行大致这样（空格分隔）：

```
<访客IP> - - [时间] "GET /api/health HTTP/1.1" <状态码> <字节数> "Referer" "User-Agent"
```

- 重点看**状态码**：`200`=正常，`404`=文件/路径找不到，`502`=Nginx 连不上后端（upstream 挂了），`304`=缓存命中。
- 例：`"GET /api/health HTTP/1.1" 502` → 后端（app 容器）没起来或端口不对，去 11.3 看 app 日志。

### 11.2 Nginx 错误日志（error.log）——看「为什么错」

```bash
tail -f /var/log/nginx/error.log
tail -n 50 /var/log/nginx/error.log
```

两种最常见报错：

- `open() "/opt/candy-house-portfolio/static/xxx" failed (2: No such file or directory)`  
  → 静态文件路径配错或文件没传上去。核对 `nginx-host.conf` 里的 `root` 和 `ls /opt/candy-house-portfolio/static`。
- `connect() failed (111: Connection refused) while connecting to upstream`  
  → Nginx 想连 `127.0.0.1:8000` 但连不上（app 没跑 / 端口错）→ 502。去 11.3。

> 你之前那个 `curl http://localhost/api/health` 返回 404 页，根因就是 Ubuntu 的 Nginx 没加载 `conf.d/` 里的配置（只认 `sites-enabled/`），`/api/` 没被代理 → 默认 server 接了这个请求。修法见第 7 步。

### 11.3 后端 App 日志（Docker）——看「代码 / 数据库报错」

```bash
cd /opt/candy-house-portfolio

# 看所有 app 实例（--scale app=2 有 2 个）
docker compose -f docker/docker-compose.yml logs -f app

# 只贴最近 100 行（不实时）
docker compose -f docker/docker-compose.yml logs --tail=100 app

# 看某个具体实例（容器名形如 candy-house-portfolio-app-1）
docker logs -f candy-house-portfolio-app-1
```

- 能看到：收到的请求、SQLAlchemy 执行的 SQL、Python 报错堆栈（如数据库连不上、密码错）。
- 502 时先看这里：若 app 在重启 / 报错，Nginx 自然连不上。

### 11.3.1 现在日志长什么样（CRUD 审计示例）

后端已加「审计日志」：每个增删改都会打印**具体操作内容**，不再是空的。执行 `logs -f app` 会看到类似：

```text
2026-08-27 15:40:01 | INFO  | → POST /api/works | ip=1.2.3.4 | req_id=a1b2c3d4
2026-08-27 15:40:01 | INFO  | CREATE work | id=12 | title='糖果屋首页' | category=Web | color=#FF1493 | link='https://...'
2026-08-27 15:40:01 | INFO  |            description='新粗野主义风格落地页'
2026-08-27 15:40:01 | INFO  | ← POST /api/works | status=201 | 12.3ms | req_id=a1b2c3d4

2026-08-27 15:41:10 | INFO  | → PUT /api/works/12 | ip=1.2.3.4 | req_id=e5f6g7h8
2026-08-27 15:41:10 | INFO  | UPDATE work | id=12 | title: '糖果屋首页' -> '糖果屋首页V2' | color: '#FF1493' -> '#00E5FF'
2026-08-27 15:41:10 | INFO  | ← PUT /api/works/12 | status=200 | 9.8ms | req_id=e5f6g7h8

2026-08-27 15:42:00 | WARNING | → DELETE /api/works/12 | ip=1.2.3.4 | req_id=i9j0k1l2
2026-08-27 15:42:00 | WARNING | DELETE work | id=12 | title='糖果屋首页V2' | category=Web
2026-08-27 15:42:00 | INFO  | ← DELETE /api/works/12 | status=204 | 7.2ms | req_id=i9j0k1l2
```

字段含义：
- `→ / ←`：请求进来 / 响应回去，配 `req_id` 能把同一次请求的两行串起来。
- `ip`：真实访客 IP（Nginx 已传 `X-Forwarded-For` / `X-Real-IP`，不再是 127.0.0.1）。
- `CREATE`：新建时打印**全部字段 + 新 id**；`UPDATE`：打印**每个改了字段的旧值 → 新值**；`DELETE`（WARNING 高亮）：打印**被删 id + 标题**，先记再删，删失败也有据可查。
- 健康检查 `/api/health` 探活过于频繁，已自动跳过，不刷屏。

> 改了后端代码（如本日志功能）后要**重新构建镜像**才能生效：
> ```bash
> cd /opt/candy-house-portfolio
> docker compose -f docker/docker-compose.yml up -d --build --scale app=2
> docker compose -f docker/docker-compose.yml logs -f app   # 立刻能看到新格式日志
> ```

### 11.4 一个标准排查顺序（记住这个）

访问异常 →  
1. `tail -f /var/log/nginx/access.log` 看状态码；  
2. `404` → 看 `error.log` 的 `open()...failed` + 核对静态路径 / nginx 配置是否被加载；  
3. `502` → 看 app 日志（app 挂了？）+ `docker compose ps` 确认 app 是 `Up` + `curl http://localhost:8000/api/health` 直连后端；  
4. db 相关 → `logs db`。

---

## 排错速查

| 现象                                      | 原因 / 处理                                                 |
| --------------------------------------- | ------------------------------------------------------- |
| SSH 连不上                                 | 安全组没放 22，或 IP/密码错                                       |
| 浏览器打不开网站                                | ①安全组放 80 ②防火墙放 80 ③`systemctl status nginx` 是否 running  |
| `no such file or directory`（compose 路径） | 必须在 `/opt/candy-house-portfolio` 根目录跑，不要进 `docker/` 子目录 |
| `env file .../api/.env not found`       | 第 4 步没做；`.env` 要在 `api/.env`                            |
| `db` 一直 Restarting                      | `.env` 缺 `MYSQL_ROOT_PASSWORD` 或密码不一致；`logs db` 看详情     |
| `mysqladmin ping` 报 `Access denied for user 'root'@'127.0.0.1'` | 数据卷里存的 root 密码 ≠ 当前 `.env`（MySQL 只在数据卷**为空时初始化一次**密码，改 `.env` 不会改已初始化的库）。解决：`docker compose -f docker/docker-compose.yml down -v` 清空卷，再 `up -d` 重新初始化；无真实数据，安全。验证用容器内变量避免手敲：`exec db bash -c 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD"'` |
| 日志报 `Can't connect to MySQL server on '@db'` / `Name or service not known` | **密码里含 `@`，破坏了 `DATABASE_URL` 的 URL 解析**（URL 用第一个 `@` 分隔密码与主机，导致主机变成 `@db`）。修复：把 `.env` 里 `DATABASE_URL` 密码部分的 `@` 改成 `%40`（如 `candy:pwd%40@db`），再 `docker compose up -d --force-recreate --scale app=2` 重建 app 容器（env 在创建时注入，必须重建）；或干脆把密码的 `@` 去掉并重 `down -v` 初始化。教训：数据库密码别用 `@ : / # %` 这些 URL 特殊字符。 |
| 日志报 `Can't connect to MySQL server on 'db'` / `Temporary failure in name resolution` | **app 与 db 不在同一 Docker 网络**，app 解析不了 `db` 这个服务名（DNS 失败）。修复：compose 里 `app` 服务必须加 `networks: [candy-net]`（和 `db` 同一自定义网络）；改完 `docker compose down`（**不加 -v**，保留数据卷）再 `up -d --scale app=2`。记住：`depends_on` 只管启动顺序，不管网络连通。 |
| 日志报 `RuntimeError: 'cryptography' package is required for sha256_password or caching_sha2_password` | **MySQL 8 默认 `caching_sha2_password` 认证，PyMySQL 做 RSA 加密必须装 `cryptography`**。修复：在 `api/requirements.txt` 加 `cryptography==43.0.1`，然后 `docker compose up -d --build --scale app=2`（**必须 `--build` 重建镜像**，否则还在用旧镜像）。 |
| `docker compose build` 报 `failed to resolve source metadata for docker.io/library/python:3.11-slim ... lookup hub-mirror.c.163.com ... no such host` | **Docker 守护进程配的镜像加速器（registry-mirrors）域名失效/DNS 解析不了**，导致拉取基础镜像元数据失败（与代码无关）。修复：`cat /etc/docker/daemon.json` 查看，把失效镜像源换成可用的（如 `https://docker.m.daocloud.io`）或清空 `{"registry-mirrors": []}`；再 `systemctl daemon-reload && systemctl restart docker`；随后 `docker compose up -d --build --scale app=2`。注意：`restart docker` 会短暂停掉运行中的容器，但命名数据卷（如 `mysql_data`）不丢，重启 `up` 后库仍在。 |
| 展示页空白 / 取数失败                            | 后端没连 MySQL：`logs app`；或 Nginx `proxy_pass` 端口对不上        |
| `nginx -t` 报 `conflicting server name`  | 默认站点没删，重做第 7 步的 `rm`                                    |
| 加的作品不显示                                 | 看 Nginx 日志 `journalctl -u nginx`；确认前端请求 `/api/works`    |

---

## 一句话记住

**Docker 管 db+app（`docker compose`），Nginx 管对外（`systemctl`）；两边密码靠 `api/.env` 一份搞定；访问不通先查安全组→防火墙→服务状态这三道。**
