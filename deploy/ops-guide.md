# 运维入门综合讲解（结合糖果屋项目）

> 这是给你的「初级运维」补课材料。每个知识点都贴着我们的糖果屋项目讲，方便你边看边在服务器上试。

---

## 1. 什么是“部署”？把我们写的代码变成别人能访问的服务

部署 = 把代码放到一台一直开着的机器（服务器）上，让它以「服务」的形式持续运行。

糖果屋的链路：**浏览器 → Nginx(80) → FastAPI ×N → MySQL**。
你访问的一个网页，背后其实串起了 4 个角色。运维的核心，就是让这条链**永远通、坏得快、查得清**。

---

## 2. 容器 vs 裸进程（你先懂概念）

| | Docker 容器（本项目用的） | 裸机 systemd 进程（作业） |
|---|---|---|
| 隔离 | 强，自带运行环境，换机器也能跑 | 弱，依赖本机装好的 Python/Nginx |
| 启动 | `docker compose up` 一条 | `systemctl start xxx` |
| 一致性 | 高（“在我电脑能跑”=“在服务器能跑”） | 易因环境差异翻车 |
| 适合 | 入门首选、易复现 | 理解“服务是怎么被系统管的” |

**结论**：先用 Docker 跑通整体（你已会），再用第 8 节的作业理解裸机，两者对比着学最扎实。

---

## 3. 反向代理（Nginx 在这里干嘛）

- **正向代理**：你（客户端）通过它访问外网（翻墙那种）。
- **反向代理**：外部用户访问 Nginx，Nginx 再把请求**转发给内网的后端**（FastAPI）。用户**不知道**背后有几台后端、IP 是多少。

本项目的 `location /api/ { proxy_pass http://candy_app_upstream; }` 就是反向代理：
- 对外只暴露 80 一个口子（安全面小）。
- 后端容器把 8000 映射到宿主机**回环地址 127.0.0.1**，只有同在宿主机的 Nginx 能访问，外网直接打不到后端（安全组也没开 8000）。
- Nginx 还能做 SSL 终结、缓存、限流、日志——以后都在这一层加。

> 本项目 Nginx 跑在**宿主机**原生环境（systemd 托管，配置见 `nginx/nginx-host.conf`），Docker 里**不再起 nginx 容器**——这是比“全 Docker”更贴近传统运维的部署方式，也方便你直接改 Nginx 配置、看 `/var/log/nginx` 日志。Docker 只负责 db + app。

---

## 4. 负载均衡（为什么起 2 个 app）

单台后端挂了 = 网站挂。起多台，流量分摊，一台挂了另一台顶上。

本项目用 Nginx 的 `upstream`：

```nginx
upstream candy_app_upstream {
    least_conn;          # 最少连接优先（比轮询更聪明）
    server app:8000;     # app 是 compose 服务名，扩容后解析到多个容器
}
```

扩容命令：`docker compose up -d --scale app=2`。
- 为什么能分到多台？Docker 内置 DNS（`127.0.0.11`）会把 `app` 解析成多个副本 IP；Nginx 配了 `resolver` 后会定期重解析，所以**扩容后不必重启 Nginx**。
- 会话保持：本项目无登录态，无需 sticky；若以后有登录，再加 `ip_hash` 或上 Redis 存会话。

---

## 5. 健康检查与自愈（服务挂了别等我睡醒）

两层：
1. **容器级**：`docker-compose.yml` 里 `healthcheck` + `restart: unless-stopped` → 容器进程挂了，Docker 自动拉起。
2. **网关级**：`proxy_next_upstream error timeout http_502 http_503;` → 某后端返回 502/503，Nginx 把这次请求转给下一台，用户无感。

调试面板里的 `/api/health` 就是给这两层探活用的“探针”。

---

## 6. 持久化：容器删了，数据不能没

MySQL 数据写在容器内的 `/var/lib/mysql`，但**容器本身是临时的**（删了就没）。所以：

```yaml
volumes:
  - db_data:/var/lib/mysql     # 挂到宿主机命名卷
```

`docker compose down` 不会删卷；只有 `down -v` 才删。**生产环境永远别随手 `-v`**。
同理，前端/配置通过 `volumes` 挂载文件，改配置 `docker compose up -d` 重新挂载即可。

---

## 7. 安全基线（入门必守）

- **安全组只开 80/443**，3306 绝不对外（MySQL 只在 Docker 内网，靠服务名 `db` 访问）。
- **最小权限 DB 用户**：项目用的是 `candy` 普通用户，不是 root；真实环境再收细到只授权 `candy_house` 库。
- **密码不进镜像/版本库**：用 `.env`，`.env` 别提交 git（加 `.gitignore`）。
- **CORS 生产收紧**：`main.py` 里 `allow_origins=["*"]` 仅调试用，上线改成你的域名。
- **及时打补丁**：`docker compose pull` 更新基础镜像，关注 MySQL/Nginx 安全公告。

---

## 8. 备份（运维的底线）

MySQL 备份一条命令（在服务器上，`candy_db` 是容器名）：

```bash
docker compose exec -T db mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" candy_house \
  | gzip > candy_house_$(date +%F).sql.gz
```

进阶：写个 cron 每天凌晨跑上面这条，保留 7 天。恢复：`gunzip < xxx.sql.gz | docker compose exec -T db mysql -uroot -p密码 candy_house`。

