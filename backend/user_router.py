from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user, require_admin
from auth import hash_password, verify_password
import models
import schemas

router = APIRouter(prefix="/users", tags=["Users"])


@router.get("", response_model=list[schemas.UserResponse])
def list_users(
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    return db.query(models.User).order_by(models.User.id).all()


@router.get("/{user_id}", response_model=schemas.UserResponse)
def get_user(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if current_user.role != "admin" and current_user.id != user_id:
        raise HTTPException(status_code=403, detail="Not authorised")
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@router.put("/{user_id}", response_model=schemas.UserResponse)
def update_user(
    user_id: int,
    data: schemas.UserProfileUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Edit full_name (and role if admin). A user can edit their own profile; only admin can change role."""
    if current_user.role != "admin" and current_user.id != user_id:
        raise HTTPException(status_code=403, detail="Not authorised")

    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if data.full_name is not None:
        user.full_name = data.full_name

    if data.role is not None:
        if current_user.role != "admin":
            raise HTTPException(status_code=403, detail="Only admin can change roles")
        if data.role not in ("admin", "cashier"):
            raise HTTPException(status_code=400, detail="role must be 'admin' or 'cashier'")
        user.role = data.role

    db.commit()
    db.refresh(user)
    return user


@router.put("/{user_id}/password", status_code=204)
def change_password(
    user_id: int,
    data: schemas.ChangePasswordRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """
    Change password.
    - Own account: must supply current_password for verification.
    - Admin changing someone else's password: current_password not required.
    """
    if current_user.role != "admin" and current_user.id != user_id:
        raise HTTPException(status_code=403, detail="Not authorised")

    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    # Non-admin changing own password must verify current password
    if current_user.id == user_id:
        if not data.current_password:
            raise HTTPException(status_code=400, detail="current_password is required")
        if not verify_password(data.current_password, user.password_hash):
            raise HTTPException(status_code=400, detail="Current password is incorrect")

    if len(data.new_password) < 6:
        raise HTTPException(status_code=400, detail="Password must be at least 6 characters")

    user.password_hash = hash_password(data.new_password)
    db.commit()


@router.delete("/{user_id}", status_code=204)
def delete_user(
    user_id: int,
    db: Session = Depends(get_db),
    current_admin: models.User = Depends(require_admin),
):
    if current_admin.id == user_id:
        raise HTTPException(status_code=400, detail="Cannot delete your own account")
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if user.role == "admin":
        admin_count = db.query(models.User).filter(models.User.role == "admin").count()
        if admin_count <= 1:
            raise HTTPException(status_code=400, detail="Cannot delete the last admin")
    has_orders = db.query(models.Order).filter(models.Order.created_by == user_id).first()
    has_payments = db.query(models.Payment).filter(models.Payment.created_by == user_id).first()
    has_cash = db.query(models.CashRecord).filter(models.CashRecord.created_by == user_id).first()
    has_promos = db.query(models.Promotion).filter(models.Promotion.created_by == user_id).first()
    has_audit = db.query(models.PaymentAuditLog).filter(models.PaymentAuditLog.changed_by == user_id).first()
    if has_orders or has_payments or has_cash or has_promos or has_audit:
        raise HTTPException(status_code=400, detail="User has existing records. Deactivate instead.")
    # LoginLog.user_id is nullable — nullify before delete to avoid FK violation
    db.query(models.LoginLog).filter(models.LoginLog.user_id == user_id).update({"user_id": None})
    db.delete(user)
    db.commit()


@router.put("/{user_id}/permissions", response_model=schemas.UserResponse)
def update_user_permissions(
    user_id: int,
    data: schemas.UserPermissionsUpdate,
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.permissions = data.model_dump()
    db.commit()
    db.refresh(user)
    return user


@router.patch("/{user_id}/status", response_model=schemas.UserResponse)
def toggle_user_status(
    user_id: int,
    data: schemas.UserStatusUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_admin),
):
    """Admin-only: activate or deactivate a user account."""
    if current_user.id == user_id:
        raise HTTPException(status_code=400, detail="Cannot change your own account status")

    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    user.is_active = data.is_active
    db.commit()
    db.refresh(user)
    return user
