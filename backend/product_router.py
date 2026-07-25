import os
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, UploadFile, File
from pydantic import BaseModel
from sqlalchemy.orm import Session
from PIL import Image

from database import get_db
from dependencies import get_current_user, require_admin, require_permission
import models
import schemas


class _ReorderItem(BaseModel):
    id: int
    sort_order: int

router = APIRouter()

UPLOAD_DIR = Path(__file__).parent / "static" / "images"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

MAX_IMAGE_SIZE = (800, 800)
IMAGE_QUALITY = 85


# ── Categories ────────────────────────────────────────────────────────────────

@router.get("/categories", response_model=list[schemas.CategoryResponse])
def list_categories(db: Session = Depends(get_db), _=Depends(get_current_user)):
    return db.query(models.Category).order_by(models.Category.sort_order, models.Category.id).all()


@router.post("/categories", response_model=schemas.CategoryResponse, status_code=201)
def create_category(
    data: schemas.CategoryCreate,
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_catalog")),
):
    if db.query(models.Category).filter(models.Category.name == data.name).first():
        raise HTTPException(status_code=400, detail="Category name already exists")
    cat = models.Category(name=data.name, sort_order=data.sort_order)
    db.add(cat)
    db.commit()
    db.refresh(cat)
    return cat


@router.post("/categories/reorder", status_code=204)
def reorder_categories(
    items: list[_ReorderItem],
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_catalog")),
):
    for item in items:
        cat = db.query(models.Category).filter(models.Category.id == item.id).first()
        if cat:
            cat.sort_order = item.sort_order
    db.commit()


@router.put("/categories/{category_id}", response_model=schemas.CategoryResponse)
def update_category(
    category_id: int,
    data: schemas.CategoryUpdate,
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_catalog")),
):
    cat = db.query(models.Category).filter(models.Category.id == category_id).first()
    if not cat:
        raise HTTPException(status_code=404, detail="Category not found")
    if data.name is not None:
        existing = db.query(models.Category).filter(
            models.Category.name == data.name, models.Category.id != category_id
        ).first()
        if existing:
            raise HTTPException(status_code=400, detail="Category name already exists")
        cat.name = data.name
    if data.sort_order is not None:
        cat.sort_order = data.sort_order
    if data.is_active is not None:
        cat.is_active = data.is_active
    db.commit()
    db.refresh(cat)
    return cat


@router.delete("/categories/{category_id}", status_code=204)
def delete_category(
    category_id: int,
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_catalog")),
):
    cat = db.query(models.Category).filter(models.Category.id == category_id).first()
    if not cat:
        raise HTTPException(status_code=404, detail="Category not found")
    has_products = db.query(models.Product).filter(
        models.Product.category_id == category_id,
        models.Product.is_deleted == False,
    ).first()
    if has_products:
        raise HTTPException(status_code=400, detail="Cannot delete category with active products")
    db.delete(cat)
    db.commit()


# ── Products ──────────────────────────────────────────────────────────────────

@router.get("/products", response_model=list[schemas.ProductResponse])
def list_products(
    category_id: int | None = None,
    status: str | None = None,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    q = db.query(models.Product).filter(models.Product.is_deleted == False)
    if category_id is not None:
        q = q.filter(models.Product.category_id == category_id)
    if status is not None:
        q = q.filter(models.Product.status == status)
    return q.order_by(models.Product.sort_order, models.Product.id).all()


@router.post("/products", response_model=schemas.ProductResponse, status_code=201)
def create_product(
    data: schemas.ProductCreate,
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_catalog")),
):
    if data.category_id is not None:
        if not db.query(models.Category).filter(models.Category.id == data.category_id).first():
            raise HTTPException(status_code=400, detail="Category not found")
    if data.status not in ("active", "inactive"):
        raise HTTPException(status_code=400, detail="status must be 'active' or 'inactive'")
    product = models.Product(**data.model_dump())
    db.add(product)
    db.commit()
    db.refresh(product)
    return product


@router.post("/products/reorder", status_code=204)
def reorder_products(
    items: list[_ReorderItem],
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_catalog")),
):
    for item in items:
        p = db.query(models.Product).filter(
            models.Product.id == item.id, models.Product.is_deleted == False
        ).first()
        if p:
            p.sort_order = item.sort_order
    db.commit()


@router.get("/products/{product_id}", response_model=schemas.ProductResponse)
def get_product(product_id: int, db: Session = Depends(get_db), _=Depends(get_current_user)):
    product = db.query(models.Product).filter(
        models.Product.id == product_id, models.Product.is_deleted == False
    ).first()
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")
    return product


@router.put("/products/{product_id}", response_model=schemas.ProductResponse)
def update_product(
    product_id: int,
    data: schemas.ProductUpdate,
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_catalog")),
):
    product = db.query(models.Product).filter(
        models.Product.id == product_id, models.Product.is_deleted == False
    ).first()
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")
    if data.category_id is not None:
        if not db.query(models.Category).filter(models.Category.id == data.category_id).first():
            raise HTTPException(status_code=400, detail="Category not found")
        product.category_id = data.category_id
    if data.name is not None:
        product.name = data.name
    if data.description is not None:
        product.description = data.description
    if data.price is not None:
        product.price = data.price
    if data.status is not None:
        if data.status not in ("active", "inactive"):
            raise HTTPException(status_code=400, detail="status must be 'active' or 'inactive'")
        product.status = data.status
    if data.sort_order is not None:
        product.sort_order = data.sort_order
    if data.sold_by_weight is not None:
        product.sold_by_weight = data.sold_by_weight
    db.commit()
    db.refresh(product)
    return product


@router.delete("/products/{product_id}", status_code=204)
def delete_product(
    product_id: int,
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_catalog")),
):
    product = db.query(models.Product).filter(
        models.Product.id == product_id, models.Product.is_deleted == False
    ).first()
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")
    product.is_deleted = True  # 软删除
    db.commit()


@router.post("/products/{product_id}/image", response_model=schemas.ProductResponse)
def upload_product_image(
    product_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_catalog")),
):
    product = db.query(models.Product).filter(
        models.Product.id == product_id, models.Product.is_deleted == False
    ).first()
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")

    if file.content_type not in ("image/jpeg", "image/png", "image/webp"):
        raise HTTPException(status_code=400, detail="Only JPEG, PNG, or WebP images are accepted")

    # 删掉旧图片
    if product.image_path:
        old_file = UPLOAD_DIR / Path(product.image_path).name
        old_file.unlink(missing_ok=True)

    # 压缩 & 存储
    ext = ".jpg"
    filename = f"{uuid.uuid4().hex}{ext}"
    dest = UPLOAD_DIR / filename

    img = Image.open(file.file)
    img = img.convert("RGB")
    img.thumbnail(MAX_IMAGE_SIZE, Image.LANCZOS)
    img.save(dest, format="JPEG", quality=IMAGE_QUALITY, optimize=True)

    product.image_path = f"static/images/{filename}"
    db.commit()
    db.refresh(product)
    return product