---

## 9. 日志：排错第一现场

| 想看什么 | 命令 |
|---|---|
| 后端报错 | `docker compose logs -f app` |
| 网关/反代 | `docker compose logs -f nginx` |
| 数据库 | `docker compose logs db` |
| 全部 | `docker compose logs` |

日志要会看关键字：`ERROR`、Traceback、连接拒绝 `Connection refused`（多半是 `db` 没起或密码错）、`Address already in use`（端口冲突）。

---

## 10. 监控告警入门（从“坏了才知道”到“快坏就知”）

最小可用：写个定时探活脚本，访问 `/api/health`，非 200 就发通知（邮件/飞书/微信）。

```bash
# crontab -e 加一行：每 5 分钟探活
*/5 * * * * curl -f http://localhost/api/health || echo "糖果屋 API 挂了" | mail -s "告警" you@example.com
```

再往上走就是 Prometheus + Grafana（CPU/内存/请求量/错误率面板），等你玩熟容器再上。

---

## 11. 作业：用裸机 systemd 再部署一遍（对比学习）

Docker 让你“一键”，但初级运维应该理解**服务是怎么被操作系统管起来的**。请在另一台测试机（或同一台另开端口）照做：

1. 服务器装 Python 3.11、`mysql-server`、Nginx（yum/apt）。
2. 建库建表：把 `db/init.sql` 在 MySQL 里执行；创建 `candy` 用户并授权。
3. 后端：在 `/opt/candy-house-portfolio/api` 跑 `pip install -r requirements.txt`，用 **systemd** 托管 uvicorn：
   ```ini
   # /etc/systemd/system/candy-api.service
   [Unit]
   Description=Candy House API
   After=network.target mysql.service
   [Service]
   User=www-data
   WorkingDirectory=/opt/candy-house-portfolio/api
   Environment=DATABASE_URL=mysql+pymysql://candy:密码@127.0.0.1:3306/candy_house
   ExecStart=/usr/bin/uvicorn main:app --host 127.0.0.1 --port 8000
   Restart=on-failure
   [Install]
   WantedBy=multi-user.target
   ```
   然后 `systemctl daemon-reload && systemctl enable --now candy-api`。
4. Nginx：把 `nginx/nginx.conf` 的 `upstream` 改成 `server 127.0.0.1:8000;`（裸机下没有 Docker DNS，用 IP），`root` 指向 `/opt/candy-house-portfolio/static`，`nginx -t && systemctl reload nginx`。
5. 想做负载均衡就**起 2 个 systemd 实例**（端口 8000/8001），upstream 写两个 `server`。
6. 对照 Docker 版，回答自己：容器帮我自动做了哪几件 systemd 里要手搓的事？（答案：环境隔离、依赖启动顺序、健康检查自愈、网络互通——逐项体会）

做完这份作业，你就同时懂了“现代容器化”和“传统进程管理”两条路，这才是真正入门。

---

## 12. MySQL 容器化：原理与运维要点（补）

上面 §6/§8 讲了持久化和备份，这里补 MySQL 镜像特有的两个“运维直觉”，正好把你刚在 README 第 2.5 步动手做过的内容提炼成知识。

**① 初始化脚本只跑一次（initdb 机制）**
MySQL 官方镜像启动时会扫描 `/docker-entrypoint-initdb.d/` 目录，对里面的 `.sql`/`.sh` **仅当数据目录为空（首次初始化）时才执行**。本项目 `db/init.sql` 就是靠这个自动建表，你从没手动进库敲过建表语句。
→ 运维教训：改表结构**别指望改 init.sql 自动生效**。要改结构，要么进库手动 `ALTER`，要么停机清卷重来（会丢数据，仅测试用）。**生产环境的表变更要走“数据库迁移（migration）”**（以后学 Alembic / Flyway），把每一次结构变更写成带版本的脚本，可回滚、可审计——这是和“随手改库”最重要的分水岭。

**② 数据库的“安装”=“拉镜像”**
传统运维 `yum install mysql-server` 在容器世界变成了 `image: mysql:8.0`。镜像自带运行环境，换机器 `docker compose up` 就还原——**这正是容器“环境一致性”的价值**（呼应 §2）。版本、字符集、时区通过环境变量/启动参数固定，写进文件，可复现、可审计。当你能在 30 秒内用一份 `docker-compose.yml` 在任意云主机还原出一模一样的 MySQL+应用，你就体会到了基础设施即代码（IaC）的雏形。

完整的“MySQL 在 Docker 里怎么装 / 怎么验证 / 怎么手动 `docker run` / 常见坑”手把手步骤，见 **deploy/README.md 第 2.5 步**。

**③ 排错常识：Compose 的相对路径以“文件所在目录”为基准**
你刚才在服务器上遇到的 `env file .../docker/api/.env not found`，根因就是这点：本项目 `docker-compose.yml` 放在 `docker/` 子目录，compose 把所有相对路径（`build`、`volumes`、`env_file`）都按 `docker/` 这个目录去解析，所以必须用 `../` 才能指到项目根的 `api/`、`db/`。同理，`-f docker/docker-compose.yml` 也要在**项目根目录**执行，否则连 compose 文件本身都找不到。这是 Docker Compose 最容易被忽略的一条规则：**相对路径 = 相对于 compose 文件，不是当前 shell 目录**。
