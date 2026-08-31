# 糖果屋 · 完整开发 → 上线流程

> 这份文档管的是**代码怎么从你的手指头流到线上**，以及每一环该怎么验证、怎么回滚。  
> 具体某条命令不懂，查 `STEP-BY-STEP.md`（那里每条命令都有参数注释）。

---

## 0. 先说清楚假设（想改随时说）

因为这几个决策会影响整条流水线，我先按推荐值定了，你觉得不合适告诉我，改动不大：

| 决策点       | 当前取值                              | 为什么这么选                    |
| --------- | --------------------------------- | ------------------------- |
| 写代码的地方    | **Windows 开发机**（F 盘）              | 你有 IDE；VM 只做测试，职责最干净      |
| 分支策略      | `main` / `develop` / `feature/*`  | 测试和生产天然隔离，是最标准的做法         |
| 项目路径      | 三处统一 `/opt/candy-house-portfolio` | **消除路径差异**，nginx 配置两份环境通用 |
| 生产环境（京东云） | **本阶段先不动**                        | 等测试环境跑顺了再做，见第 9 节         |

---

## 1. 三环境的职责（先记住这张表）

| 环境       | 机器              | 路径                                            | 跟哪个分支         | .env 密码    | 谁能碰   |
| -------- | --------------- | --------------------------------------------- | ------------- | ---------- | ----- |
| **开发机**  | Windows（F 盘）    | `F:\005_code\WORKbuddy\candy-house-portfolio` | `feature/*`   | 不需要跑       | 你     |
| **测试环境** | VM `ubuntu-dev` | `/opt/candy-house-portfolio`                  | `develop`     | 简单即可       | 你     |
| **生产环境** | 京东云服务器          | `/opt/candy-house-portfolio`                  | `main`（或 tag） | **强密码，唯一** | 你（谨慎） |

**铁律**：

1. **密码永远不进 git**。每个环境有自己独立的 `api/.env`，都被 `.gitignore` 挡着。
2. **生产只认 `main`**，测试只认 `develop`。生产绝不直接改代码。
3. **GitHub 是唯一中转**。环境之间不互相拷文件，一律过 git。

---

## 2. 代码流向图

```text
┌────────────────────────────────────────────────────────────────┐
│ ① 开发机（Windows）                                             │
│    改代码 → 建 feature/xxx 分支 → commit → push                 │
└────────────────────────────────────────────────────────────────┘
                            │ git push
                            ▼
┌────────────────────────────────────────────────────────────────┐
│ ② GitHub（唯一中转站 · 不存任何密码）                            │
│      main（生产）     develop（测试）     feature/*（开发中）     │
└────────────────────────────────────────────────────────────────┘
        │                                        │
   pull develop                             pull main
        ▼                                        ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│ ③ 测试环境 VM（现在做这个）    │   │ ④ 生产环境 京东云（后面做）    │
│   ./deploy/deploy-dev.sh      │   │   ./deploy/deploy-prod.sh     │
│   健康检查失败会自动回滚        │   │   健康检查失败会自动回滚        │
│   密码随便，数据丢了不心疼      │   │   ⚠️ 强密码 + 先备份           │
└──────────────────────────────┘   └──────────────────────────────┘
```

**合并顺序永远是单向的**：`feature/*` → `develop` → `main`。绝不反向合并。

---

## 3. 分支策略（日常就这三步）

```
feature/xxx   开发新功能，一人一条，用完即删
    │
    │ (测试环境验过了) 合并
    ▼
develop       测试环境永远对应这个分支，"当前待验证的版本"
    │
    │ (确认可以上线了) 合并 + 打 tag
    ▼
main          生产环境对应这个分支，"已上线的稳定版本"
```

**为什么多一层 `develop`？**  
因为 `main` 直接对应线上。如果测试和 VM 都拉 `main`，那你 push 的瞬间生产就"该更新了"——哪怕你还没测。多一层 `develop`，等于给生产加了一道缓冲：**只有你主动合进 `main`，生产才会动。**

---

