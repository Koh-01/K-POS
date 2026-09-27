import io
import csv
import uuid
from decimal import Decimal
from datetime import date, datetime, time
from pathlib import Path
from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile, File
from fastapi.responses import Response
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from PIL import Image

from database import get_db
from dependencies import get_current_user, require_permission
import models
import schemas
from image_utils import load_upload_image

RECEIPT_DIR = Path(__file__).parent / "static" / "receipts"
RECEIPT_DIR.mkdir(parents=True, exist_ok=True)

router = APIRouter(prefix="/cash-records", tags=["Cash Records"])


@router.get("", response_model=list[schemas.CashRecordResponse])
def list_cash_records(
    start_date: date | None = Query(None),
    end_date: date | None = Query(None),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if current_user.role != "admin":
        perms = current_user.permissions or {}
        if not perms.get("can_view_cash", True):
            raise HTTPException(status_code=403, detail="Permission denied: can_view_cash")
    q = db.query(models.CashRecord)
    if start_date:
        q = q.filter(models.CashRecord.created_at >= datetime.combine(start_date, time.min))
    if end_date:
        q = q.filter(models.CashRecord.created_at <= datetime.combine(end_date, time.max))
    if current_user.role != "admin":
        perms = current_user.permissions or {}
        if perms.get("hide_salary_from_cash", False):
            q = q.filter(models.CashRecord.category != "Salary")
    return q.order_by(models.CashRecord.created_at.desc()).all()


@router.post("", response_model=schemas.CashRecordResponse, status_code=201)
def create_cash_record(
    data: schemas.CashRecordCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if current_user.role != "admin":
        perms = current_user.permissions or {}
        if not perms.get("can_add_cash", True):
            raise HTTPException(status_code=403, detail="Permission denied: can_add_cash")
    if data.type not in ("cash_in", "cash_out"):
        raise HTTPException(status_code=400, detail="type must be 'cash_in' or 'cash_out'")
    if data.amount <= 0:
        raise HTTPException(status_code=400, detail="amount must be positive")
    if data.offline_ref:
        existing = db.query(models.CashRecord).filter(
            models.CashRecord.offline_ref == data.offline_ref
        ).first()
        if existing:
            return existing

    description = data.description.strip()
    if not description:
        description = "Cash In" if data.type == "cash_in" else "Cash Out"

    record = models.CashRecord(
        offline_ref=data.offline_ref,
        type=data.type,
        amount=data.amount,
        description=description,
        category=data.category,
        reference=data.reference,
        created_by=current_user.id,
    )
    db.add(record)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if data.offline_ref:
            existing = db.query(models.CashRecord).filter(
                models.CashRecord.offline_ref == data.offline_ref
            ).first()
            if existing:
                return existing
        raise HTTPException(status_code=409, detail="Cash record already exists")
    db.refresh(record)
    return record


@router.get("/{record_id}", response_model=schemas.CashRecordResponse)
def get_cash_record(
    record_id: int,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(
        require_permission("can_view_cash", default_for_cashier=True)
    ),
):
    record = db.query(models.CashRecord).filter(models.CashRecord.id == record_id).first()
    if not record:
        raise HTTPException(status_code=404, detail="Record not found")
    if (
        current_user.role != "admin"
        and (current_user.permissions or {}).get("hide_salary_from_cash", False)
        and record.category == "Salary"
    ):
        raise HTTPException(status_code=404, detail="Record not found")
    return record


@router.put("/{record_id}", response_model=schemas.CashRecordResponse)
def update_cash_record(
    record_id: int,
    data: schemas.CashRecordUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if current_user.role != "admin":
        perms = current_user.permissions or {}
        if not perms.get("can_edit_cash", True):
            raise HTTPException(status_code=403, detail="Permission denied: can_edit_cash")
    record = db.query(models.CashRecord).filter(models.CashRecord.id == record_id).first()
    if not record:
        raise HTTPException(status_code=404, detail="Record not found")
    if data.amount is not None:
        if data.amount <= 0:
            raise HTTPException(status_code=400, detail="amount must be positive")
        record.amount = data.amount
    if data.description is not None:
        record.description = data.description.strip() or record.description
    if data.category is not None:
        record.category = data.category if data.category else None
    if data.reference is not None:
        record.reference = data.reference if data.reference else None
    db.commit()
    db.refresh(record)
    return record


@router.delete("/{record_id}", status_code=204)
def delete_cash_record(
    record_id: int,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if current_user.role != "admin":
        perms = current_user.permissions or {}
        if not perms.get("can_delete_cash", True):
            raise HTTPException(status_code=403, detail="Permission denied: can_delete_cash")
    record = db.query(models.CashRecord).filter(models.CashRecord.id == record_id).first()
    if not record:
        raise HTTPException(status_code=404, detail="Record not found")
    db.delete(record)
    db.commit()


@router.post("/{record_id}/receipt", response_model=schemas.CashRecordResponse)
def upload_receipt(
    record_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    _=Depends(require_permission("can_edit_cash", default_for_cashier=True)),
):
    record = db.query(models.CashRecord).filter(models.CashRecord.id == record_id).first()
    if not record:
        raise HTTPException(status_code=404, detail="Record not found")
    if file.content_type not in ("image/jpeg", "image/png", "image/webp"):
        raise HTTPException(status_code=400, detail="Only JPEG, PNG, or WebP images are accepted")

    old = (
        RECEIPT_DIR / Path(record.receipt_image_path).name
        if record.receipt_image_path
        else None
    )

    filename = f"{uuid.uuid4().hex}.jpg"
    dest = RECEIPT_DIR / filename
    try:
        img = load_upload_image(file)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    img.thumbnail((1200, 1200), Image.LANCZOS)
    img.save(dest, format="JPEG", quality=85, optimize=True)

    record.receipt_image_path = f"static/receipts/{filename}"
    db.commit()
    if old:
        old.unlink(missing_ok=True)
    db.refresh(record)
    return record


@router.get("/export/csv")
def export_cash_csv(
    start_date: date | None = Query(None),
    end_date: date | None = Query(None),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(
        require_permission("can_view_cash", default_for_cashier=True)
    ),
):
    q = db.query(models.CashRecord)
    if start_date:
        q = q.filter(models.CashRecord.created_at >= datetime.combine(start_date, time.min))
    if end_date:
        q = q.filter(models.CashRecord.created_at <= datetime.combine(end_date, time.max))
    if (
        current_user.role != "admin"
        and (current_user.permissions or {}).get("hide_salary_from_cash", False)
    ):
        q = q.filter(models.CashRecord.category != "Salary")
    records = q.order_by(models.CashRecord.created_at).all()

    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["Date", "Type", "Amount (MYR)", "Description", "Reference"])

    total_in = Decimal("0")
    total_out = Decimal("0")
    for r in records:
        amt = Decimal(str(r.amount))
        writer.writerow([
            r.created_at.strftime("%Y-%m-%d %H:%M"),
            r.type,
            str(amt),
            r.description,
            r.reference or "",
        ])
        if r.type == "cash_in":
            total_in += amt
        else:
            total_out += amt

    writer.writerow([])
    writer.writerow(["Total Cash In", "", str(total_in), "", ""])
    writer.writerow(["Total Cash Out", "", str(total_out), "", ""])
    writer.writerow(["Net Cash", "", str(total_in - total_out), "", ""])

    label = f"{start_date or 'all'}_{end_date or 'all'}"
    filename = f"cash_records_{label}.csv"
    return Response(
        content=output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )
