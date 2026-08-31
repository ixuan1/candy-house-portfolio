# 糖果屋 · 以非 root 用户 candyapp 部署到京东云

> **为什么不用 root 一把梭？**
> 单独建 `candyapp` 跑应用，遵循「最小权限原则」：误操作（比如 `rm -rf`、`chmod` 手滑）
> 的爆炸半径被限制在项目目录内，碰不到系统文件；日常流程也更规范。

> **⚠️ 但别神化它（诚实认知）**：
> `candyapp` 只要进了 `docker` 组，就能通过 Docker 守护进程起特权容器、
> 挂载宿主文件系统——**约等于拿到了 root 的提权通道**。
> 所以非 root 部署解决的是「**减少误操作 + 规范流程**」，
> 不是一道真正的安全隔离墙。真要隔离得靠 rootless Docker / 独立主机 / 容器沙箱。

---

## 🎭 三种身份，别搞混（最重要的一节）

| 谁 | 能做什么 | 怎么进入 |
|---|---|---|
| **root** | 建用户、改属主、配 Nginx、放行防火墙 | `ssh root@<公网IP>`（本地终端） |
| **candyapp** | 传文件、跑 `docker compose`、看日志、跑部署脚本 | `ssh candyapp@<公网IP>` 或 root 下 `su - candyapp` |
| ~~candyapp + sudo~~ | **不存在**。`candyapp` 不该进 sudoers，也不该有 sudo 权 | — |

> 🚨 **核心原则：candyapp 没有 sudo，这是设计如此，不是配置问题。**
> 一旦看到 `candyapp is not in the sudoers file` → 说明你正在用 candyapp 身份
> 尝试做一件**本该在 root 会话里做**的事。切回 root 会话即可，别去给它加 sudo 权
> （加了就等于白搞非 root 部署）。

**两个会话之间怎么切**（root → candyapp 不需要密码）：

```bash
# 在 root 会话里切到 candyapp（会加载 candyapp 的完整环境，docker 组立即生效）
su - candyapp
# su  = switch user 切换用户
# -   = login shell，完整加载目标用户的环境变量（不加 - 会导致组/环境不刷新）

# 回到 root
exit
# exit = 退出当前 shell，回到上一个用户
```

> **命令约定**：每条命令后用 `#` 注释逐个解释参数（与 `STEP-BY-STEP.md` 一致）。
> **前提**：京东云已装好 Docker（含 Compose 插件）；没装见 `STEP-BY-STEP.md` 第 2 步。

---

## 第 0 步：建 candyapp 用户并加 docker 组（🔴 root 会话）

```bash
# 本地终端：用 root 登录
ssh root@<公网IP>
# ssh  = secure shell 加密远程登录协议
# root = 以 root 身份登录；@ 后面是服务器公网 IP

# 服务器执行（已经是 root，命令前【不需要】加 sudo）：
# 1) 创建用户，建家目录、指定 bash
useradd -m -s /bin/bash candyapp
# useradd = 新建系统用户
# -m      = makedir，自动创建家目录 /home/candyapp
# -s /bin/bash = 指定登录 shell（默认可能是 /bin/sh，不好用）

# 2) 设密码（SSH 登录用）
passwd candyapp
# passwd = 修改密码；后面跟用户名就是改该用户的密码

# 3) 关键：加入 docker 组，这样它能直接跑 docker 不用 sudo
usermod -aG docker candyapp
# usermod = 修改用户属性
# -aG     = append + Groups：-a 表示「追加」到组（不覆盖原有组），-G 指定组名

# 4) 确认结果
id candyapp
# id = 打印用户的 uid/gid 和所属组；输出里必须能看到 docker
```

> 💡 **SSH 登录 candyapp 推荐用密钥**：把本机公钥追加到服务器
> `/home/candyapp/.ssh/authorized_keys` 即可，省得每次输密码。

---

## 第 1 步：准备部署目录（🔴 root 会话）

项目继续放 `/opt/candy-house-portfolio`（nginx 配置里的 `root` 写死在这，别改路径，
否则又掉进「路径漂移 404」的坑）。

