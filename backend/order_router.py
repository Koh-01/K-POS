from uuid import uuid4
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user, require_admin
from time_utils import local_now
import models
import schemas

router = APIRouter()


def _generate_order_number(db: Session) -> str:
    # Timestamp + random suffix avoids duplicate numbers when multiple POS
    # devices create an order in the same transaction window.
    now = local_now()
    return f"ORD-{now:%Y%m%d-%H%M%S}-{uuid4().hex[:6].upper()}"


def _set_table_status(db: Session, table_id: int | None, status: str):
    if table_id is None:
        return
    table = db.query(models.Table).filter(models.Table.id == table_id).first()
    if table:
        table.status = status


def _validated_weight(product: models.Product, weight_kg):
    """Keep item pricing mode consistent with the product catalogue."""
    if product.sold_by_weight:
        if weight_kg is None or weight_kg <= 0:
            raise HTTPException(
                status_code=400,
                detail=f"Product {product.id} requires a positive weight_kg",
            )
        return weight_kg
    if weight_kg is not None:
        raise HTTPException(
            status_code=400,
            detail=f"Product {product.id} is sold by quantity, not weight",
        )
    return None


# ── Tables ────────────────────────────────────────────────────────────────────

@router.get("/tables", response_model=list[schemas.TableResponse])
def list_tables(db: Session = Depends(get_db), _=Depends(get_current_user)):
    return (
        db.query(models.Table)
        .order_by(models.Table.sort_order, models.Table.id)
        .all()
    )


@router.post("/tables", response_model=schemas.TableResponse, status_code=201)
def create_table(data: schemas.TableCreate, db: Session = Depends(get_db), _=Depends(require_admin)):
    if db.query(models.Table).filter(models.Table.name == data.name).first():
        raise HTTPException(status_code=400, detail="Table name already exists")
    table = models.Table(name=data.name, capacity=data.capacity, sort_order=data.sort_order)
    db.add(table)
    db.commit()
    db.refresh(table)
    return table


