# 糖果屋部署操作手册（一步一步，照抄即可）

> 本手册只讲「一条能跑通的路」：
> **MySQL + 后端(FastAPI) 跑在 Docker；Nginx 跑在宿主机**（你选的方案）。
> 从零开始，按顺序执行第 0 步到第 10 步，每步都有「执行命令 + 怎么验证」。

> 📌 **本手册的命令书写约定**：每条命令后面都会用 `#` 注释逐个解释参数含义
> （例如 `-l` 是什么意思、`--scale` 是什么意思），方便理解而不是死记硬背。
> 末尾有「附录：命令参数速查表」可单独复习。

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
# ssh  = secure shell，加密远程登录协议
# root = 以 root 用户身份登录
# @    = 分隔符，@ 后面写服务器地址（IP 或域名）
```

连上后，后面的命令都在「服务器」里敲。

---

## 第 2 步：安装 Docker（含 Compose 插件）

```bash
# 服务器执行（一键装，CentOS / Ubuntu 通用）
curl -fsSL https://get.docker.com | sh
# curl = 命令行下载/请求工具
# -f = fail，服务器返回错误码时不输出错误页面（静默失败）
# -s = silent，静默模式，不显示进度条
# -S = show-error，配合 -s 使用：只在出错时才显示错误信息
# -L = location，自动跟随 301/302 重定向
# | sh = 管道，把下载回来的脚本内容交给 shell 执行

systemctl enable --now docker
# systemctl = systemd 的服务管理命令
# enable    = 设为开机自启
# --now     = 顺便现在立刻启动（省得再单独敲 systemctl start docker）

# 验证
docker --version
# --version = 只打印版本号后退出，用来确认装没装成功

docker compose version
# compose   = Docker 的子命令，用于编排多个容器
# version   = 查看 compose 插件版本（v2 才支持 `docker compose` 这种写法）
```

- 看到 `Docker version ...` 和 `Docker Compose version v2...` 即成功。
- 如果 `docker compose version` 报错说找不到插件，补装：
  - Ubuntu：`apt install -y docker-compose-plugin`
    - `apt install` = 安装软件包；`-y` = 对所有询问自动回答 yes（不用手动确认）
  - CentOS：`yum install -y docker-compose-plugin`
    - `yum` = CentOS 的包管理器；`-y` = 同上，自动确认

---

## 第 3 步：把项目传到服务器

方式 A（推荐，一次性传整个目录）：

```bash
# 本地终端执行（Git Bash 用 /f/... 这种路径；PowerShell 直接用 F:\...）
scp -r /f/005_code/WORKbuddy/candy-house-portfolio root@<公网IP>:/opt/candy-house-portfolio
# scp      = secure copy，基于 SSH 的远程拷文件
# -r       = recursive，递归拷贝，整个目录连同子目录一起传（传目录必须加）
# 第 1 个参数 = 本地源路径
# 第 2 个参数 = 服务器目标路径（格式：用户@主机:路径，冒号后面是服务器上的位置）
```

方式 B（如果目录已存在，只更新改过的文件）：

```bash
scp /f/005_code/WORKbuddy/candy-house-portfolio/docker/docker-compose.yml root@<公网IP>:/opt/candy-house-portfolio/docker/
# 不加 -r，因为这次只传单个文件
scp /f/005_code/WORKbuddy/candy-house-portfolio/nginx/nginx-host.conf root@<公网IP>:/opt/candy-house-portfolio/nginx/
```

回到服务器确认结构：

```bash
# 服务器执行
ls /opt/candy-house-portfolio
# ls = list，列出目录里的内容
# 期望看到：api  db  deploy  docker  nginx  static  README.md
```

---

## 第 4 步：配置 .env 密码（必做）

```bash
# 服务器执行
cd /opt/candy-house-portfolio
# cd = change directory，切换到指定目录（后面所有 compose 命令都依赖这个位置）

cp api/.env.example api/.env
# cp        = copy，复制文件
# 第 1 个参数 = 源文件（模板）
# 第 2 个参数 = 目标文件（真实配置，被 .gitignore 挡住不会进 git）

