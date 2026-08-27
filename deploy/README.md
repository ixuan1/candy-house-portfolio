# 京东云部署实操手册（一步一步）

> 目标：把糖果屋全栈项目搬到京东云服务器跑起来。MySQL + 后端用 Docker，Nginx 在【宿主机】原生运行（systemd 托管），外网 80 端口访问。

---

## 第 0 步：准备

| 项 | 说明 |
|---|---|
| 京东云云主机 | 已创建、运行中，系统建议 **Ubuntu 22.04** 或 **CentOS 7/8**，规格 2C2G 起 |
| 公网 IP | 控制台「云主机」详情里看 |
| 登录 | `ssh root@公网IP`（密钥或密码） |
| **安全组** | ⚠️ 控制台「安全组」放行 **TCP 80**（后续上 HTTPS 再加 443）。**不要放行 3306**（MySQL 只在 Docker 内网，绝不暴露公网） |

---

## 第 1 步：登录服务器，装 Docker

```bash
ssh root@你的公网IP

# Ubuntu / Debian
apt update && apt install -y docker.io docker-compose-plugin
# CentOS
# yum install -y yum-utils && yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo && yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl start docker
systemctl enable docker     # 开机自启，避免重启后服务全没
docker version              # 看到 Server 版本即成功
```

---

## 第 2 步：把项目传到服务器

在你**本机**（不是服务器）的项目目录执行：

```bash
# 把整个 candy-house-portfolio 目录打包上传到服务器的 /opt
scp -r /本地路径/candy-house-portfolio root@公网IP:/opt/
```

然后在服务器上：

```bash
ssh root@公网IP
cd /opt/candy-house-portfolio
cp api/.env.example api/.env
# 编辑 api/.env，把以下密码改成强密码（别用默认值）：
#   MYSQL_ROOT_PASSWORD  —— MySQL root 密码（db 与 app 都从这份 .env 读，必须一致）
#   MYSQL_PASSWORD       —— 普通用户 candy 的密码
#   DATABASE_URL         —— 里面的密码要和上面的 MYSQL_PASSWORD 保持一致
vi api/.env
```

> ⚠️ **`api/.env` 是 db 和 app 共用的唯一密码来源**（compose 里两个服务都用 `env_file` 读它）。
> 只要这份文件里密码一致、且都用强密码，就不会出现“库用 A 密码、应用用 B 密码”连不上的情况。

---

## 第 2.5 步：MySQL 在 Docker 里是怎么装好的（重点，之前漏讲了）

很多人以为“装 MySQL”要先 `apt install mysql-server`，但本项目里**不是**——MySQL 是作为一个 Docker 容器跑起来的，整个过程由 Compose 自动完成。下面把“背后发生了什么”拆开讲，并给你手动验证、手动安装的办法。

### A. 自动安装的原理（docker-compose 里发生了什么）

`docker/docker-compose.yml` 里的 `db` 服务做了三件事：

1. **拉镜像**：`image: mysql:8.0` —— 第一次 `docker compose up` 时，Docker 自动从 Docker Hub 下载 MySQL 8.0 官方镜像（相当于“安装”）。
2. **设置环境变量**：通过 `env_file: ../api/.env` 读取同一份密码文件，其中包含 4 个关键变量：
   - `MYSQL_ROOT_PASSWORD`：root 密码
   - `MYSQL_DATABASE`：启动时自动创建名为 `candy_house` 的库
   - `MYSQL_USER` / `MYSQL_PASSWORD`：自动创建普通用户 `candy` 并授该库权限
   > db 与 app 共用 `../api/.env`，所以“建库密码”和“连库密码”天然一致。
3. **挂载初始化脚本**：`../db/init.sql`（注意：compose 文件在 `docker/` 子目录，所以用 `../` 回到项目根）挂到容器内的 `/docker-entrypoint-initdb.d/init.sql`。
   ▶️ 关键点：MySQL 官方镜像有个**约定**——只要这个目录里有 `.sql` 文件，且**数据目录还是空的（首次启动）**，容器启动时会**自动执行它**来建库建表。所以你不用手动进库敲 SQL，`candy_house.works` 表是自动建好的。

### B. 手动验证 MySQL 真的装好了（排错必会）

在服务器上（项目目录下）逐条执行：