## 4. 阶段一：搭建测试环境（VM）—— 现在就做这个

### 4.1 在 Windows 上建好 `develop` 分支并推上去

```bash
# ==== Windows 开发机执行（Git Bash）====
cd /f/005_code/WORKbuddy/candy-house-portfolio

git branch develop
# git branch = 分支管理；develop = 分支名；不带 -d 就是【新建】分支（此时还没切换过去）

git push -u origin develop
# push      = 推送到远程仓库
# -u        = upstream，把本地 develop 和远程 develop 关联起来（下次直接 git push 就行）
# origin    = 远程仓库的默认别名（就是 GitHub 上那个仓库）
# develop   = 要推送的分支名
```

确认三个分支都在：

```bash
git branch -a
# -a = all，列出【所有】分支（本地 + 远程；远程的会带 remotes/ 前缀）
```

---

### 4.2 在 VM 上：建目录、克隆（注意路径用 `/opt`，跟生产一致）

```bash
# ==== VM 执行（candyapp 用户）====

sudo mkdir -p /opt/candy-house-portfolio
# sudo   = superuser do，以 root 权限执行后面这条命令
# mkdir  = make directory，创建目录
# -p     = parents，父目录不存在就一并创建；目录已存在也不报错（幂等，可重复执行）

sudo chown -R candyapp:candyapp /opt/candy-house-portfolio
# chown      = change owner，改文件/目录的属主
# -R         = recursive，递归，目录下所有内容一起改
# candyapp:candyapp = 新的【用户:用户组】
# 目的：/opt 默认是 root 的，不改属主的话 candyapp 没权限往里 clone

cd /opt
# cd = change directory，切换目录

git clone -b develop git@github.com:ixuan1/candy-house-portfolio.git
# clone      = 把远程仓库完整下载到本地
# -b develop = branch，克隆完成后直接切到 develop 分支（不加 -b 则默认 main）
# 后面       = 仓库地址（SSH 方式，需先配好 SSH 密钥）

cd /opt/candy-house-portfolio
```

> ⚠️ **为什么非要用 `/opt` 而不是 `/home/candyapp`？**  
> 因为 `nginx/nginx-host.conf` 第 28 行写死了 `root /opt/candy-house-portfolio/static;`。  
> 路径跟生产完全一致 → **这份 nginx 配置两份环境通用，一行都不用改**。  
> 如果放 `/home/candyapp`，你就得额外 `sed` 改路径，两份配置从此开始漂移，  
> 迟早出现"测试好好的、线上 404"这种最难受的 bug。

---

### 4.3 在 VM 上：配置 .env（测试环境可以用简单密码）

```bash
# ==== VM 执行（项目根目录 /opt/candy-house-portfolio）====

cp api/.env.example api/.env
# cp = copy，复制文件；第 1 个参数=源文件（模板），第 2 个参数=目标文件

sed -i 's/^MYSQL_PASSWORD=.*/MYSQL_PASSWORD=CandyDev2026/' api/.env
# sed           = 流编辑器，用来批量替换文本
# -i            = in-place，直接修改文件内容（不加则只打印到屏幕，不改文件）
# 's/原/新/'     = substitute 替换命令
# ^MYSQL_PASSWORD = ^ 表示行首，只匹配以这个开头的行
# .*            = 正则，匹配该行剩下所有字符
# 整体效果：把整行替换成新密码

sed -i 's/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=CandyDev2026/' api/.env
sed -i 's#^DATABASE_URL=.*#DATABASE_URL=mysql+pymysql://candy:CandyDev2026@db:3306/candy_house#' api/.env
# 注意这里分隔符用 # 而不是 /，因为替换内容里本身含有 /（如 mysql+pymysql://），用 / 会冲突

grep -E 'MYSQL_PASSWORD|MYSQL_ROOT_PASSWORD|DATABASE_URL' api/.env
# grep    = 在文件里搜索文本
# -E      = extended regex，启用扩展正则（这里用 | 表示"或者"，匹配三个关键词任一）
# 目的：核对三处密码【完全一致】，这是最常见的启动失败原因
```