vi api/.env
# vi = 文本编辑器（不熟的话可以用 nano api/.env，更简单）
```

把文件里所有 `change_me_strong` / `root_strong_please_change` 改成你自己的强密码（**三处**密码要一致：`MYSQL_PASSWORD`、`MYSQL_ROOT_PASSWORD`、`DATABASE_URL` 里的密码）。
改完确认有这一行（**MySQL 8 强制要求，缺失会起不来**）：

```
MYSQL_ROOT_PASSWORD=你改后的强密码
```

> 记住：这份 `api/.env` 是「密码唯一来源」，db 和 app 都读它，所以只要改这一处。
>
> ⚠️ **密码别用 `@ : / # %` 这些 URL 特殊字符**。`DATABASE_URL` 是一个 URL，
> 密码里的 `@` 会让解析错位（主机被解析成 `@db`）→ app 连不上库、无限重启。
> 真要用的话必须转义，例如 `@` 写成 `%40`。详见排错速查表。

---

## 第 5 步：启动 MySQL + 后端（Docker）

```bash
# 服务器执行（务必在项目根目录 /opt/candy-house-portfolio 下运行）
cd /opt/candy-house-portfolio
# 原因：compose 文件里的 ../api/.env 是相对路径，进错目录会报 env file not found

# 第一次启动：清掉可能失败的数据卷，重新拉起
docker compose -f docker/docker-compose.yml down -v
# -f              = file，指定 compose 文件的路径（不加则默认找当前目录的 docker-compose.yml）
# down            = 停止并移除容器和网络
# -v              = volumes，连数据卷一起删除
# ⚠️ 危险：-v 会清空 MySQL 全部数据！仅在「首次初始化失败要重来」或「确定不要数据」时用

docker compose -f docker/docker-compose.yml up -d --scale app=2
# up             = 创建并启动容器（镜像不存在会自动构建）
# -d             = detached，后台运行，不占用当前终端
# --scale app=2  = 把 app 这个服务扩到 2 个实例（配合 Nginx 的 least_conn 做负载均衡）

# 看状态（db、app-1、app-2 都应是 Up）
docker compose -f docker/docker-compose.yml ps
# ps = process status，列出本 compose 管理的容器及其状态
# 注意：期望是 3 个容器（db × 1 + app × 2），Nginx 不在 Docker 里
```

验证 MySQL 真的好了：

```bash
docker compose -f docker/docker-compose.yml exec db mysqladmin ping -h 127.0.0.1 -uroot -p"你改后的强密码"
# exec          = execute，在【已运行的容器】里执行一条命令
# db            = 服务名（compose 里定义的，不是容器名）
# mysqladmin ping = MySQL 自带的探活命令，数据库活着就回 mysqld is alive
# -h 127.0.0.1  = host，连哪个主机（这里是容器内部本机）
# -uroot        = user，用户名 root（-u 和用户名连写，也可写 -u root）
# -p"..."       = password，密码（-p 和密码之间【不能】有空格）
# 期望输出：mysqld is alive
```

验证后端健康：

```bash
curl -s http://localhost:8000/api/health
# -s = silent，静默模式，不显示进度条和连接信息，只输出响应正文
# 8000 = app 容器映射到宿主机的端口（只监听 127.0.0.1，外网访问不到）
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
# apt update      = 刷新软件源索引（不更新软件，只更新「可安装版本清单」）
# &&              = 前一条命令【成功】才执行后一条（; 则不管成功失败都执行）
# apt install -y  = 安装软件；-y = 自动回答 yes，跳过确认提示

# —— CentOS / Rocky ——
yum install -y nginx
# yum = CentOS 的包管理器；install = 安装；-y = 自动确认

# 放行防火墙（系统这层，和安全组是两道）
# Ubuntu：
ufw allow 80
# ufw    = uncomplicated firewall，Ubuntu 的防火墙管理工具
# allow  = 放行规则
# 80     = 端口号（HTTP 默认端口）
# CentOS：
firewall-cmd --permanent --add-port=80/tcp && firewall-cmd --reload
# firewall-cmd  = CentOS 的防火墙管理工具
# --permanent   = 永久生效（写进配置，重启后仍在；不加则重启即失效）
# --add-port=80/tcp = 放行 TCP 协议的 80 端口
# --reload      = 重载配置使永久规则立即生效

# 开机自启并启动
systemctl enable --now nginx
# enable = 开机自启；--now = 顺便立刻启动
```

