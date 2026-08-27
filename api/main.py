"""糖果屋 API 入口（FastAPI）。
提供作品(works)的增删改查 + 健康检查。
调试利器：访问 /docs 自动得到 Swagger 交互式文档。

日志：每个 CRUD 操作都会写结构化审计日志（新增/修改/删除的具体内容、真实访客 IP、
耗时、请求 ID），`docker compose logs -f app` 即可看清「谁改了什么」。
"""
import logging
import sys
import time
import uuid

from fastapi import FastAPI, Depends, HTTPException, status, Request
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select, func
from sqlalchemy.orm import Session

from database import engine, Base, get_db
import models
import schemas

# ---------- 审计日志 logger（统一输出到 stdout，被 docker logs 捕获）----------
logger = logging.getLogger("candy")
if not logger.handlers:
    _h = logging.StreamHandler(sys.stdout)
    _h.setFormatter(
        logging.Formatter(
            "%(asctime)s | %(levelname)s | %(message)s",
            "%Y-%m-%d %H:%M:%S",
        )
    )
    logger.addHandler(_h)
    logger.setLevel(logging.INFO)
logger.propagate = False  # 不重复交给 root / uvicorn


def client_ip(request: Request) -> str:
    """取真实访客 IP：优先 X-Forwarded-For（Nginx 已传），否则 X-Real-IP，最后回退直连 IP。"""
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
    real = request.headers.get("x-real-ip")
    if real:
        return real.strip()
    return request.client.host if request.client else "unknown"


# 兜底建表：即使 init.sql 没跑，也能自动建好表（开发期友好）
Base.metadata.create_all(bind=engine)

app = FastAPI(title="糖果屋 API", version="1.0.0")

# CORS：同源经 Nginx 时其实不需要，但本地调试跨端口时方便。
# 生产环境请把 allow_origins 改成因你的真实域名，例如 ["https://candy.example.com"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def audit_log(request: Request, call_next):
    """请求级审计：记录方法 / 路径 / 真实 IP / 耗时 / 状态码；连同 req_id 串起进出两行。
    健康检查 /api/health 探活过于频繁，跳过以免刷屏。"""
    if request.url.path == "/api/health":
        return await call_next(request)

    req_id = uuid.uuid4().hex[:8]
    start = time.perf_counter()
    ip = client_ip(request)
    logger.info(f"→ {request.method} {request.url.path} | ip={ip} | req_id={req_id}")
    try:
        response = await call_next(request)
    except Exception:
        ms = (time.perf_counter() - start) * 1000
        logger.exception(
            f"✗ {request.method} {request.url.path} | req_id={req_id} | ERROR | {ms:.1f}ms"
        )
        raise
    ms = (time.perf_counter() - start) * 1000
    logger.info(
        f"← {request.method} {request.url.path} | status={response.status_code} | {ms:.1f}ms | req_id={req_id}"
    )
    return response


@app.get("/api/health")
def health(db: Session = Depends(get_db)):
    """健康检查：调试面板和负载均衡探活都会打这个接口。"""
    try:
        db.execute(select(func.now())).scalar()
        db_ok = True
    except Exception:
        db_ok = False
    return {
        "status": "ok" if db_ok else "degraded",
        "db": db_ok,
        "service": "candy-house-api",
    }


@app.get("/api/works", response_model=list[schemas.WorkOut])
def list_works(q: str | None = None, db: Session = Depends(get_db)):
    """列出作品，支持按标题模糊搜索。"""
    stmt = select(models.Work)
    if q:
        stmt = stmt.where(models.Work.title.contains(q))
    result = db.scalars(stmt.order_by(models.Work.id.desc())).all()
    logger.info(f"LIST works | q={q!r} | count={len(result)}")
    return result


@app.get("/api/works/{work_id}", response_model=schemas.WorkOut)
def get_work(work_id: int, db: Session = Depends(get_db)):
    w = db.get(models.Work, work_id)
    logger.info(f"GET work | id={work_id} | found={'yes' if w else 'no'}")
    if not w:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "作品不存在")
    return w


@app.post("/api/works", response_model=schemas.WorkOut, status_code=status.HTTP_201_CREATED)
def create_work(payload: schemas.WorkCreate, db: Session = Depends(get_db)):
    """新增作品。"""
    w = models.Work(**payload.model_dump())
    db.add(w)
    db.commit()
    db.refresh(w)
    logger.info(
        f"CREATE work | id={w.id} | title={w.title!r} | category={w.category} | "
        f"color={w.color} | link={w.link!r}"
    )
    logger.info(f"           description={w.description!r}")
    return w


@app.put("/api/works/{work_id}", response_model=schemas.WorkOut)
def update_work(work_id: int, payload: schemas.WorkUpdate, db: Session = Depends(get_db)):
    """更新作品（只改传来的字段）。"""
    w = db.get(models.Work, work_id)
    if not w:
        logger.warning(f"UPDATE work | id={work_id} | NOT FOUND")
        raise HTTPException(status.HTTP_404_NOT_FOUND, "作品不存在")
    # 先记录旧值，再覆盖，最后打印「旧 -> 新」
    changes = {}
    for k, v in payload.model_dump(exclude_unset=True).items():
        old = getattr(w, k)
        changes[k] = (old, v)
        setattr(w, k, v)
    db.commit()
    db.refresh(w)
    chg = ", ".join(f"{k}: {old!r} -> {new!r}" for k, (old, new) in changes.items())
    logger.info(f"UPDATE work | id={work_id} | {chg}")
    return w


@app.delete("/api/works/{work_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_work(work_id: int, db: Session = Depends(get_db)):
    """删除作品。"""
    w = db.get(models.Work, work_id)
    if not w:
        logger.warning(f"DELETE work | id={work_id} | NOT FOUND")
        raise HTTPException(status.HTTP_404_NOT_FOUND, "作品不存在")
    # 先记后删：万一删除失败也有据可查
    logger.warning(f"DELETE work | id={work_id} | title={w.title!r} | category={w.category}")
    db.delete(w)
    db.commit()