> ⚠️ **密码只用字母+数字**（示例 `CandyDev2026`）。  
> 别用 `@`，它在 `DATABASE_URL` 里会被当成"密码和主机的分隔符"，  
> 导致主机解析成 `@db` → app 连不上库、无限重启。这个坑你踩过一次了。

---

### 4.4 在 VM 上：装 Nginx 并放配置（路径一致，无需改任何东西）

```bash
sudo apt update && sudo apt install -y nginx
# apt update     = 刷新软件源索引
# &&             = 前一条命令【成功】才执行后一条
# apt install -y = 安装；-y = 自动回答 yes，跳过确认提示

sudo cp nginx/nginx-host.conf /etc/nginx/sites-available/candy-house.conf
# sites-available = "可用配置仓库"，放这里不会被加载

sudo ln -sf /etc/nginx/sites-available/candy-house.conf /etc/nginx/sites-enabled/candy-house.conf
# ln        = link，创建链接
# -s        = symbolic，软链接（快捷方式，改源文件同步生效）
# -f        = force，目标已存在就覆盖
# sites-enabled = "已启用配置"，Ubuntu 的 nginx.conf 只 include 这个目录

sudo rm -f /etc/nginx/sites-enabled/default
# rm = remove 删除；-f = force 强制（文件不存在也不报错）
# 必须删默认站点，否则它和我们的配置抢 80 端口 → nginx -t 报 conflicting server name

sudo cp deploy/404.html static/404.html
# 配置里 error_page 引用了 404.html，确保静态目录里有这个文件

sudo nginx -t
# -t = test，只检查配置语法，不启动。必须看到 syntax is ok / test is successful

sudo nginx -s reload
# -s      = signal，向运行中的 nginx 主进程发信号
# reload  = 优雅热加载，不中断现有连接
```

> 💡 因为路径统一成了 `/opt`，**这里不需要任何 sed 改路径**——这就是一致性的收益。

---

### 4.5 在 VM 上：首次启动

```bash
cd /opt/candy-house-portfolio

docker compose -f docker/docker-compose.yml up -d --build --scale app=2
# -f             = file，指定 compose 文件路径
# up             = 创建并启动容器
# -d             = detached，后台运行
# --build        = 先重新构建镜像（首次或改了代码必加）
# --scale app=2  = 把 app 扩到 2 个实例

docker compose -f docker/docker-compose.yml ps
# ps = process status，列出容器状态
# 期望：3 个容器（db × 1 + app × 2），全部 Up / healthy。Nginx 不在 Docker 里，别找它
```

---

### 4.6 验证（分三层，逐层排除）

```bash
# 第 1 层：直连后端，确认 app + db 本身没问题（绕过 Nginx）
curl -s http://127.0.0.1:8000/api/health
# -s = silent 静默；8000 = app 实例 1 映射的端口
curl -s http://127.0.0.1:8001/api/health
# 8001 = app 实例 2
# 期望：{"status":"ok","db":true,...}

# 第 2 层：走 Nginx，确认反代 + 静态资源没问题
curl -s http://localhost/api/health
curl -I http://localhost
# -I = head，只请求响应头（不看正文），期望 200 OK

# 第 3 层：从宿主机浏览器访问（确认防火墙 + 网络通）
hostname -I
# hostname = 显示主机名；-I = 列出本机所有 IP 地址
sudo ufw allow 80/tcp
# ufw = Ubuntu 防火墙；allow 80/tcp = 放行 TCP 80 端口
```

浏览器打开 `http://<VM_IP>/` 和 `http://<VM_IP>/admin.html`。

> **分层的意义**：如果第 1 层就挂了，问题在 app/db，跟 Nginx 无关；  
> 第 1 层通、第 2 层挂，问题在 Nginx 配置；两层都通、第 3 层挂，问题在防火墙或网络。  
> 不分层的话，你只能瞎猜。

---

## 5. 日常开发循环（每天就这套动作）

### 5.1 开发机：写功能

