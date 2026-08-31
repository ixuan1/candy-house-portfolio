#!/usr/bin/env bash
# ============================================================
#  糖果屋 · 文件同步 + 部署脚本（在本机执行，非服务器）
#  作用：把项目【同步】到京东云，并用 Docker Compose 起起来（含 app×2 负载均衡）
#
#  ⚠️ 为什么用 rsync 而不是 scp？
#     scp 只会"复制本地有的"，不会删除"服务器上有、本地已删掉"的文件。
#     后果：改名的 nginx 配置、删掉的 .py 会在服务器上残留且继续生效。
#     rsync --delete 才是真正的"同步"（增/改/删 三向一致）。
# ============================================================
set -euo pipefail
# set -e = 任何命令失败立即退出；-u = 用了未定义变量就报错；-o pipefail = 管道中任一环节失败即算失败

# ===================== 按需修改 =====================
SERVER_USER="candyapp"          # 非 root 部署：单独的应用用户（需先建好并加入 docker 组）
SERVER_IP="你的服务器公网IP"       # 改成京东云公网 IP
REMOTE_DIR="/opt/candy-house-portfolio"
# ⚠️ 前置：服务器上需先一次性建好目录并改属主（见 deploy/DEPLOY-CANDYAPP.md）：
#       root 会话执行：mkdir -p /opt/candy-house-portfolio && chown -R candyapp:candyapp /opt/candy-house-portfolio
#       否则 candyapp 无法在 /opt 下创建/写入目录。
# ===================================================

# DRY_RUN=1 ./deploy.sh  →  只预演打印将要发生的变更，不真改服务器（强烈建议第一次这么跑）
DRY_RUN="${DRY_RUN:-0}"
# ${VAR:-默认值} = 变量未设置或为空时取默认值

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# $(dirname "$0") = 本脚本所在目录（deploy/）
# cd .. && pwd    = 回到项目根目录并打印绝对路径，避免相对路径出错
SSH_TARGET="${SERVER_USER}@${SERVER_IP}"

# ---------- 同步时【永远不碰】的清单 ----------
# 这些是"服务器独有的生产状态"，被 --delete 删掉或被本地覆盖都会出事
EXCLUDES=(
  --exclude '.env'          # 生产真实密码。本地那份是开发配置，绝不能覆盖上去
  --exclude '.git/'         # 服务器若是 clone 来的，仓库由 git 自己管理， rsync 别插手
  --exclude 'backups/'      # deploy-prod.sh 生成的数据库备份（含真实数据）
  --exclude '__pycache__/'  # Python 字节码缓存，无意义且频繁变动
  --exclude '*.pyc'
)
# 数组写法，配合 "${EXCLUDES[@]}" 展开时每个元素仍作为独立参数（不会被空格拆开）

# ---------- rsync 参数 ----------
RSYNC_FLAGS=(-rlptvz --delete "${EXCLUDES[@]}")
# -r = recursive 递归子目录
# -l = links 保留符号链接本身（不复制它指向的内容，scp -r 会把软链变成实体文件，语义被改变）
# -p = perms 保留权限位（可执行脚本到了服务器仍然可执行）
# -t = times 保留修改时间（下次同步靠它快速判断变没变）
# -v = verbose 列出每个被处理的文件
# -z = compress 传输时压缩，省带宽
# --delete = 【关键】删除目标端有、源端没有的文件，这才是"同步"而非"复制"
# 不用 -a：因为 -a 里含 -o -g（同步属主/属组），非 root 用户执行会产生权限警告

if [[ "$DRY_RUN" == "1" ]]; then
  RSYNC_FLAGS+=(-n)
  # -n = dry-run 预演模式，只打印将要发生的变更，不真正写入/删除
  echo "🔍 DRY_RUN 模式：只预演，不会改动服务器任何文件"
fi

SYNC_SRC=(
  "${LOCAL_DIR}/api"
  "${LOCAL_DIR}/db"
  "${LOCAL_DIR}/nginx"
  "${LOCAL_DIR}/static"
  "${LOCAL_DIR}/docker"
  "${LOCAL_DIR}/deploy"      # 一起传：服务器上跑 deploy-prod.sh（备份/回滚）需要它
)

