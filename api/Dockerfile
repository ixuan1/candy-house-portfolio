# 糖果屋后端镜像
FROM python:3.11-slim

WORKDIR /app

# 先装依赖，利用层缓存（依赖不变时不必重装）
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 再拷源码
COPY . .

EXPOSE 8000

# 容器健康探活：能访问 /api/health 即视为存活
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/api/health').status==200 else 1)"

# --no-access-log：关掉 uvicorn 自带的请求日志，只留 main.py 里的审计日志，避免重复刷屏
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