```bash
# ==== Windows 执行 ====
cd /f/005_code/WORKbuddy/candy-house-portfolio

git checkout develop
# checkout = 切换分支；develop = 目标分支

git pull origin develop
# pull = 拉取远程最新代码并与本地合并（等价于 fetch + merge 两步）
# 目的：开工前先同步，避免基于旧代码开发

git checkout -b feature/add-audit-log
# -b = branch，【新建并切换】到该分支
# feature/add-audit-log = 分支名，约定用 feature/ 前缀 + 简短描述

# ...这里改你的代码...

git add -A
# add = 把改动加入暂存区；-A = all，包含新增、修改、删除（不加 -A 则不含删除）

git commit -m "feat: 增加审计日志"
# commit = 把暂存区的改动提交到本地仓库
# -m     = message，后面跟提交说明
# 建议格式：feat(新功能) / fix(修bug) / docs(文档) / chore(杂项)

git push -u origin feature/add-audit-log
# -u = upstream，建立本地分支与远程分支的关联（首次推送加 -u，之后直接 git push）
```

### 5.2 测试环境：部署并验证

```bash
# ==== VM 执行 ====
cd /opt/candy-house-portfolio
./deploy/deploy-dev.sh feature/add-audit-log
# 参数 = 要部署的分支名；不传则默认 develop
# 脚本会：拉代码 → 构建 → 健康检查 → 【失败自动回滚】
```

### 5.3 测试通过：合入 develop

```bash
# ==== Windows 执行 ====
git checkout develop
git merge feature/add-audit-log
# merge = 把指定分支的改动合并进【当前所在分支】（这里是 develop）

git push origin develop
# 推送合并结果到远程

git branch -d feature/add-audit-log
# -d = delete，删除已合并的分支（保持分支列表干净）
# 如果分支还没合并，用 -D 强制删除（会丢改动，慎用）
```

### 5.4 确认可上线：develop → main（**本阶段先跳过，等生产阶段再做**）

```bash
git checkout main
git merge develop
git tag -a v1.0.0 -m "第一个可上线版本"
# tag      = 打标签，给某个提交起个固定名字
# -a       = annotated，创建带注释的标签（推荐，会记录作者、时间、说明）
# v1.0.0   = 标签名，约定用语义化版本（主版本.次版本.修订号）
# -m       = 标签的说明文字
# 作用：main 上每个可上线版本都有 tag，回滚时能精确回到某一点

git push origin main --tags
# --tags = 把本地所有标签一并推送到远程（标签默认不会跟着分支推送，必须显式加）
```

---

## 6. 部署脚本（已写好，直接用）

| 脚本                      | 在哪跑     | 默认拉什么              | 回滚能力                    |
| ----------------------- | ------- | ------------------ | ----------------------- |
| `deploy/deploy-dev.sh`  | VM 测试环境 | `develop`（可传分支名覆盖） | 健康检查失败自动回滚到上一个提交        |
| `deploy/deploy-prod.sh` | 京东云生产   | `main`（可传分支名或 tag） | 失败自动回滚 + **部署前自动备份数据库** |

```bash
# 用法示例
./deploy/deploy-dev.sh                     # 拉默认分支 develop
./deploy/deploy-dev.sh feature/xxx         # 拉指定分支（测功能时这么用）
./deploy/deploy-prod.sh                    # 生产拉 main
./deploy/deploy-prod.sh v1.0.0             # 生产拉指定 tag（推荐，可追溯）
```

脚本里每一步都有注释，第一次用建议先打开看一遍。

---

## 7. 每次部署后的验证清单

- [ ] `docker compose ps` —— 3 个容器全部 `Up (healthy)`
- [ ] `curl http://127.0.0.1:8000/api/health` —— 返回 `"db":true`（**db 必须是 true，false 说明连不上库**）
- [ ] `curl -I http://localhost` —— `200 OK`
- [ ] `/admin.html` 增删改一条，回首页能显示（端到端跑通）
- [ ] `docker compose logs --tail=50 app` —— 无 ERROR 堆栈

