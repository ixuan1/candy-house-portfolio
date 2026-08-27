"""SQLAlchemy 模型：对应数据库表 works。"""
from datetime import datetime
from sqlalchemy import Column, Integer, String, Text, DateTime, func
from database import Base


class Work(Base):
    __tablename__ = "works"

    id = Column(Integer, primary_key=True, autoincrement=True)
    title = Column(String(120), nullable=False)          # 作品名称
    category = Column(String(60), default="Web")         # 分类：Web/UI/Canvas...
    color = Column(String(20), default="#FF1493")        # 糖果色（HEX）
    description = Column(Text, default="")                # 描述
    link = Column(String(255), default="")               # 外链
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())
