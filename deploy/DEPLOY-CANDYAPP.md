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

### 方式 B：本地 scp 上传

```bash
# 本地终端执行（Windows Git Bash），以 candyapp 身份传 → 文件属主直接就是 candyapp
scp -r "/f/005_code/WORKbuddy/candy-house-portfolio - docker/"{api,db,nginx,static,docker,deploy} \
      candyapp@<公网IP>:/opt/candy-house-portfolio/
# scp = secure copy；-r = recursive 递归；{...} = bash 大括号展开，一次传多个目录
```

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

## 排错速查

| 现象 | 原因 | 解决 |
|---|---|---|
| `candyapp is not in the sudoers file` | 用 candyapp 做了本该 root 做的事 | **切回 root 会话**执行，别给 candyapp 加 sudo |
| `permission denied` 连 docker socket | candyapp 没在 docker 组 | root 下 `usermod -aG docker candyapp`，然后 `su - candyapp` |
| 访问 404（Nginx 欢迎页或糖果屋 404） | 配置丢进 `conf.d/`（Ubuntu 不读） | root 下改放 `sites-enabled/`（第 3 步），`nginx -s reload` |
| 静态资源 403 | www-data 读不到 `/opt/.../static` | root 下 `chmod -R o+rX /opt/candy-house-portfolio/static` |
| `/opt` 下写入被拒 | 目录属主还是 root | root 下 `chown -R candyapp:candyapp /opt/candy-house-portfolio` |
| app 一直重启 / `Can't connect to '@db'` | `.env` 密码含 `@` 截断连接串 | 改密码去掉 `@`，`up -d --build` 重建 |