```bash
# 服务器执行（root 会话）：
# 0) 先看旧目录还在不在（你之前用 root 部署过，多半还在）
ls -la /opt/ | grep candy
# ls -la = 长格式列出所有文件；| grep candy = 过滤出含 candy 的行

# 1) 建目录（已存在也不会报错）
mkdir -p /opt/candy-house-portfolio
# mkdir = make directory；-p = parents，已存在也不报错

# 2) 改属主给 candyapp（关键！否则 candyapp 写不进去）
chown -R candyapp:candyapp /opt/candy-house-portfolio
# chown = change owner；-R = recursive 递归；candyapp:candyapp = 属主:属组

# 3) 让 Nginx 的 www-data 能读到静态文件
chmod -R o+rX /opt/candy-house-portfolio/static
# chmod = change mode；-R = recursive
# o+rX  = others 加读(r) + 仅对目录加执行(X，大写)
#         （大写 X 很关键：不会给普通文件乱加执行位）
```

> ⚠️ **若旧目录里还有上一次 root 部署留下的容器在跑**，先停掉（端口 8000/8001 会冲突）：
> ```bash
> cd /opt/candy-house-portfolio && docker compose -f docker/docker-compose.yml down
> # down = 停止并移除容器和网络（不动数据卷，数据库安全）
> ```
> 数据卷 `db_data` 由 Docker 守护进程统一管理、**与「谁跑 compose」无关**，旧数据会保留。

---

## 第 2 步：把项目弄到服务器（🟢 candyapp 会话）

```bash
# 在 root 会话里切换（docker 组立即生效，免退出重登）
su - candyapp
cd /opt/candy-house-portfolio
```

### 方式 A：git clone（推荐）

```bash
git clone git@github.com:ixuan1/candy-house-portfolio.git .
# clone = 下载远程仓库；git@github.com:... = SSH 地址（需先配 candyapp 的 SSH 密钥）
# 末尾的 . = 克隆到当前目录（目录必须为空，否则 git 拒绝）
```

### 方式 B：本地 rsync 同步上传（不用 git 时选这个）

```bash
# 本地终端执行（Windows Git Bash），以 candyapp 身份传 → 文件属主直接就是 candyapp

# ① 先预演一遍，看看会发生什么（强烈建议第一次一定先跑这个）
rsync -rlptvz --delete -n \
      --exclude '.env' --exclude '.git/' --exclude 'backups/' \
      --exclude '__pycache__/' --exclude '*.pyc' \
      "/f/005_code/WORKbuddy/candy-house-portfolio - docker/"{api,db,nginx,static,docker,deploy} \
      candyapp@<公网IP>:/opt/candy-house-portfolio/
# rsync = 远程同步工具；-r = recursive 递归子目录
# -l = links 保留符号链接本身（scp -r 会把软链变成实体文件，语义被改变）
# -p = perms 保留权限；-t = times 保留修改时间（下次靠它判断变没变）
# -v = verbose 列出每个文件；-z = compress 传输时压缩
# --delete = 【核心】删掉"服务器上有、本地没有"的文件 —— scp 做不到这一条
# -n = dry-run 预演，只打印将要发生的变更，【不真改动】
# --exclude = 排除不参与同步的路径（见下方红字警告）
# {...} = bash 大括号展开，一次同步多个目录

# ② 确认预演结果没问题后，去掉 -n 真跑一次
rsync -rlptvz --delete \
      --exclude '.env' --exclude '.git/' --exclude 'backups/' \
      --exclude '__pycache__/' --exclude '*.pyc' \
      "/f/005_code/WORKbuddy/candy-house-portfolio - docker/"{api,db,nginx,static,docker,deploy} \
      candyapp@<公网IP>:/opt/candy-house-portfolio/
```

> 🚨 **`--delete` 是双刃剑，两个必须知道的点**
>
> 1. **必须先跑 `-n` 预演**。如果服务器上放了项目之外的东西（比如后来手动加的 SSL 证书、
>    临时脚本），`--delete` 会把它删掉。预演输出里看到 `deleting xxx` 就逐条确认。
> 2. **`--exclude '.env'` 绝不能省**。`--delete` 只认"源端有没有"，不认"文件重不重要"。
>    本地 `.env` 被 `.gitignore` 挡着（可能根本不存在），一旦漏掉这个 exclude，
>    服务器上的生产密码会被判定为"多余文件"直接删掉 → 下一次起容器就连不上库。

### 📘 增 / 改 / 删：三种同步方式对照

| 本地动作 | `scp -r` | `rsync --delete` | `git pull` |
|---|---|---|---|
| 新增文件 | ✅ 传过去 | ✅ 传过去 | ✅ 拉下来 |
| 修改内容 | ✅ 整文件覆盖 | ✅ 只传差异块 | ✅ 只传差异 |
| **删除文件** | ❌ **服务器上残留，且继续生效** | ✅ 同步删除 | ✅ 同步删除 |
| 回滚到上一个版本 | ❌ 没有历史 | ❌ 没有历史 | ✅ `git reset` 一键回退 |
| 传之前看改了什么 | ❌ | ✅ `-n` 预演 | ✅ `git diff` |