---

## 第 7 步：放入 Nginx 配置（用宿主机版）

```bash
# 服务器执行
cd /opt/candy-house-portfolio

# 关键点：用 nginx/nginx-host.conf（宿主机版）。deploy/nginx-candy-house.conf 是已弃用的 Docker 版旧配置，已归档到 deploy/archive/，请勿使用。
# 先确认 main 配置实际 include 哪个目录（CentOS 是 conf.d/，Ubuntu 是 sites-enabled/）
grep -n "include" /etc/nginx/nginx.conf
# grep        = 在文件里搜索匹配的文本
# -n          = number，显示匹配内容所在的【行号】
# "include"   = 要搜索的关键词
# /etc/nginx/nginx.conf = 被搜索的文件（Nginx 主配置文件）

# —— CentOS / Rocky：放到 conf.d/ ——
cp nginx/nginx-host.conf /etc/nginx/conf.d/candy-house.conf
rm -f /etc/nginx/conf.d/default.conf
# rm    = remove，删除文件
# -f    = force，强制删除；文件不存在时不报错（脚本里常用，避免中断）

# —— Ubuntu / Debian：放到 sites-enabled/（用软链，main 配置只 include sites-enabled/*）——
cp nginx/nginx-host.conf /etc/nginx/sites-available/candy-house.conf
ln -sf /etc/nginx/sites-available/candy-house.conf /etc/nginx/sites-enabled/candy-house.conf
# ln        = link，创建链接
# -s        = symbolic，软链接（相当于快捷方式，推荐，改源文件同步生效）
# -f        = force，目标已存在就覆盖
# 第 1 个路径 = 源文件真实位置（sites-available = 可用配置仓库）
# 第 2 个路径 = 链接放的位置（sites-enabled = 真正被加载的）

rm -f /etc/nginx/sites-enabled/default
# 删掉默认站点，否则会和我们的配置抢 80 端口 → nginx -t 报 conflicting server name

rm -f /etc/nginx/conf.d/candy-house.conf        # 避免两个发行版都放导致重复监听 80

# 把 404 错误页也放进静态目录（配置里引用了它）
cp deploy/404.html static/404.html
```

> ⚠️ **跨发行版大坑（实测踩过）**：Ubuntu 的 `nginx.conf` 默认只 `include /etc/nginx/sites-enabled/*`，**不读 `conf.d/`**。若把配置放 `conf.d/` 而系统是 Ubuntu，Nginx 实际还在跑默认配置，`/api/*` 不会被代理 → `curl http://localhost/api/health` 返回 404 页。判断方法：`grep include /etc/nginx/nginx.conf` 看它到底加载哪个目录，配置就放哪；放错目录 = “写了但没生效”。

---

## 第 8 步：校验并启动 Nginx

```bash
# 服务器执行
nginx -t
# -t = test，只检查配置文件语法是否正确，不真正启动/重启
# 必须看到 "syntax is ok" 和 "test is successful" 才能 reload

nginx -s reload
# -s      = signal，向正在运行的 Nginx 主进程发送信号
# reload  = 重新加载配置：master 进程起新的 worker 干活，老的 worker 处理完手上的连接才退出
#           → 优雅热加载，不中断现有连接

# 首次启动若 Nginx 还没跑，用：systemctl start nginx  （或 nginx 直接起）

systemctl status nginx --no-pager | head -5
# status      = 查看服务运行状态
# --no-pager  = 一次性输出完，不进入分页器（否则要按 q 才能退出）
# |           = 管道，把左边命令的输出当成右边命令的输入
# head -5     = 只显示前 5 行
# 期望看到 active (running)
```

> 改 Nginx 配置后永远是：`nginx -t && nginx -s reload`（`reload` 优雅热加载、不断连接；`restart`/`systemctl restart` 会先停后起、瞬间断所有连接，非必要不用）。

---

## 第 9 步：端到端验证（浏览器 / curl）

```bash
# 服务器执行
curl -s http://localhost/api/health     # {"status":"ok","db":true,...}
# -s = silent 静默；localhost:80 由宿主机 Nginx 接收，再反代给 app 容器

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
# up -d = 后台创建并启动；--scale app=2 = 扩到 2 个 app 实例

docker compose -f docker/docker-compose.yml down
# down = 停止并移除容器（不加 -v 就【保留】数据卷，数据库数据还在）

docker compose -f docker/docker-compose.yml restart
# restart = 重启容器（配置没变、只是想重新拉起时用）

# 看日志（排错第一现场）
docker compose -f docker/docker-compose.yml logs -f app     # 后端（实时滚动）
# logs      = 查看服务日志
# -f        = follow，实时跟随新日志（按 Ctrl+C 退出）
# app       = 服务名

docker compose -f docker/docker-compose.yml logs -f db      # 数据库

# Nginx 有两套日志：
# ① 文件日志（最常用，看访问/报错细节）：
tail -f /var/log/nginx/access.log
# tail      = 显示文件【末尾】的内容（默认最后 10 行）
# -f        = follow，实时跟随文件新增内容（看日志神器，Ctrl+C 退出）
# access.log = 访问日志：谁访问了什么路径、返回什么状态码

tail -f /var/log/nginx/error.log
# error.log = 错误日志：404/502 的【根本原因】都在这里

# ② systemd 日志（看 Nginx 进程本身有没有起得来）：
journalctl -u nginx -n 50 --no-pager
# journalctl  = 查询 systemd 收集的日志
# -u nginx    = unit，只看 nginx 这个服务单元（unit）的日志
# -n 50       = number，只显示最近 50 行
# --no-pager  = 不分页，一次性输出完

# 扩容 / 缩容后端（改数量后改 nginx-host.conf 的 upstream 行数对应）
docker compose -f docker/docker-compose.yml up -d --scale app=3
# --scale app=3 = 扩到 3 个实例；缩容就改小数字（如 app=1）
# 若只跑 1 个 app，编辑第 7 步放的那个 candy-house.conf，删掉 upstream 里的
# server 127.0.0.1:8001; 那一行，再 nginx -t && nginx -s reload

# 更新代码后重新部署
# 1) 本地 scp 更新文件上来
# 2) 服务器：docker compose -f docker/docker-compose.yml up -d --build --scale app=2
#    --build = 先重新构建镜像再启动。改了 .py 代码【必须】加，否则跑的还是旧镜像
# 3) 若改了 nginx 配置：nginx -t && nginx -s reload

# 备份数据库（重要！）
docker compose -f docker/docker-compose.yml exec -T db \
  mysqldump -uroot -p"你改后的强密码" candy_house > backup_$(date +%F).sql
# exec -T     = 在容器里执行命令；-T = 不分配伪终端(TTY)
#               （脚本里或用 > 重定向时必须加，否则输出会混入终端控制字符）
# mysqldump   = MySQL 官方导出工具，把数据库导出成 SQL 文本
# -uroot      = 用 root 用户连接
# -p"..."     = 密码（-p 与密码之间不能有空格）
# candy_house = 要导出的【数据库名】（不是表名）
# >           = 重定向：把本该打印到屏幕的内容写进文件
# $(date +%F) = 命令替换，把 date +%F 的执行结果插进来
#               date +%F = 按 YYYY-MM-DD 格式输出今天日期
#               → 最终文件名形如 backup_2026-08-29.sql，每天不重名
# \           = 反斜杠，表示这一行没结束，下一行是同一条命令的继续（纯换行方便阅读）
```

---

## 第 11 步：日志怎么看（排错第一现场）

日志是运维的「监控探头」，出问题**第一件事就是看日志**，别瞎猜。下面三类日志分开看。

### 11.1 Nginx 访问日志（access.log）——看「请求结果」

```bash
tail -f /var/log/nginx/access.log          # 实时滚动看新访问
# -f = follow，实时跟随

tail -n 20 /var/log/nginx/access.log       # 只贴最近 20 行
# -n 20 = number，指定显示末尾 20 行（不加 -f 就不实时，打印完即退出）
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
# -f = follow 实时跟随

tail -n 50 /var/log/nginx/error.log
# -n 50 = 只看最后 50 行
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
# -f = follow 实时滚动；app = 服务名，会把该服务所有副本的日志合并输出

# 只贴最近 100 行（不实时）
docker compose -f docker/docker-compose.yml logs --tail=100 app
# --tail=100 = 只显示最后 100 行，打印完立即退出（区别于 -f 的持续跟随）

# 看某个具体实例（容器名形如 candy-house-portfolio-app-1）
docker logs -f candy-house-portfolio-app-1
# docker logs = 直接看【单个容器】的日志（不走 compose，所以要写完整容器名）
# -f          = follow 实时跟随
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
> # --build = 强制重新构建镜像（不加就复用旧镜像，代码改动不生效）
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
| 日志报 `Can't connect to MySQL server on '@db'` / `Name or service not known` | **密码里含 `@`，破坏了 `DATABASE_URL` 的 URL 解析**（URL 用第一个 `@` 分隔密码与主机，导致主机变成 `@db`）。修复：把 `.env` 里 `DATABASE_URL` 密码部分的 `@` 改成 `%40`（如 `candy:pwd%40@db`），再 `docker compose up -d --force-recreate --scale app=2` 重建 app 容器（env 在容器创建时注入，必须重建）；或干脆把密码的 `@` 去掉并重 `down -v` 初始化。教训：数据库密码别用 `@ : / # %` 这些 URL 特殊字符。 |
| 日志报 `Can't connect to MySQL server on 'db'` / `Temporary failure in name resolution` | **app 与 db 不在同一 Docker 网络**，app 解析不了 `db` 这个服务名（DNS 失败）。修复：compose 里 `app` 服务必须加 `networks: [candy-net]`（和 `db` 同一自定义网络）；改完 `docker compose down`（**不加 -v**，保留数据卷）再 `up -d --scale app=2`。记住：`depends_on` 只管启动顺序，不管网络连通。 |
| 日志报 `RuntimeError: 'cryptography' package is required for sha256_password or caching_sha2_password` | **MySQL 8 默认 `caching_sha2_password` 认证，PyMySQL 做 RSA 加密必须装 `cryptography`**。修复：在 `api/requirements.txt` 加 `cryptography==43.0.1`，然后 `docker compose up -d --build --scale app=2`（**必须 `--build` 重建镜像**，否则还在用旧镜像）。 |
| `docker compose build` 报 `failed to resolve source metadata for docker.io/library/python:3.11-slim ... lookup hub-mirror.c.163.com ... no such host` | **Docker 守护进程配的镜像加速器（registry-mirrors）域名失效/DNS 解析不了**，导致拉取基础镜像元数据失败（与代码无关）。修复：`cat /etc/docker/daemon.json` 查看（`cat` = 一次性打印文件全部内容），把失效镜像源换成可用的（如 `https://docker.m.daocloud.io`）或清空 `{"registry-mirrors": []}`；再 `systemctl daemon-reload && systemctl restart docker`（`daemon-reload` = 让 systemd 重新读取改过的配置文件；`restart` = 重启服务）；随后 `docker compose up -d --build --scale app=2`。注意：`restart docker` 会短暂停掉运行中的容器，但命名数据卷（如 `mysql_data`）不丢，重启 `up` 后库仍在。 |
| 展示页空白 / 取数失败                            | 后端没连 MySQL：`logs app`；或 Nginx `proxy_pass` 端口对不上        |
| `nginx -t` 报 `conflicting server name`  | 默认站点没删，重做第 7 步的 `rm`                                    |
| 加的作品不显示                                 | 看 Nginx 日志 `journalctl -u nginx`；确认前端请求 `/api/works`    |

---

## 附录：命令参数速查表

> 本手册出现过的所有参数，集中在这里复习。按命令分组。

### Docker / Compose

| 参数 | 全称 / 含义 | 作用 |
|---|---|---|
| `-f <文件>` | file | 指定 compose 文件路径 |
| `up` | — | 创建并启动容器 |
| `-d` | detached | 后台运行，不占终端 |
| `--build` | — | 启动前先重新构建镜像（改代码必加） |
| `--scale 服务=N` | — | 把某服务扩/缩到 N 个实例 |
| `--force-recreate` | — | 强制重建容器（改了 .env 后必加，环境变量在创建时注入） |
| `down` | — | 停止并移除容器、网络 |
| `-v` | volumes | **连数据卷一起删（会清空数据库，慎用）** |
| `restart` | — | 重启容器 |
| `ps` | process status | 列出容器及状态 |
| `logs` | — | 查看日志 |
| `-f` | follow | 实时跟随日志（Ctrl+C 退出） |
| `--tail=N` | — | 只显示最后 N 行，不实时 |
| `exec` | execute | 在已运行的容器里执行命令 |
| `-T` | no-TTY | 不分配伪终端（配合 `>` 重定向时必须加） |