```bash
# 1) 看容器状态，db 应是 Up（healthy）
docker compose -f docker/docker-compose.yml ps db

# 2) 看 MySQL 启动日志（首次会看到 "port: 3306  MySQL Community Server" 字样）
docker compose -f docker/docker-compose.yml logs db

# 3) 用 mysqladmin 探活（返回 "mysqld is alive" 即正常）
docker compose -f docker/docker-compose.yml exec db \
  mysqladmin ping -h localhost -p"$MYSQL_ROOT_PASSWORD"

# 4) 进库确认表已建好（这是验证“初始化脚本生效”的硬证据）
docker compose -f docker/docker-compose.yml exec db \
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "USE candy_house; SHOW TABLES; SELECT COUNT(*) FROM works;"
# 期望看到：works 表 + 0 行（空表，无假数据 ✅）
```

> 如果上面报错 `MYSQL_ROOT_PASSWORD` 为空，是因为你在 shell 里没 `export`，直接把密码写进去即可：
> `docker compose -f docker/docker-compose.yml exec db mysqladmin ping -h localhost -p你的密码`

### C. 应用是怎么连上 MySQL 的（最关键的网络概念）

后端 `app` 容器连数据库**不是用 IP，而是用服务名 `db`**：

```yaml
environment:
  MYSQL_HOST: db
  DATABASE_URL: mysql+pymysql://candy:密码@db:3306/candy_house
```

原因：Docker Compose 给这些容器建了一个**内部桥接网络 `candy-net`**，并内置 DNS，能把服务名 `db` 解析成 MySQL 容器的内网 IP。所以：
- 应用写 `db:3306` 就能连，**不需要知道 IP、也不需要 3306 映射公网**。
- 这也是为什么安全组/防火墙**永远不要开 3306**——数据库只活在 Docker 内网，外网打不到。

### D. 不用 Compose 的“纯手动安装”方式（理解原理用）

如果你想脱离 Compose 自己用 `docker run` 装一遍 MySQL，命令如下（项目用 Compose 就够了，这步仅供你理解镜像机制）：

```bash
# 建专用网络
docker network create candy-net

# 跑 MySQL 容器（等效于 compose 里的 db 服务）
docker run -d \
  --name candy_db \
  --network candy-net \
  -e MYSQL_ROOT_PASSWORD=你的强密码 \
  -e MYSQL_DATABASE=candy_house \
  -e MYSQL_USER=candy \
  -e MYSQL_PASSWORD=你的强密码 \
  -v candy_db_data:/var/lib/mysql \
  -v /opt/candy-house-portfolio/db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro \
  mysql:8.0 \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci

# 验证
docker exec -it candy_db mysqladmin ping -h localhost -p"你的强密码"
```

要点和 Compose 完全一致：**镜像 = 安装、环境变量 = 初始化、initdb 目录 = 自动建表、命名卷 = 数据持久化**。

### E. MySQL 在 Docker 里的常见坑（必看）

| 坑 | 现象 | 解决 |
|---|---|---|
| **改了 init.sql 不生效** | 表结构没变 | initdb 脚本**只在数据卷为空时执行一次**。改表结构后：要么 `docker compose down -v` 重来（会清空数据！），要么手动 `docker exec` 进库 `ALTER TABLE` / 跑增量 SQL。 |
| **应用连不上 MySQL** | app 日志 `Connection refused` / `Unknown MySQL server host 'db'` | ① `docker compose ps db` 是否 healthy；② `depends_on: condition: service_healthy` 保证顺序；③ `.env` 密码和 compose 一致。 |
| **Data directory not empty** | MySQL 容器起不来，日志报目录非空 | 多半是卷里已有残留数据。清卷：`docker compose down -v` 再 `up`；或换一个新卷名。 |
| **字符乱码** | 中文变 `?` | 已在 init.sql 用 `utf8mb4`；若手动建库漏了，加 `--character-set-server=utf8mb4` 参数（见 D）。 |
| **想临时用 Navicat 连库调试** | 本地工具连不上 | 临时 `docker run` 时加 `-p 3306:3306` 映射本机，**调试完务必去掉**，生产绝不映射公网。 |

---

## 第 3 步：一键启动（含负载均衡）

> 💡 **路径基准提醒**：`docker-compose.yml` 在 `docker/` 子目录，里面的 `../api`、`../db`、`../static` 等相对路径都已用 `../` 回到项目根。所以**必须在项目根目录 `/opt/candy-house-portfolio` 执行**下面这条命令（在子目录里跑会报 `no such file` 或 `env file not found`）。

```bash
docker compose -f docker/docker-compose.yml up -d --scale app=2
```

- `--scale app=2`：起 **2 个后端容器**，Nginx 用 `least_conn` 把流量分摊到两台 → 这就是负载均衡。
- 首次启动 MySQL 会自动执行 `db/init.sql` 建好表（空表，无假数据）。

---

## 第 3.5 步：在宿主机安装并配置 Nginx（反代 + 负载均衡）

本方案**不让 Nginx 跑在 Docker 里**，而是装在宿主机上用 systemd 托管——这正是传统运维的做法，也方便你以后直接改配置、看日志。