**为什么"删"不同步最危险**——服务器上残留的旧文件不是躺着的垃圾，是**还在生效的配置**：

- nginx 配置改名/删除 → `sites-enabled/` 里旧 `.conf` 仍被加载，你以为改了路由，其实跑的是旧规则
- 删掉的 `.py` 仍在 → 有地方 import 它时，本地报错的代码在生产反而"能跑"，掩盖 bug
- 静态文件改名（`app.js` → `app.v2.js`）→ 新旧两份都在，两边都能被访问

> **结论**：`scp` 只是"复制"，不能叫"部署同步"。要么用 `rsync --delete`，
> 要么（更推荐）服务器上改成 `git clone` + 日常 `git pull`——后者还能一键回滚，
> 这才是"开发到上线"流程该有的样子。
>
> 顺带一提：OpenSSH 9.0 起 `scp` 底层已改用 SFTP 协议，官方也更推荐 `rsync` / `sftp`。

### ⚠️ 实测：你的 Windows 本机目前没有 rsync

已验证 `Git Bash` 和 `WinGit` 都**不自带 rsync**，所以上面的 `rsync` 命令现在跑不了。
三条路，按推荐顺序：

**① 改用 git（最省事，且是长期正解）**
服务器上 `git clone` 一次，之后每次部署就是一句：

```bash
# candyapp 会话，在服务器上执行
cd /opt/candy-house-portfolio
git pull origin develop
# pull = 拉取并合并；origin = 远程仓库别名；develop = 分支名
# .env 被 .gitignore 挡着，git pull 不会动它 —— 生产密码天然安全
# 还能看改动：git log --oneline -5 ；还能回滚：git reset --hard <上一个commit>
```

**② 给 Windows 装 rsync（一次性）**

```bash
# 任选一条（winget 已确认可用）
winget install -e --id MSYS2.MSYS2      # 装 MSYS2，然后在 MSYS2 里 pacman -S rsync
wsl --install -d Ubuntu                 # 装 WSL，自带 rsync（你机器上 wsl.exe 已存在）
# -e = exact 精确匹配 ID；--id = 指定包标识
```

**③ 什么也不装，用脚本的「清空重传」模式**

`deploy/deploy.sh` 已自动判断：有 rsync 就用 rsync；没有就**先把服务器目录清空再全量传**，
效果等同 `--delete`，代价是几秒钟空窗期（这期间 Nginx 读静态文件会 404，紧接着就会重启）。
它会先把 `api/.env` 和 `backups/` 转移到 `/tmp` 暂存，传完再放回去——
这段逻辑已在本地沙箱里跑过验证，确认生产密码不会被本地版本覆盖。

### 补 .env（真实密码，绝不进 git）

```bash
# candyapp 会话：
cp api/.env.example api/.env
# cp = copy；把模板复制成真正的 .env（.env 已被 .gitignore 忽略）

vi api/.env
# 把 MYSQL_ROOT_PASSWORD / MYSQL_PASSWORD 改成强密码，且【不要含 @ 号】
# （密码里的 @ 会截断 DATABASE_URL 连接串，这是你之前踩过的坑）
```

---

## 第 3 步：配置 Nginx（🔴 root 会话）

> 这是「祖传 404 坑」高发地。京东云是 **Ubuntu**，Nginx **只认 `sites-enabled/`**，
> 丢进 `conf.d/` 会静默不生效 → 全站 404。

```bash
# 先回到 root 会话（如果还在 candyapp 下）
exit

# 服务器执行（root 会话）：
# 1) 复制配置到 sites-available（可用配置的「仓库」）
cp /opt/candy-house-portfolio/nginx/nginx-host.conf /etc/nginx/sites-available/candy-house.conf

# 2) 软链到 sites-enabled（Nginx 真正加载的目录）
ln -sf /etc/nginx/sites-available/candy-house.conf /etc/nginx/sites-enabled/candy-house.conf
# ln = link；-s = symbolic 软链接；-f = force 覆盖已存在的同名链接

# 3) 删掉默认站点（否则默认欢迎页抢 80 端口）
rm -f /etc/nginx/sites-enabled/default
# rm = remove；-f = force（不存在也不报错）

# 4) 校验语法 + 优雅热加载
nginx -t
# -t = test 只检查语法；看到 successful 才继续
nginx -s reload
# -s reload = 发「重载」信号：新 worker 用新配置，旧 worker 处理完手头请求再退出（用户无感）
```

