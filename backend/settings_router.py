import io
import uuid
from decimal import Decimal
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, UploadFile, File
from PIL import Image
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user, require_permission
import models
import schemas

router = APIRouter(tags=["Settings"])

UPLOAD_DIR = Path(__file__).parent / "static" / "images"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

_DEFAULTS: dict[str, str] = {
    # Tax / charges (used by payment calculations)
    "sst_enabled": "1",
    "sst_rate": "0.06",
    "service_charge_enabled": "1",
    "service_charge_rate": "0.10",
    # Whether completed payments automatically create a cash_in cash record
    "payment_to_cash_record": "0",
    # Store info
    "store_name": "My Restaurant",
    "store_address": "",
    "store_phone": "",
    "store_email": "",
    "store_logo_path": "",
    # Theme
    "theme": "light",
    # Receipt
    "receipt_header": "",
    "receipt_header_size": "1",
    "receipt_header_align": "1",
    "receipt_footer": "Thank you for dining with us!",
    "receipt_footer_size": "0",
    "receipt_footer_align": "1",
    "receipt_show_logo": "0",
    # DuitNow QR
    "duitnow_qr_image_url": "",
}


def _get_settings(db: Session) -> dict:
    rows = db.query(models.StoreSettings).all()
    cfg = dict(_DEFAULTS)
    for row in rows:
        cfg[row.key] = row.value
    return cfg


@router.get("/settings", response_model=schemas.AllSettingsResponse)
def get_settings(db: Session = Depends(get_db), _=Depends(get_current_user)):
    cfg = _get_settings(db)
    return schemas.AllSettingsResponse(
        sst_enabled=cfg["sst_enabled"] == "1",
        sst_rate=Decimal(cfg["sst_rate"]),
        service_charge_enabled=cfg["service_charge_enabled"] == "1",
        service_charge_rate=Decimal(cfg["service_charge_rate"]),
        payment_to_cash_record=cfg["payment_to_cash_record"] == "1",
        store_name=cfg["store_name"],
        store_address=cfg["store_address"],
        store_phone=cfg["store_phone"],
        store_email=cfg["store_email"],
        store_logo_path=cfg["store_logo_path"],
        theme=cfg["theme"],
        receipt_header=cfg["receipt_header"],
        receipt_header_size=int(cfg.get("receipt_header_size", "1")),
        receipt_header_align=int(cfg.get("receipt_header_align", "1")),
        receipt_footer=cfg["receipt_footer"],
        receipt_footer_size=int(cfg.get("receipt_footer_size", "0")),
        receipt_footer_align=int(cfg.get("receipt_footer_align", "1")),
        receipt_show_logo=cfg["receipt_show_logo"] == "1",
        duitnow_qr_image_url=cfg.get("duitnow_qr_image_url", ""),
    )


@router.put("/settings", response_model=schemas.AllSettingsResponse)
def update_settings(
    body: schemas.AllSettingsUpdate,
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_settings")),
):
    updates: dict[str, str] = {}

    if body.sst_enabled is not None:
        updates["sst_enabled"] = "1" if body.sst_enabled else "0"
    if body.sst_rate is not None:
        updates["sst_rate"] = str(body.sst_rate)
    if body.service_charge_enabled is not None:
        updates["service_charge_enabled"] = "1" if body.service_charge_enabled else "0"
    if body.service_charge_rate is not None:
        updates["service_charge_rate"] = str(body.service_charge_rate)
    if body.payment_to_cash_record is not None:
        updates["payment_to_cash_record"] = "1" if body.payment_to_cash_record else "0"
    if body.store_name is not None:
        updates["store_name"] = body.store_name
    if body.store_address is not None:
        updates["store_address"] = body.store_address
    if body.store_phone is not None:
        updates["store_phone"] = body.store_phone
    if body.store_email is not None:
        updates["store_email"] = body.store_email
    if body.store_logo_path is not None:
        updates["store_logo_path"] = body.store_logo_path
    if body.theme is not None:
        if body.theme not in ("light", "dark"):
            raise HTTPException(status_code=400, detail="theme must be 'light' or 'dark'")
        updates["theme"] = body.theme
    if body.receipt_header is not None:
        updates["receipt_header"] = body.receipt_header
    if body.receipt_header_size is not None:
        updates["receipt_header_size"] = str(body.receipt_header_size)
    if body.receipt_header_align is not None:
        updates["receipt_header_align"] = str(body.receipt_header_align)
    if body.receipt_footer is not None:
        updates["receipt_footer"] = body.receipt_footer
    if body.receipt_footer_size is not None:
        updates["receipt_footer_size"] = str(body.receipt_footer_size)
    if body.receipt_footer_align is not None:
        updates["receipt_footer_align"] = str(body.receipt_footer_align)
    if body.receipt_show_logo is not None:
        updates["receipt_show_logo"] = "1" if body.receipt_show_logo else "0"
    if body.duitnow_qr_image_url is not None:
        updates["duitnow_qr_image_url"] = body.duitnow_qr_image_url

    for key, val in updates.items():
        row = db.query(models.StoreSettings).filter(models.StoreSettings.key == key).first()
        if row:
            row.value = val
        else:
            db.add(models.StoreSettings(key=key, value=val))
    db.commit()
    return get_settings(db)


@router.post("/settings/store-logo", response_model=schemas.AllSettingsResponse)
async def upload_store_logo(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_settings")),
):
    if file.content_type not in ("image/jpeg", "image/png", "image/webp"):
        raise HTTPException(status_code=400, detail="Only JPEG, PNG, or WebP images are accepted")

    data = await file.read()
    img = Image.open(io.BytesIO(data)).convert("RGB")

    existing = db.query(models.StoreSettings).filter(
        models.StoreSettings.key == "store_logo_path"
    ).first()
    if existing and existing.value:
        old_path = Path(__file__).parent / existing.value
        old_path.unlink(missing_ok=True)

    filename = f"store_logo_{uuid.uuid4().hex[:8]}.jpg"
    dest = UPLOAD_DIR / filename
    img.save(dest, format="JPEG", quality=90, optimize=True)

    relative_path = f"static/images/{filename}"
    row = db.query(models.StoreSettings).filter(
        models.StoreSettings.key == "store_logo_path"
    ).first()
    if row:
        row.value = relative_path
    else:
        db.add(models.StoreSettings(key="store_logo_path", value=relative_path))
    db.commit()

    return get_settings(db)


@router.post("/settings/duitnow-qr", response_model=schemas.AllSettingsResponse)
async def upload_duitnow_qr(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_manage_settings")),
):
    if file.content_type not in ("image/jpeg", "image/png", "image/webp"):
        raise HTTPException(status_code=400, detail="Only JPEG, PNG, or WebP images are accepted")

    data = await file.read()
    img = Image.open(io.BytesIO(data)).convert("RGB")

    # Delete old QR if exists
    existing = db.query(models.StoreSettings).filter(
        models.StoreSettings.key == "duitnow_qr_image_url"
    ).first()
    if existing and existing.value:
        old_path = Path(__file__).parent / existing.value
        old_path.unlink(missing_ok=True)

    filename = f"duitnow_qr_{uuid.uuid4().hex[:8]}.jpg"
    dest = UPLOAD_DIR / filename
    img.save(dest, format="JPEG", quality=90, optimize=True)

    relative_path = f"static/images/{filename}"
    row = db.query(models.StoreSettings).filter(
        models.StoreSettings.key == "duitnow_qr_image_url"
    ).first()
    if row:
        row.value = relative_path
    else:
        db.add(models.StoreSettings(key="duitnow_qr_image_url", value=relative_path))
    db.commit()

    return get_settings(db)