echo ">> [1/3] 确认远端目录存在（已存在则跳过）"
ssh "${SSH_TARGET}" "mkdir -p ${REMOTE_DIR}"
# mkdir -p = parents，目录已存在时静默跳过（前提是它已被 chown 给 candyapp，否则这步会失败）

echo ">> [2/3] 同步文件（增 / 改 / 删 三向一致）"
if command -v rsync >/dev/null 2>&1; then
  # command -v = 检查命令是否存在；>/dev/null 2>&1 = 丢掉所有输出，只关心退出码
  rsync "${RSYNC_FLAGS[@]}" "${SYNC_SRC[@]}" "${SSH_TARGET}:${REMOTE_DIR}/"

elif [[ "$DRY_RUN" == "1" ]]; then
  echo "🔍 DRY_RUN：本机无 rsync，跳过上传（rsync 模式下才能安全预演）"

else
  # ============================================================
  #  没有 rsync 时的兜底：【清空重传】
  #  原理：scp 不会删，那就自己先删干净再全量传 —— 效果等同 --delete
  #  代价：有几秒钟目录是空的（Nginx 读 static 会短暂 404），重启在下一步
  # ============================================================
  echo "⚠️ 本机没有 rsync，启用【清空重传】模式（效果等同 --delete）"

  # ① 把服务器上"本地没有、但必须保住"的东西先转移到 /tmp
  STASH="$(ssh "${SSH_TARGET}" "bash -s -- ${REMOTE_DIR}" <<'EOS'
set -eu
cd "$1"                                   # $1 = 传进来的项目根目录
STASH=/tmp/candy-stash-$$                 # $$ = 远端 shell 的 PID，用作临时目录名避免冲突
mkdir -p "$STASH"
[ -f api/.env ]  && cp -p api/.env "$STASH/env" || true   # 生产真实密码，必须保住
[ -d backups ]   && mv backups "$STASH/backups" || true    # 数据库备份，必须保住
rm -rf api db nginx static docker deploy                  # 清空，让本地的全量覆盖
echo "$STASH"                             # 唯一的 stdout 输出：把暂存路径回传给本机
EOS
)"
  # <<'EOS' = heredoc，把脚本内容作为 stdin 喂给 ssh 远端的 bash
  #   单引号包住 EOS = 内容不做本地变量替换（$$ 到远端才展开）
  # bash -s -- 参数 = 从 stdin 读脚本执行，-- 后面的值成为脚本的 $1
  # cp -p = preserve，保留原文件的权限和时间戳

  # ② 全量上传（此时服务器上是空的，所以"残留"问题不存在）
  scp -r "${SYNC_SRC[@]}" "${SSH_TARGET}:${REMOTE_DIR}/"
  # -r = recursive 递归复制整个目录

  # ③ 把保住的东西放回去
  ssh "${SSH_TARGET}" "bash -s -- ${REMOTE_DIR} ${STASH}" <<'EOS'
set -eu
cd "$1"
[ -f "$2/env" ]     && cp -p "$2/env" api/.env || true
[ -d "$2/backups" ] && mv "$2/backups" backups || true
rm -rf "$2"
echo "   已还原 .env 与 backups/"
EOS
fi

# 仅在服务器还没有 .env 时，用示例占位初始化；绝不覆盖已有配置，避免误清生产密码
ssh "${SSH_TARGET}" "cd ${REMOTE_DIR}/api && [ -f .env ] || cp .env.example .env"
# [ -f .env ] = 测试 .env 是否为普通文件；|| = 前面失败（文件不存在）才执行后面的 cp

echo ">> [3/3] 服务器上启动（app×2 负载均衡）"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "🔍 DRY_RUN：跳过启动"
else
  ssh "${SSH_TARGET}" "cd ${REMOTE_DIR} && docker compose -f docker/docker-compose.yml up -d --build --scale app=2"
  # -f      = file 指定 compose 文件路径
  # up      = 创建并启动容器
  # -d      = detached 后台运行
  # --build = 重建镜像（改了 api/ 下的 .py 必须加，否则跑的还是旧代码）
  # --scale app=2 = 起 2 个 app 实例，配合 nginx 的 least_conn 做负载均衡
fi

echo ">> 完成 🎉  浏览器访问 http://${SERVER_IP}/"
