# 糖果屋后端镜像
FROM python:3.11-slim

WORKDIR /app

# 先装依赖，利用层缓存（依赖不变时不必重装）
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 再拷源码
COPY . .

EXPOSE 8000

# 容器时区设为北京时间。
# 不设会怎样：基础镜像默认 UTC → 容器"本地时间"就是 UTC → logging 的
# %(asctime)s 取 time.localtime()，写出来的日志时间戳比北京时间【慢 8 小时】，
# 和宿主机 Nginx 访问日志（北京时间）永远对不上，线上回溯时会拼错时间线。
# 为什么一行 ENV 就够：python:3.11-slim 的 runtime 依赖里已包含 tzdata
# （/usr/share/zoneinfo 存在），TZ 变量能直接生效，不必再 apt install tzdata。
# 为什么放在这里而不是开头：ENV 会让【它之后的所有层】缓存失效，
# 放到 pip install 之后，改时区不会导致依赖重装，重建更快。
ENV TZ=Asia/Shanghai

# 容器健康探活：能访问 /api/health 即视为存活
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/api/health').status==200 else 1)"

# --no-access-log：关掉 uvicorn 自带的请求日志，只留 main.py 里的审计日志，避免重复刷屏
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