@router.put("/tables/{table_id}", response_model=schemas.TableResponse)
def update_table(
    table_id: int,
    data: schemas.TableUpdate,
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    table = db.query(models.Table).filter(models.Table.id == table_id).first()
    if not table:
        raise HTTPException(status_code=404, detail="Table not found")
    if data.name is not None:
        dup = db.query(models.Table).filter(
            models.Table.name == data.name, models.Table.id != table_id
        ).first()
        if dup:
            raise HTTPException(status_code=400, detail="Table name already exists")
        table.name = data.name
    if data.capacity is not None:
        table.capacity = data.capacity
    if data.sort_order is not None:
        table.sort_order = data.sort_order
    if data.is_active is not None:
        table.is_active = data.is_active
    db.commit()
    db.refresh(table)
    return table


@router.delete("/tables/{table_id}", status_code=204)
def delete_table(table_id: int, db: Session = Depends(get_db), _=Depends(require_admin)):
    table = db.query(models.Table).filter(models.Table.id == table_id).first()
    if not table:
        raise HTTPException(status_code=404, detail="Table not found")
    has_open = db.query(models.Order).filter(
        models.Order.table_id == table_id,
        models.Order.status == "open",
        models.Order.is_deleted == False,
    ).first()
    if has_open:
        raise HTTPException(status_code=400, detail="Cannot delete table with open orders")
    db.delete(table)
    db.commit()


# ── Orders ────────────────────────────────────────────────────────────────────

@router.get("/orders", response_model=list[schemas.OrderResponse])
def list_orders(
    status: str | None = None,
    table_id: int | None = None,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    q = db.query(models.Order).filter(models.Order.is_deleted == False)
    if status:
        q = q.filter(models.Order.status == status)
    if table_id is not None:
        q = q.filter(models.Order.table_id == table_id)
    return q.order_by(models.Order.id.desc()).all()


@router.post("/orders", response_model=schemas.OrderResponse, status_code=201)
def create_order(
    data: schemas.OrderCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if data.order_type not in ("dine_in", "take_away"):
        raise HTTPException(status_code=400, detail="order_type must be 'dine_in' or 'take_away'")

    if data.offline_ref:
        existing = db.query(models.Order).filter(
            models.Order.offline_ref == data.offline_ref,
            models.Order.is_deleted == False,
        ).first()
        if existing:
            return existing

    if data.order_type == "dine_in" and data.table_id is not None:
        table = db.query(models.Table).filter(
            models.Table.id == data.table_id, models.Table.is_active == True
        ).with_for_update().first()
        if not table:
            raise HTTPException(status_code=404, detail="Table not found or inactive")
        if table.status == "occupied":
            raise HTTPException(status_code=400, detail="Table is already occupied")

    order = models.Order(
        order_number=_generate_order_number(db),
        table_id=data.table_id,
        table_name=data.table_name,
        order_type=data.order_type,
        notes=data.notes,
        created_by=current_user.id,
        offline_ref=data.offline_ref,
    )
    db.add(order)
    db.flush()  # 拿到 order.id

    for item_data in data.items:
        product = db.query(models.Product).filter(
            models.Product.id == item_data.product_id,
            models.Product.is_deleted == False,
            models.Product.status == "active",
        ).first()
        if not product:
            db.rollback()
            raise HTTPException(status_code=400, detail=f"Product {item_data.product_id} not found or inactive")
        db.add(models.OrderItem(
            order_id=order.id,
            product_id=product.id,
            quantity=item_data.quantity,
            unit_price=product.price,
            weight_kg=_validated_weight(product, item_data.weight_kg),
            notes=item_data.notes,
        ))

    if data.order_type == "dine_in" and data.table_id:
        _set_table_status(db, data.table_id, "occupied")

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if data.offline_ref:
            existing = db.query(models.Order).filter(
                models.Order.offline_ref == data.offline_ref,
            ).first()
            if existing:
                return existing
        raise HTTPException(status_code=409, detail="Order already exists")
    db.refresh(order)
    return order


@router.get("/orders/{order_id}", response_model=schemas.OrderResponse)
def get_order(order_id: int, db: Session = Depends(get_db), _=Depends(get_current_user)):
    order = db.query(models.Order).filter(
        models.Order.id == order_id, models.Order.is_deleted == False
    ).first()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    return order


@router.put("/orders/{order_id}", response_model=schemas.OrderResponse)
def update_order(
    order_id: int,
    data: schemas.OrderUpdate,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    order = db.query(models.Order).filter(
        models.Order.id == order_id,
        models.Order.is_deleted == False,
        models.Order.status == "open",
    ).with_for_update().first()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found or not open")
    if data.notes is not None:
        order.notes = data.notes
    if data.order_type is not None:
        if data.order_type not in ("dine_in", "take_away"):
            raise HTTPException(status_code=400, detail="order_type must be 'dine_in' or 'take_away'")
        order.order_type = data.order_type

    if "table_id" in data.model_fields_set:
        new_table = None
        if data.table_id is not None:
            new_table = db.query(models.Table).filter(
                models.Table.id == data.table_id,
                models.Table.is_active == True,
            ).with_for_update().first()
            if not new_table:
                raise HTTPException(status_code=404, detail="Table not found or inactive")
            if new_table.status == "occupied" and data.table_id != order.table_id:
                raise HTTPException(status_code=409, detail="Table is already occupied")
        if order.table_id != data.table_id:
            _set_table_status(db, order.table_id, "available")
            if new_table:
                new_table.status = "occupied"
            order.table_id = data.table_id
    if "table_name" in data.model_fields_set:
        order.table_name = data.table_name

    if order.order_type == "take_away" and order.table_id is not None:
        _set_table_status(db, order.table_id, "available")
        order.table_id = None

    if data.items is not None:
        products: dict[int, models.Product] = {}
        for item_data in data.items:
            product = db.query(models.Product).filter(
                models.Product.id == item_data.product_id,
                models.Product.is_deleted == False,
                models.Product.status == "active",
            ).first()
            if not product:
                raise HTTPException(status_code=400, detail=f"Product {item_data.product_id} not found or inactive")
            products[item_data.product_id] = product
        db.query(models.OrderItem).filter(models.OrderItem.order_id == order.id).delete()
        for item_data in data.items:
            product = products[item_data.product_id]
            db.add(models.OrderItem(
                order_id=order.id,
                product_id=product.id,
                quantity=item_data.quantity,
                unit_price=product.price,
                weight_kg=_validated_weight(product, item_data.weight_kg),
                notes=item_data.notes,
            ))

    db.commit()
    db.refresh(order)
    return order


@router.delete("/orders/{order_id}", status_code=204)
def delete_order(
    order_id: int,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    order = db.query(models.Order).filter(
        models.Order.id == order_id, models.Order.is_deleted == False
    ).with_for_update().first()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    if order.status == "paid":
        raise HTTPException(status_code=400, detail="Paid orders cannot be deleted here. Use the payment module.")
    order.is_deleted = True
    if order.status == "open":
        _set_table_status(db, order.table_id, "available")
    db.commit()


# ── Change Table ──────────────────────────────────────────────────────────────

@router.post("/orders/{order_id}/change-table", response_model=schemas.OrderResponse)
def change_table(
    order_id: int,
    body: dict,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    new_table_id: int = body.get("table_id")
    if new_table_id is None:
        raise HTTPException(status_code=400, detail="table_id is required")

    order = db.query(models.Order).filter(
        models.Order.id == order_id,
        models.Order.is_deleted == False,
        models.Order.status == "open",
    ).with_for_update().first()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found or not open")

    new_table = db.query(models.Table).filter(
        models.Table.id == new_table_id, models.Table.is_active == True
    ).with_for_update().first()
    if not new_table:
        raise HTTPException(status_code=404, detail="Target table not found or inactive")
    if new_table.status == "occupied" and new_table_id != order.table_id:
        raise HTTPException(status_code=400, detail="Target table is already occupied")

    old_table_id = order.table_id
    order.table_id = new_table_id
    _set_table_status(db, old_table_id, "available")
    _set_table_status(db, new_table_id, "occupied")
    db.commit()
    db.refresh(order)
    return order


# ── Combine Orders ────────────────────────────────────────────────────────────

@router.post("/orders/{order_id}/combine", response_model=schemas.OrderResponse)
def combine_orders(
    order_id: int,
    body: dict,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    """
    把 source_order_id 的所有 items 合并到 order_id，
    source 订单变 cancelled，source 桌位释放。
    """
    source_id: int = body.get("source_order_id")
    if source_id is None:
        raise HTTPException(status_code=400, detail="source_order_id is required")
    if source_id == order_id:
        raise HTTPException(status_code=400, detail="Cannot combine an order with itself")

    locked = db.query(models.Order).filter(
        models.Order.id.in_([order_id, source_id]),
        models.Order.is_deleted == False,
        models.Order.status == "open",
    ).order_by(models.Order.id).with_for_update().all()
    by_id = {order.id: order for order in locked}
    target = by_id.get(order_id)
    if not target:
        raise HTTPException(status_code=404, detail="Target order not found or not open")

    source = by_id.get(source_id)
    if not source:
        raise HTTPException(status_code=404, detail="Source order not found or not open")

    for item in source.items:
        item.order_id = target.id

    source.status = "cancelled"
    if source.table_id != target.table_id:
        _set_table_status(db, source.table_id, "available")
    db.commit()
    db.refresh(target)
    return target


# ── Order Items ───────────────────────────────────────────────────────────────

@router.post("/orders/{order_id}/items", response_model=schemas.OrderItemResponse, status_code=201)
def add_order_item(
    order_id: int,
    data: schemas.OrderItemCreate,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    order = db.query(models.Order).filter(
        models.Order.id == order_id,
        models.Order.is_deleted == False,
        models.Order.status == "open",
    ).with_for_update().first()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found or not open")

    product = db.query(models.Product).filter(
        models.Product.id == data.product_id,
        models.Product.is_deleted == False,
        models.Product.status == "active",
    ).first()
    if not product:
        raise HTTPException(status_code=400, detail="Product not found or inactive")

    item = models.OrderItem(
        order_id=order.id,
        product_id=product.id,
        quantity=data.quantity,
        unit_price=product.price,
        weight_kg=_validated_weight(product, data.weight_kg),
        notes=data.notes,
    )
    db.add(item)
    db.commit()
    db.refresh(item)
    return item


@router.put("/orders/{order_id}/items/{item_id}", response_model=schemas.OrderItemResponse)
def update_order_item(
    order_id: int,
    item_id: int,
    data: schemas.OrderItemUpdate,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    order = db.query(models.Order).filter(
        models.Order.id == order_id, models.Order.status == "open"
    ).with_for_update().first()
    if not order:
        raise HTTPException(status_code=400, detail="Order is not open")
    item = db.query(models.OrderItem).filter(
        models.OrderItem.id == item_id,
        models.OrderItem.order_id == order_id,
    ).first()
    if not item:
        raise HTTPException(status_code=404, detail="Order item not found")
    if data.quantity is not None:
        item.quantity = data.quantity
    if "weight_kg" in data.model_fields_set:
        item.weight_kg = _validated_weight(item.product, data.weight_kg)
    if data.notes is not None:
        item.notes = data.notes
    db.commit()
    db.refresh(item)
    return item


@router.delete("/orders/{order_id}/items/{item_id}", status_code=204)
def delete_order_item(
    order_id: int,
    item_id: int,
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    order = db.query(models.Order).filter(
        models.Order.id == order_id, models.Order.status == "open"
    ).with_for_update().first()
    if not order:
        raise HTTPException(status_code=400, detail="Order is not open")
    item = db.query(models.OrderItem).filter(
        models.OrderItem.id == item_id,
        models.OrderItem.order_id == order_id,
    ).first()
    if not item:
        raise HTTPException(status_code=404, detail="Order item not found")
    db.delete(item)
    db.commit()