### systemctl / journalctl

| 参数 | 全称 / 含义 | 作用 |
|---|---|---|
| `enable` | — | 设为开机自启 |
| `--now` | — | 配合 enable，顺便立刻启动 |
| `start` / `stop` / `restart` | — | 启动 / 停止 / 重启服务 |
| `status` | — | 查看服务运行状态 |
| `daemon-reload` | — | 让 systemd 重新读取改过的配置文件 |
| `journalctl -u <服务>` | unit | 只看某个服务的 systemd 日志 |
| `-n N` | number | 只显示最近 N 行 |
| `--no-pager` | — | 不分页，一次性输出完 |

### Nginx

| 参数 | 全称 / 含义 | 作用 |
|---|---|---|
| `-t` | test | 只检查配置语法，不启动（改配置后先跑这个） |
| `-s reload` | signal | 优雅热加载配置，不断开现有连接 |
| `-s stop` | signal | 立即停止 |

### 文件 / 目录操作

| 参数 | 全称 / 含义 | 作用 |
|---|---|---|
| `ls` | list | 列出目录内容 |
| `ls -l` | long | 长格式（权限/属主/大小/时间） |
| `ls -a` | all | 含 `.` 开头的隐藏文件 |
| `ls -h` | human-readable | 大小显示为 K/M/G |
| `cd` | change directory | 切换目录 |
| `cp` | copy | 复制文件 |
| `-r` | recursive | 递归，用于复制整个目录 |
| `rm` | remove | 删除 |
| `-f` | force | 强制；文件不存在也不报错 |
| `ln -s` | symbolic link | 创建软链接（快捷方式） |

### 文本查看 / 搜索

| 参数 | 全称 / 含义 | 作用 |
|---|---|---|
| `cat` | concatenate | 一次性打印文件全部内容 |
| `tail` | — | 显示文件末尾（默认 10 行） |
| `tail -f` | follow | 实时跟随新增内容 |
| `tail -n N` | number | 显示末尾 N 行 |
| `grep "关键词" 文件` | — | 在文件里搜索文本 |
| `grep -n` | number | 同时显示行号 |
| `head -N` | — | 显示开头 N 行 |

### 网络 / 下载

| 参数 | 全称 / 含义 | 作用 |
|---|---|---|
| `curl` | — | 命令行 HTTP 请求工具 |
| `curl -s` | silent | 静默，不显示进度条 |
| `curl -f` | fail | 服务器报错时不输出错误页面 |
| `curl -S` | show-error | 配合 -s，出错时才显示 |
| `curl -L` | location | 自动跟随重定向 |
| `scp` | secure copy | 基于 SSH 远程拷文件 |
| `scp -r` | recursive | 拷贝整个目录 |
| `ssh 用户@主机` | secure shell | 远程登录 |

### Shell 符号

| 符号 | 含义 | 作用 |
|---|---|---|
| `\|` | 管道 | 把左边命令的输出，作为右边命令的输入 |
| `>` | 重定向 | 把输出写进文件（**会覆盖**原文件） |
| `>>` | 追加重定向 | 把输出追加到文件末尾（不覆盖） |
| `&&` | 与 | 左边【成功】才执行右边 |
| `;` | 顺序 | 不管成功失败，依次执行 |
| `\` | 续行符 | 一行没写完，下一行接着算同一条命令 |
| `$(命令)` | 命令替换 | 把命令的执行结果插进当前位置 |
| `#` | 注释 | 后面的内容不执行，仅作说明 |

---

## 一句话记住

**Docker 管 db+app（`docker compose`），Nginx 管对外（`systemctl`）；两边密码靠 `api/.env` 一份搞定；访问不通先查安全组→防火墙→服务状态这三道。**
