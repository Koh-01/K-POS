from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from database import get_db
from dependencies import require_admin
import models
import schemas

router = APIRouter(prefix="/salary", tags=["Salary"])

_MONTH_NAMES = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]

# ── Workers ────────────────────────────────────────────────────────────────

@router.get("/workers", response_model=list[schemas.WorkerResponse])
def list_workers(
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    return (
        db.query(models.Worker)
        .filter(models.Worker.is_active == True)
        .order_by(models.Worker.name)
        .all()
    )


@router.post("/workers", response_model=schemas.WorkerResponse, status_code=201)
def create_worker(
    data: schemas.WorkerCreate,
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    name = data.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="name is required")
    worker = models.Worker(
        name=name,
        ic_number=data.ic_number,
        phone=data.phone,
        position=data.position,
    )
    db.add(worker)
    db.commit()
    db.refresh(worker)
    return worker


@router.put("/workers/{worker_id}", response_model=schemas.WorkerResponse)
def update_worker(
    worker_id: int,
    data: schemas.WorkerUpdate,
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    worker = db.query(models.Worker).filter(models.Worker.id == worker_id).first()
    if not worker:
        raise HTTPException(status_code=404, detail="Worker not found")
    if data.name is not None:
        name = data.name.strip()
        if name:
            worker.name = name
    if data.ic_number is not None:
        worker.ic_number = data.ic_number or None
    if data.phone is not None:
        worker.phone = data.phone or None
    if data.position is not None:
        worker.position = data.position or None
    db.commit()
    db.refresh(worker)
    return worker


@router.delete("/workers/{worker_id}", status_code=204)
def delete_worker(
    worker_id: int,
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    worker = db.query(models.Worker).filter(models.Worker.id == worker_id).first()
    if not worker:
        raise HTTPException(status_code=404, detail="Worker not found")
    worker.is_active = False
    db.commit()


# ── Salary Payments ────────────────────────────────────────────────────────

@router.get("/payments", response_model=list[schemas.SalaryPaymentResponse])
def list_salary_payments(
    worker_id: int | None = Query(None),
    year: int | None = Query(None),
    month: int | None = Query(None),
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    q = db.query(models.SalaryPayment)
    if worker_id:
        q = q.filter(models.SalaryPayment.worker_id == worker_id)
    if year:
        q = q.filter(models.SalaryPayment.year == year)
    if month:
        q = q.filter(models.SalaryPayment.month == month)
    return q.order_by(models.SalaryPayment.created_at.desc()).all()


@router.post("/payments", response_model=schemas.SalaryPaymentResponse, status_code=201)
def create_salary_payment(
    data: schemas.SalaryPaymentCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_admin),
):
    worker = db.query(models.Worker).filter(
        models.Worker.id == data.worker_id,
        models.Worker.is_active == True,
    ).first()
    if not worker:
        raise HTTPException(status_code=404, detail="Worker not found")
    if not (1 <= data.month <= 12):
        raise HTTPException(status_code=400, detail="month must be 1-12")
    if data.amount <= 0:
        raise HTTPException(status_code=400, detail="amount must be positive")

    description = f"Salary - {worker.name} ({_MONTH_NAMES[data.month - 1]} {data.year})"

    cash_record = models.CashRecord(
        type="cash_out",
        amount=data.amount,
        description=description,
        category="Salary",
        created_by=current_user.id,
    )
    db.add(cash_record)
    db.flush()

    payment = models.SalaryPayment(
        worker_id=data.worker_id,
        year=data.year,
        month=data.month,
        amount=data.amount,
        note=data.note,
        cash_record_id=cash_record.id,
        created_by=current_user.id,
    )
    db.add(payment)
    db.commit()
    db.refresh(payment)
    return payment


@router.put("/payments/{payment_id}", response_model=schemas.SalaryPaymentResponse)
def update_salary_payment(
    payment_id: int,
    data: schemas.SalaryPaymentUpdate,
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    payment = db.query(models.SalaryPayment).filter(
        models.SalaryPayment.id == payment_id
    ).first()
    if not payment:
        raise HTTPException(status_code=404, detail="Payment not found")

    if data.amount is not None:
        if data.amount <= 0:
            raise HTTPException(status_code=400, detail="amount must be positive")
        payment.amount = data.amount
        if payment.cash_record_id:
            cash = db.query(models.CashRecord).filter(
                models.CashRecord.id == payment.cash_record_id
            ).first()
            if cash:
                cash.amount = data.amount

    if data.note is not None:
        payment.note = data.note or None

    db.commit()
    db.refresh(payment)
    return payment


@router.delete("/payments/{payment_id}", status_code=204)
def delete_salary_payment(
    payment_id: int,
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    payment = db.query(models.SalaryPayment).filter(
        models.SalaryPayment.id == payment_id
    ).first()
    if not payment:
        raise HTTPException(status_code=404, detail="Payment not found")
    if payment.cash_record_id:
        cash = db.query(models.CashRecord).filter(
            models.CashRecord.id == payment.cash_record_id
        ).first()
        if cash:
            db.delete(cash)
    db.delete(payment)
    db.commit()