---

## 8. 回滚

**测试环境**——脚本已自动回滚。手动回滚：

```bash
cd /opt/candy-house-portfolio
git log --oneline -5
# log      = 查看提交历史
# --oneline = 每条提交压缩成一行显示（只显示短 hash + 提交说明）
# -5       = 只显示最近 5 条

git checkout <上一个提交的hash>
# checkout + 提交 hash = 让工作区回到那次提交的状态

docker compose -f docker/docker-compose.yml up -d --build --scale app=2
```

**生产环境**（阶段二才用）：优先用 tag 回滚，比 hash 可读性好。

```bash
git checkout v1.0.0
docker compose -f docker/docker-compose.yml up -d --build --scale app=2
```

> ⚠️ 回滚只能回**代码**，回不了**数据库**。如果新版本改过表结构，回滚代码后数据结构可能对不上——  
> 所以生产部署前一定要先备份（脚本已自动做）。

---

## 9. 阶段二：生产上线（京东云）—— 等测试环境跑顺再做

到这一步时，生产只需要做一次初始化：

1. 服务器上已有 `/opt/candy-house-portfolio`，改成用 git 管理（或重新 clone 到临时目录再切换）。
2. 生产 `.env` 用**强密码**，且**绝不提交**（`.gitignore` 已挡住，CI 也会拦截）。
3. 把 `deploy/deploy-prod.sh` 传上去并 `chmod +x`。
4. 之后每次上线：Windows 上 `develop → main` 打 tag → 服务器上 `./deploy/deploy-prod.sh v1.0.0`。

**生产额外红线**：

- 部署前脚本会自动 `mysqldump` 备份，别跳过。
- **永远不要在生产跑 `docker compose down -v`**（`-v` 删数据卷 = 删库）。
- 生产不直接改代码，一切走 git。

---

## 10. 数据库与迁移（重要，容易踩）

MySQL 的 `init.sql` **只在数据卷为空时执行一次**。这意味着：

| 场景        | 后果                         | 怎么办                                         |
| --------- | -------------------------- | ------------------------------------------- |
| 测试环境想重置数据 | 正常                         | `docker compose down -v` 再 `up -d`（测试环境随便来） |
| 生产改了表结构   | `git pull` **不会**自动执行新 SQL | 手动进容器执行，或写迁移脚本                              |
| 生产想重置     | ⚠️ **绝对不行**                | 用备份恢复，别用 `down -v`                          |

测试环境因为数据可丢，最简单：**改了 `init.sql` 就 `down -v` 重建**，省事。

---

## 11. 环境差异对照（排错时先看这个）

| 项目       | 测试环境 VM                             | 生产 京东云                               |
| -------- | ----------------------------------- | ------------------------------------ |
| 路径       | `/opt/candy-house-portfolio`        | `/opt/candy-house-portfolio`（**一致**） |
| 分支       | `develop`                           | `main` / tag                         |
| nginx 配置 | `nginx/nginx-host.conf`（**同一份，通用**） | 同一份                                  |
| 容器数量     | 3（db + app×2）                       | 3（db + app×2）                        |
| .env     | 简单密码即可                              | **强密码，独立一份**                         |
| 数据       | 可丢                                  | **不可丢，先备份**                          |
| 防火墙      | `ufw allow 80`                      | 京东云安全组 + 系统防火墙（**两道**）               |

---

## 12. 当前阶段任务清单

**阶段一（现在）**：

- [ ] Windows 建 `develop` 分支并 push
- [ ] VM 配 SSH 密钥，能 `ssh -T git@github.com`
- [ ] VM clone 到 `/opt/candy-house-portfolio`（切 `develop`）
- [ ] VM 配 `.env`（纯字母数字密码，三处一致）
- [ ] VM 装 nginx + 放配置 + `nginx -t && nginx -s reload`
- [ ] VM 启动 3 个容器，三层验证全过
- [ ] 浏览器能打开 `/` 和 `/admin.html`

**阶段二（测试环境稳定后）**：见第 9 节。
