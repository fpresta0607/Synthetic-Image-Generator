import os
from datetime import datetime
from typing import Optional, List, Dict, Any
from sqlalchemy import create_engine, String, Integer, DateTime, ForeignKey, Text
from sqlalchemy.orm import declarative_base, relationship, Session, Mapped, mapped_column

_DB_URL = os.environ.get('DATABASE_URL', 'sqlite:///data/app.db')
_ENGINE = create_engine(_DB_URL, echo=False, future=True)
Base = declarative_base()

class Dataset(Base):
    __tablename__ = 'datasets'
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    images: Mapped[List['Image']] = relationship('Image', back_populates='dataset', cascade='all, delete-orphan')
    templates: Mapped[List['Template']] = relationship('Template', back_populates='dataset', cascade='all, delete-orphan')

class Image(Base):
    __tablename__ = 'images'
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    dataset_id: Mapped[str] = mapped_column(String(64), ForeignKey('datasets.id', ondelete='CASCADE'), index=True)
    filename: Mapped[str] = mapped_column(String(255))
    path: Mapped[str] = mapped_column(Text)
    width: Mapped[int] = mapped_column(Integer)
    height: Mapped[int] = mapped_column(Integer)
    thumb_b64: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    dataset: Mapped[Dataset] = relationship('Dataset', back_populates='images')

class Template(Base):
    __tablename__ = 'templates'
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    dataset_id: Mapped[str] = mapped_column(String(64), ForeignKey('datasets.id', ondelete='CASCADE'), index=True)
    name: Mapped[str] = mapped_column(String(255))
    klass: Mapped[Optional[str]] = mapped_column('class', String(32), nullable=True)
    points_json: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    dataset: Mapped[Dataset] = relationship('Dataset', back_populates='templates')

# ------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------

def init_db():
    Base.metadata.create_all(_ENGINE)

# ------------------------------------------------------------------
# CRUD Helpers (minimal)
# ------------------------------------------------------------------

def create_dataset(ds_id: str, images: List[Dict[str, Any]]):
    with Session(_ENGINE) as s:
        ds = Dataset(id=ds_id)
        for im in images:
            s.add(Image(id=im['id'], dataset_id=ds_id, filename=im['filename'], path=im['path'], width=im.get('w',0), height=im.get('h',0), thumb_b64=im.get('thumb_b64')))
        s.add(ds)
        s.commit()

def store_template(dataset_id: str, tpl_id: str, name: str, klass: str, points_json: str):
    with Session(_ENGINE) as s:
        t = Template(id=tpl_id, dataset_id=dataset_id, name=name, klass=klass or None, points_json=points_json)
        s.add(t)
        s.commit()

def list_templates(dataset_id: str) -> List[Dict[str, Any]]:
    with Session(_ENGINE) as s:
        rows = s.query(Template).filter(Template.dataset_id==dataset_id).all()
        return [ {'id':r.id,'name':r.name,'class':r.klass or '', 'points_json': r.points_json} for r in rows ]

def load_dataset(dataset_id: str) -> Optional[Dict[str, Any]]:
    with Session(_ENGINE) as s:
        ds = s.get(Dataset, dataset_id)
        if not ds:
            return None
        images = s.query(Image).filter(Image.dataset_id==dataset_id).all()
        return {
            'dataset_id': dataset_id,
            'images': [ {'id':im.id,'filename':im.filename,'path':im.path,'w':im.width,'h':im.height,'thumb_b64':im.thumb_b64} for im in images ]
        }

def load_templates(dataset_id: str) -> Dict[str, Dict[str, Any]]:
    with Session(_ENGINE) as s:
        rows = s.query(Template).filter(Template.dataset_id==dataset_id).all()
        out = {}
        import json
        for r in rows:
            try:
                pts = json.loads(r.points_json)
            except Exception:
                pts = []
            out[r.id] = {'id': r.id, 'name': r.name, 'class': r.klass or '', 'points': pts, 'created_at': r.created_at.timestamp()}
        return out
