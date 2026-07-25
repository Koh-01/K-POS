from datetime import datetime, timezone
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user
import models
import schemas

router = APIRouter(prefix="/sync", tags=["Sync"])


@router.get("/catalog")
def get_catalog(db: Session = Depends(get_db), _=Depends(get_current_user)):
    """Full product/category/table snapshot for offline caching."""
    categories = (
        db.query(models.Category)
        .filter(models.Category.is_active == True)
        .order_by(models.Category.sort_order, models.Category.id)
        .all()
    )
    products = (
        db.query(models.Product)
        .filter(models.Product.is_deleted == False, models.Product.status == "active")
        .order_by(models.Product.sort_order, models.Product.id)
        .all()
    )
    tables = (
        db.query(models.Table)
        .filter(models.Table.is_active == True)
        .order_by(models.Table.sort_order, models.Table.id)
        .all()
    )
    return {
        "synced_at": datetime.now(timezone.utc).isoformat(),
        "categories": [schemas.CategoryResponse.model_validate(c) for c in categories],
        "products": [schemas.ProductResponse.model_validate(p) for p in products],
        "tables": [schemas.TableResponse.model_validate(t) for t in tables],
    }


@router.post("/orders", response_model=list[schemas.SyncOrderResult])
def sync_orders(
    orders: list[schemas.SyncOrderCreate],
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """
    Batch-create orders from offline device.
    Each item must have a unique offline_ref (device UUID).
    Already-synced refs are skipped (idempotent).
    """
    results: list[schemas.SyncOrderResult] = []

    for item in orders:
        # Idempotency: if already synced, return existing
        existing = (
            db.query(models.Order)
            .filter(models.Order.offline_ref == item.offline_ref)
            .first()
        )
        if existing:
            results.append(schemas.SyncOrderResult(
                offline_ref=item.offline_ref,
                order_id=existing.id,
                order_number=existing.order_number,
                action="skipped",
            ))
            continue

        try:
            if not item.items:
                raise ValueError("Order has no items")

            # Generate order number based on device_created_at or now
            ref_time = item.device_created_at or datetime.now(timezone.utc)
            day_str = ref_time.strftime("%Y%m%d")
            prefix = f"ORD-{day_str}-"
            last = (
                db.query(models.Order)
                .filter(models.Order.order_number.like(f"{prefix}%"))
                .order_by(models.Order.id.desc())
                .first()
            )
            seq = 1
            if last:
                try:
                    seq = int(last.order_number.split("-")[-1]) + 1
                except ValueError:
                    pass
            order_number = f"{prefix}{seq:03d}"

            order = models.Order(
                order_number=order_number,
                table_id=item.table_id,
                order_type=item.order_type,
                notes=item.notes,
                created_by=current_user.id,
                offline_ref=item.offline_ref,
                status="open",
                created_at=item.device_created_at or datetime.now(timezone.utc),
            )
            db.add(order)
            db.flush()

            for item_data in item.items:
                product = db.query(models.Product).filter(
                    models.Product.id == item_data.product_id,
                    models.Product.is_deleted == False,
                ).first()
                if not product:
                    raise ValueError(f"Product {item_data.product_id} not found")
                if item_data.quantity <= 0:
                    raise ValueError("quantity must be > 0")
                db.add(models.OrderItem(
                    order_id=order.id,
                    product_id=product.id,
                    quantity=item_data.quantity,
                    unit_price=product.price,
                    notes=item_data.notes,
                ))

            if item.table_id:
                table = db.query(models.Table).filter(models.Table.id == item.table_id).first()
                if table:
                    table.status = "occupied"

            db.commit()
            db.refresh(order)

            results.append(schemas.SyncOrderResult(
                offline_ref=item.offline_ref,
                order_id=order.id,
                order_number=order.order_number,
                action="created",
            ))

        except Exception as e:
            db.rollback()
            results.append(schemas.SyncOrderResult(
                offline_ref=item.offline_ref,
                order_id=None,
                order_number=None,
                action="error",
                error=str(e),
            ))

    return results
