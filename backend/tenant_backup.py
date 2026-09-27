"""Restaurant-scoped JSON backup used by tenant administrators."""

import json
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

from sqlalchemy.orm import Session

import models
from drive_connections import upload_for_restaurant
from time_utils import local_now


TENANT_MODELS = (
    models.User,
    models.Category,
    models.Product,
    models.Table,
    models.Order,
    models.OrderItem,
    models.StoreSettings,
    models.Payment,
    models.PaymentAuditLog,
    models.CashRecord,
    models.LoginLog,
    models.Worker,
    models.SalaryPayment,
    models.Promotion,
)


def _json_value(value):
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, bytes):
        return value.hex()
    return value


def _row_dict(row) -> dict:
    return {
        column.name: _json_value(getattr(row, column.name))
        for column in row.__table__.columns
    }


BACKUP_PREFIX = "kpos_backup_"


def run_tenant_backup(db: Session, restaurant: models.Restaurant) -> dict:
    """Upload a JSON backup to the restaurant's own connected Google Drive."""
    db.info["restaurant_id"] = restaurant.id
    payload = {
        "format": "k-pos-restaurant-backup-v1",
        "created_at": local_now().isoformat(),
        "restaurant": _row_dict(restaurant),
        "tables": {
            model.__tablename__: [_row_dict(row) for row in db.query(model).all()]
            for model in TENANT_MODELS
        },
    }
    stamp = local_now().strftime("%Y%m%d_%H%M%S")
    filename = f"{BACKUP_PREFIX}{restaurant.slug}_{stamp}.json"
    backup_dir = Path(__file__).parent / "backups"
    backup_dir.mkdir(exist_ok=True)
    path = backup_dir / filename
    try:
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        drive_file_id = upload_for_restaurant(db, restaurant, str(path), filename, BACKUP_PREFIX)
    finally:
        path.unlink(missing_ok=True)
    return {"status": "ok", "filename": filename, "drive_file_id": drive_file_id}
