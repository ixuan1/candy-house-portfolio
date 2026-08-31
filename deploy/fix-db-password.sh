#!/usr/bin/env bash
# ============================================================
#  糖果屋 · 修复「app 连不上 MySQL（1045 Access denied）」
#
#  问题根因（务必先看懂，否则还会再踩）：
#    MySQL 官方镜像的 MYSQL_USER / MYSQL_PASSWORD / MYSQL_DATABASE
#    这三项【只在数据卷为空、首次初始化时执行一次】。
#    之后你改了 api/.env 里的密码再 docker compose up -d，
#    MySQL 里那个 candy 用户的密码【不会跟着变】 → app 报 1045。
#
#    而且 db 的 healthcheck 用的是 root 密码探活，
#    所以 docker compose ps 里 db 显示 healthy，app 却在疯狂重启 —— 假绿灯。
#
#  本脚本做什么（幂等，可重复执行）：
#    读 api/.env 的密码 → 用 root 进 MySQL →
#    确保用户 candy@'%' 存在、且密码 = .env 里的 MYSQL_PASSWORD、
#    并对 candy_house 库有全部权限 → 最后用新密码实连一次验证。
#
#  什么时候跑：
#    ✅ 改过 api/.env 里 MYSQL_PASSWORD 之后（必跑一次）
#    ✅ 出现 (1045, "Access denied for user 'candy'") 时
#    ✅ 首次部署想确保账号一定存在
#
#  🟢 candyapp 会话执行（不需要 sudo）
# ============================================================

set -euo pipefail
# set -e = 任一命令失败就退出；-u = 用了未定义变量就报错；
# -o pipefail = 管道里任一环失败都算失败（默认只看最后一环）

echo "=========================================="
echo " 糖果屋 · MySQL 账号密码同步工具"
echo "=========================================="

# ---------- 定位项目根目录（脚本在 deploy/，上一级就是根）----------
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# $(...)  = 命令替换，把括号里命令的输出当字符串用
# dirname "$0" = 取脚本所在目录；cd .. 再 pwd = 拿到项目根目录绝对路径

cd "${PROJECT_ROOT}"
echo "项目根目录: ${PROJECT_ROOT}"
echo ""

ENV_FILE="api/.env"
COMPOSE_FILE="docker/docker-compose.yml"

# ---------- 前置检查 ----------
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "❌ 找不到 ${ENV_FILE}"
  echo "   先执行：cp api/.env.example api/.env  然后填入真实密码"
  exit 1
  # exit 1 = 非零退出码，表示失败（shell 约定：0=成功，非0=失败）
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "❌ 找不到 ${COMPOSE_FILE}（你是不是在错误的目录？）"
  exit 1
fi

# ---------- 从 .env 读取配置 ----------
get_env() {
  # 作用：从 .env 里取出指定变量的值
  grep -E "^${1}=" "${ENV_FILE}" \
    | tail -n 1 \
    | sed -e "s/^${1}=//" \
          -e 's/^[[:space:]]*//' \
          -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' \
          -e "s/^'\(.*\)'\$/\1/"
  # grep -E "^KEY="  = 正则匹配以 KEY= 开头的行
  # tail -n 1        = 取最后一行（万一重复定义，以最后的为准）
  # sed 's/^KEY=//'  = 删掉 "KEY=" 前缀
  # 's/^[[:space:]]*//' = 删掉开头空白
  # 's/[[:space:]]*$//' = 删掉结尾空白
  # 's/^"\(.*\)"$/\1/'  = 若被双引号包住，去掉外层双引号
}

MYSQL_USER="$(get_env MYSQL_USER)"
MYSQL_PASSWORD="$(get_env MYSQL_PASSWORD)"
MYSQL_ROOT_PASSWORD="$(get_env MYSQL_ROOT_PASSWORD)"
MYSQL_DATABASE="$(get_env MYSQL_DATABASE)"

# ---------- 校验关键变量非空 ----------
for pair in "MYSQL_USER:${MYSQL_USER}" \
            "MYSQL_PASSWORD:${MYSQL_PASSWORD}" \
            "MYSQL_ROOT_PASSWORD:${MYSQL_ROOT_PASSWORD}" \
            "MYSQL_DATABASE:${MYSQL_DATABASE}"; do
  key="${pair%%:*}"
  # ${var%%:*} = 从右边贪婪删除 ":内容"，只留下冒号前的 key
  val="${pair#*:}"
  # ${var#*:}  = 从左边非贪婪删除 "key:"，只留下冒号后的 value
  if [[ -z "${val}" ]]; then
    echo "❌ ${ENV_FILE} 里 ${key} 是空的，先填好再跑"
    exit 1
  fi
done