> 💡 **为什么 Nginx 必须 root 起？** 它要绑定 80 端口（特权端口 <1024）且以 root 起主进程。
> 这是一次性主机配置，不属于 candyapp 的日常流程。

---

## 第 4 步：启动服务（🟢 candyapp 会话，日常流程）

```bash
# root 会话切过去（root 切 candyapp 不用密码）
su - candyapp
cd /opt/candy-house-portfolio

docker compose -f docker/docker-compose.yml up -d --scale app=2
# -f = file 指定 compose 文件；up = 创建并启动
# -d = detached 后台运行；--scale app=2 = 扩到 2 个实例（配合 Nginx least_conn）

docker compose -f docker/docker-compose.yml ps
# ps = 列出本项目容器状态（期望 db + 2×app = 3 个 Up/healthy）
```

---

## 第 5 步：分层验证（🟢 candyapp 会话）

```bash
# ① 直连后端（绕过 Nginx，确认「后端本身是好的」）
curl -s http://127.0.0.1:8000/api/health
curl -s http://127.0.0.1:8001/api/health
# 期望返回 {"status":"ok","db":true,...}

# ② 走 Nginx（确认「反代 + 静态也好了」）
curl -s http://localhost/api/health
curl -I http://localhost
# -I = 只看响应头；期望 200 OK
```

> **分层验证的意义**：① 通、② 不通 → Nginx 配置问题（查 `tail -f /var/log/nginx/error.log`）；
> ① 就不通 → 后端/数据库问题（查 `docker compose logs -f app`）。一次只排查一层。

**防火墙放行需 root**（若系统防火墙开着）：

```bash
# root 会话：
ufw allow 80/tcp
# ufw = Ubuntu 简易防火墙；allow = 放行；80/tcp = TCP 80 端口
ufw reload
```

京东云**安全组**也要放行 80（控制台操作，见 `STEP-BY-STEP.md` 第 0 步）。

---

## 第 6 步：日常运维（🟢 candyapp 会话）

```bash
# 看日志
docker compose -f docker/docker-compose.yml logs -f app
# -f = follow 实时滚动

# 改了代码要重新构建
docker compose -f docker/docker-compose.yml up -d --build --scale app=2
# --build = 强制重新构建镜像（改代码必加）

# 用生产脚本（自动备份 + 二次确认 + 失败回滚）
./deploy/deploy-prod.sh main
# main = 要部署的分支
```

---

---

## 🔴 高频坑：db 显示 healthy，app 却报 1045

### 现象

```
sqlalchemy.exc.OperationalError: (pymysql.err.OperationalError)
(1045, "Access denied for user 'candy'@'172.19.0.4' (using password: YES)")
app-1 exited with code 1 (restarting)
app-2 exited with code 1 (restarting)
```

### 为什么 `docker compose ps` 里 db 是 healthy 的？

**因为健康检查是个「假绿灯」**。`docker-compose.yml` 里 db 的探活命令是：

```bash
mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD"
```

它只验证 **root** 密码。而 app 用的是 **`candy`** 账号。
**root 密码对 ≠ candy 密码对** —— 所以 db 一路 healthy，app 一路重启，两件事互不矛盾。

### 根因

MySQL 官方镜像的 `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_DATABASE` 这三项，
**只在数据卷（`db_data`）为空、首次初始化时执行一次**。

之后你改了 `api/.env` 里的密码，再 `docker compose up -d`：
- 容器会重建，**但数据卷还在**
- MySQL 检测到数据目录非空 → **跳过初始化**
- 于是库里 `candy` 的密码仍是**旧值**，而 `DATABASE_URL` 里是**新值** → 认证失败

```
第一次部署（卷为空）  .env 密码 A  ──写入──> MySQL candy 密码 A   ✅ 能连
改 .env 为密码 B      卷里还是 A   ──跳过──> MySQL candy 密码 A   ❌ 1045
```

### 修复（🟢 candyapp 会话）

**方案 A：保住数据（推荐，生产唯一选项）**

```bash
cd /opt/candy-house-portfolio
bash deploy/fix-db-password.sh
# 脚本做的事：读 .env → root 进 MySQL → 确保 candy@'%' 存在且密码=MYSQL_PASSWORD
#             → 授权 candy_house 库 → 用新密码实连验证一次
# 幂等，可反复执行；不碰数据、不删卷
```

