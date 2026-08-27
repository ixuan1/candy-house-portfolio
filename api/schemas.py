"""Pydantic 模型：负责 API 的“进出”数据校验与序列化。"""
from datetime import datetime
from pydantic import BaseModel, ConfigDict


class WorkBase(BaseModel):
    title: str
    category: str = "Web"
    color: str = "#FF1493"
    description: str = ""
    link: str = ""


class WorkCreate(WorkBase):
    """创建时需要的字段。"""


class WorkUpdate(BaseModel):
    """更新时全部可选（只传要改的字段）。"""
    title: str | None = None
    category: str | None = None
    color: str | None = None
    description: str | None = None
    link: str | None = None


class WorkOut(WorkBase):
    """返回给前端的结构（含数据库自生成字段）。"""
    model_config = ConfigDict(from_attributes=True)
    id: int
    created_at: datetime
    updated_at: datetime