# ---------- 密码字符安全检查 ----------
# 这些字符会破坏两处：① DATABASE_URL 连接串 ② 本脚本拼的 SQL 语句
if [[ "${MYSQL_PASSWORD}" == *"@"* ]]; then
  echo "❌ MYSQL_PASSWORD 里含 @ 号"
  echo "   @ 会截断 DATABASE_URL（mysql://candy:pa@ss@db:3306/... 会被解析错）"
  echo "   请改成纯字母+数字+下划线，改完同步修改 DATABASE_URL 里的密码"
  exit 1
fi

if [[ "${MYSQL_PASSWORD}" == *"'"* || "${MYSQL_PASSWORD}" == *'"'* || "${MYSQL_PASSWORD}" == *"\\"* ]]; then
  echo "❌ MYSQL_PASSWORD 里含引号或反斜杠"
  echo "   这些字符会破坏 SQL 语句拼接，请改用纯字母+数字+下划线"
  exit 1
fi

echo "配置读取完成："
echo "  MYSQL_USER      = ${MYSQL_USER}"
echo "  MYSQL_DATABASE  = ${MYSQL_DATABASE}"
echo "  MYSQL_PASSWORD  = ${MYSQL_PASSWORD:0:2}******（长度 ${#MYSQL_PASSWORD}）"
# ${var:0:2} = 取前 2 个字符（只露一点，不打印完整密码）
# ${#var}    = 取字符串长度
echo ""

# ---------- 确认 db 容器在跑 ----------
echo ">> [1/4] 检查 db 容器状态"
if ! docker compose -f "${COMPOSE_FILE}" ps db | grep -q "Up\|running"; then
  # grep -q = quiet 静默模式，只靠退出码表示找没找到，不打印内容
  echo "❌ db 容器没在跑，先启动它："
  echo "   docker compose -f ${COMPOSE_FILE} up -d db"
  exit 1
fi
echo "   ✅ db 容器在运行"
echo ""

# ---------- 拼接并执行 SQL ----------
# 两条一起写，无论用户存不存在都能把密码设成目标值（幂等）：
#   CREATE USER IF NOT EXISTS = 用户不存在才建（MySQL 8.0+ 支持 IF NOT EXISTS）
#   ALTER USER                = 无论新建还是已存在，都把密码改成 .env 里的值
#   GRANT ALL                 = 授予对该库的全部权限
#   FLUSH PRIVILEGES          = 重新加载权限表，让改动立刻生效
SQL="CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;"

echo ">> [2/4] 以 root 身份写入账号与授权"
docker compose -f "${COMPOSE_FILE}" exec -T db \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "${SQL}"
# exec           = 在已运行的容器里执行命令
# -T             = 不分配伪终端（脚本里必须加，否则报 the input device is not a TTY）
# db             = compose 里的服务名
# mysql -uroot   = -u 指定用户名 root（注意 -u 和名字之间无空格）
# -p"密码"       = -p 指定密码（同样无空格；有空格会被当成库名）
# -e "SQL"       = execute，执行引号里的 SQL 语句后退出
echo "   ✅ 账号与授权已写入"
echo ""

# ---------- 用新密码实连验证 ----------
echo ">> [3/4] 用新密码实连验证（这才是真正的健康检查）"
if docker compose -f "${COMPOSE_FILE}" exec -T db \
     mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
     -e "SELECT '连接成功' AS result;" "${MYSQL_DATABASE}" >/dev/null 2>&1; then
  # >/dev/null 2>&1 = 标准输出和错误都丢进黑洞，只看退出码
  echo "   ✅ 用 ${MYSQL_USER} 的新密码连库成功"
else
  echo "   ❌ 连库仍然失败。可能原因："
  echo "      1) MYSQL_ROOT_PASSWORD 不对（root 都进不去，SQL 没执行成功）"
  echo "      2) 上方 [2/4] 步骤的报错被忽略了，往上翻看具体错误"
  exit 1
fi
echo ""

# ---------- 提示重启 app ----------
echo ">> [4/4] 让 app 用新密码重连"
echo "   账号已就绪，现在重启 app 容器（不必重建镜像，密码是启动时读 .env 的）："
echo ""
echo "   docker compose -f ${COMPOSE_FILE} up -d --force-recreate app"
# --force-recreate = 强制重建容器（即使配置没变）
#                    改了 .env 必须加这个，否则 Compose 认为没变化、不重建，
#                    容器里还是旧的 DATABASE_URL 环境变量
echo ""
echo "=========================================="
echo " 完成。紧跟一句验证："
echo "   curl -s http://127.0.0.1:8000/api/health"
echo "   期望返回 {\"status\":\"ok\",\"db\":true,...}"
echo "=========================================="