手工版等价命令（想理解原理时用这个）：

```bash
docker compose -f docker/docker-compose.yml exec -T db \
  mysql -uroot -p"你的ROOT密码" -e "ALTER USER 'candy'@'%' IDENTIFIED BY '你的新密码'; FLUSH PRIVILEGES;"
# exec            = 在已运行的容器里执行命令
# -T              = 不分配伪终端（脚本/管道里必须加，否则报 the input device is not a TTY）
# db              = compose 里的服务名
# mysql -uroot    = -u 指定用户名（-u 与用户名之间【没有空格】）
# -p"密码"        = -p 指定密码（同样没有空格，有空格会被当成库名）
# -e              = execute，执行引号内 SQL 后退出
# ALTER USER      = 修改已有用户的密码
# 'candy'@'%'     = 用户名@允许来源主机，% 表示任意 IP（容器 IP 会变，必须不写死）
# FLUSH PRIVILEGES = 重新加载权限表，让改动立即生效
```

**方案 B：库里没数据、可以推倒重来（⚠️ 生产禁用）**

```bash
docker compose -f docker/docker-compose.yml down -v
# -v = volumes，连数据卷一起删 —— 等于删库，库里所有作品数据没了

docker compose -f docker/docker-compose.yml up -d --build --scale app=2
# 卷为空 → MySQL 重新初始化 → candy 密码 = 当前 .env 的 MYSQL_PASSWORD
```

### ⚠️ 改密码后必须重建 app 容器

`.env` 是通过 `env_file` 在**容器创建时**注入的。改了 `.env` 直接 `up -d`，
Compose 认为配置没变，**不会重建容器**，容器里的 `DATABASE_URL` 仍是旧值。

```bash
docker compose -f docker/docker-compose.yml up -d --force-recreate app
# --force-recreate = 强制重建容器（即使配置看似没变）
# app              = 只重建 app，不动 db（保数据）
```

### 校验清单

```bash
# ① .env 里三处密码必须一致：MYSQL_PASSWORD == DATABASE_URL 里冒号后@前的那段
grep -E '^(MYSQL_USER|MYSQL_PASSWORD|MYSQL_ROOT_PASSWORD|DATABASE_URL)=' api/.env

# ② 库里到底有哪些账号（root 会话，用 ROOT 密码）
docker compose -f docker/docker-compose.yml exec -T db \
  mysql -uroot -p"ROOT密码" -e "SELECT user, host, plugin FROM mysql.user;"
# 期望看到 candy 且 host 为 %（% = 任意来源；若是 localhost，容器 IP 连不进来）

# ③ 用 app 的真实账号实连一次（这才是真健康检查）
docker compose -f docker/docker-compose.yml exec -T db \
  mysql -ucandy -p"新密码" -e "SELECT 1;" candy_house
```

---

## 排错速查

| 现象 | 原因 | 解决 |
|---|---|---|
| `candyapp is not in the sudoers file` | 用 candyapp 做了本该 root 做的事 | **切回 root 会话**执行，别给 candyapp 加 sudo |
| app 报 `1045 Access denied for user 'candy'` | 改过 `.env` 密码，但 MySQL 里的账号密码没跟着变（卷非空 → 跳过初始化） | `bash deploy/fix-db-password.sh`，然后 `up -d --force-recreate app` |
| db 显示 healthy 但 app 连不上 | healthcheck 只用 **root** 探活，不覆盖 `candy` 账号 | 同上；健康检查不代表业务账号可用 |
| `permission denied` 连 docker socket | candyapp 没在 docker 组 | root 下 `usermod -aG docker candyapp`，然后 `su - candyapp` |
| 访问 404（Nginx 欢迎页或糖果屋 404） | 配置丢进 `conf.d/`（Ubuntu 不读） | root 下改放 `sites-enabled/`（第 3 步），`nginx -s reload` |
| 静态资源 403 | www-data 读不到 `/opt/.../static` | root 下 `chmod -R o+rX /opt/candy-house-portfolio/static` |
| `/opt` 下写入被拒 | 目录属主还是 root | root 下 `chown -R candyapp:candyapp /opt/candy-house-portfolio` |
| app 一直重启 / `Can't connect to '@db'` | `.env` 密码含 `@` 截断连接串 | 改密码去掉 `@`，`up -d --build` 重建 |