```bash
# 安装 Nginx（Ubuntu / Debian）
apt update && apt install -y nginx
# CentOS
# yum install -y nginx

# 放入“宿主机版”配置（注意是 nginx-host.conf，不是 docker 那版 nginx.conf）
cp /opt/candy-house-portfolio/nginx/nginx-host.conf /etc/nginx/conf.d/candy-house.conf

# CentOS 默认还有 /etc/nginx/conf.d/default.conf 占着 80 端口会冲突，删掉它：
# rm -f /etc/nginx/conf.d/default.conf

nginx -t                 # 检查配置语法，看到 successful 再继续
systemctl enable --now nginx   # 开机自启并启动
```

`nginx-host.conf` 做了三件事：
- `root /opt/candy-house-portfolio/static`：直接由宿主机 Nginx 发静态文件，不经过容器，最快。
- `upstream candy_app_upstream`：指向宿主机回环的 `127.0.0.1:8000` 与 `:8001`（Docker 把 app 映射出来的端口），`least_conn` 做负载均衡。
- `location /api/`：反向代理到后端；某台 502/503 时 `proxy_next_upstream` 自动转下一台。

> 端口对应：compose 里 app 用 `ports: 127.0.0.1:8000-8001:8000`，`--scale app=2` 时两容器分别占宿主机 8000/8001。若只跑 1 个 app，把 `nginx-host.conf` 里的 `server 127.0.0.1:8001;` 删掉即可。

---

## 第 4 步：验证

```bash
docker compose -f docker/docker-compose.yml ps
# 期望：db Up、app 有 2 个 Up（Nginx 不在 Docker 里，用下面看）
systemctl status nginx --no-pager | head -5

curl -s http://localhost/api/health
# {"status":"ok","db":true,"service":"candy-house-api"}

# 浏览器访问 http://你的公网IP/  → 展示页
#            http://你的公网IP/admin.html → 添加第一件作品
```

打开 `admin.html` 加一条作品，再回展示页刷新，能看到数据来自 MySQL（增删改查闭环打通 ✅）。

---

## 第 5 步：日常运维命令速查

```bash
# 看状态
docker compose -f docker/docker-compose.yml ps

# 看后端日志（排错第一现场）
docker compose -f docker/docker-compose.yml logs -f app

# 看 Nginx 状态 / 日志（Nginx 在宿主机，用 systemd 那套）
systemctl status nginx --no-pager
journalctl -u nginx -n 50 --no-pager          # 最近 50 行
# 或看错误日志文件
tail -f /var/log/nginx/error.log

# 改了代码/配置后重建
docker compose -f docker/docker-compose.yml up -d --build --scale app=2

# 扩容 / 缩容（不重启其它服务）
docker compose -f docker/docker-compose.yml up -d --scale app=3

# 停机（保留数据）
docker compose -f docker/docker-compose.yml down
# 停机并清空 MySQL 数据（慎用！）
docker compose -f docker/docker-compose.yml down -v
```

---

## 第 6 步：常见问题

| 现象 | 排查 |
|---|---|
| 浏览器打不开 | ① 安全组放 80 了没 ② 防火墙 ③ `systemctl status nginx` 是否 active ④ `nginx -t` 配置是否通过 |
| 展示页空白 / 取数失败 | 后端没连上 MySQL：`docker compose logs app` 看报错；多半是 `.env` 密码或 `db` 服务名 |
| 加了作品不显示 | 看 `journalctl -u nginx -n 50` 或 `/var/log/nginx/error.log`；确认前端请求的是 `/api/works` |
| 容器一直 Restarting | `docker compose logs app` 看启动报错（依赖顺序 / 端口冲突） |
| Nginx 起不来（80 端口被占） | `nginx -t` 看报错；CentOS 多半是 `/etc/nginx/conf.d/default.conf` 占坑，`rm -f` 掉再 `systemctl restart nginx` |
| `env file .../docker/api/.env not found` | compose 在 `docker/` 子目录，相对路径必须用 `../`。已修正；若仍报，确认：① 在**项目根目录**运行 ② `api/.env` 确实存在（`ls api/.env`）|
| 应用连不上 MySQL（日志 `Access denied`） | `api/.env` 里 `MYSQL_PASSWORD` 与 `DATABASE_URL` 中的密码不一致，或忘了加 `MYSQL_ROOT_PASSWORD`。两者都从这份 `.env` 读，改一致后 `down -v` 重来 |

> 更系统的运维知识（容器、日志、健康检查、反代、负载均衡、持久化、安全、备份、裸机 systemd 作业）见同目录 **ops-guide.md**。
