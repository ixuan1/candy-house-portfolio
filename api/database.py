"""数据库连接层：SQLAlchemy 引擎 + 会话。
链接串从环境变量 DATABASE_URL 读取（Docker 内用 db:3306，本地裸跑用 localhost:3306）。
"""
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, DeclarativeBase

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "mysql+pymysql://candy:change_me_strong@db:3306/candy_house",
)

# pool_pre_ping=True 会在每次取连接前先 ping 一下，自动踢掉断开的死连接（运维常见坑）
engine = create_engine(DATABASE_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


class Base(DeclarativeBase):
    pass


def get_db():
    """FastAPI 依赖：每个请求一个会话，用完即关。"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
