import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user, require_admin
from auth import hash_password, verify_password
import models
import schemas
from tenant_database import sync_user_shadow

router = APIRouter(prefix="/users", tags=["Users"])


@router.get("", response_model=list[schemas.UserResponse])
def list_users(
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    return (
        db.query(models.User)
        .filter(models.User.is_deleted == False)
        .order_by(models.User.id)
        .all()
    )


@router.get("/{user_id}", response_model=schemas.UserResponse)
def get_user(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if current_user.role != "admin" and current_user.id != user_id:
        raise HTTPException(status_code=403, detail="Not authorised")
    user = db.query(models.User).filter(
        models.User.id == user_id,
        models.User.is_deleted == False,
    ).first()
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
    """Edit a profile. Admin accounts are created only through email registration."""
    if current_user.role != "admin" and current_user.id != user_id:
        raise HTTPException(status_code=403, detail="Not authorised")

    user = db.query(models.User).filter(
        models.User.id == user_id,
        models.User.is_deleted == False,
    ).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if data.full_name is not None:
        user.full_name = data.full_name

    if data.role is not None:
        if data.role != user.role:
            raise HTTPException(
                status_code=400,
                detail="Roles cannot be changed. Admins register by verified email; cashiers are created by an admin.",
            )

    db.commit()
    db.refresh(user)
    sync_user_shadow(db, user)
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

    user = db.query(models.User).filter(
        models.User.id == user_id,
        models.User.is_deleted == False,
    ).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    # Non-admin changing own password must verify current password
    if current_user.id == user_id:
        if not data.current_password:
            raise HTTPException(status_code=400, detail="current_password is required")
        if not verify_password(data.current_password, user.password_hash):
            raise HTTPException(status_code=400, detail="Current password is incorrect")

    if len(data.new_password) < 8:
        raise HTTPException(status_code=400, detail="Password must be at least 8 characters")

    user.password_hash = hash_password(data.new_password)
    db.commit()
    sync_user_shadow(db, user)


@router.delete("/{user_id}", status_code=204)
def delete_user(
    user_id: int,
    db: Session = Depends(get_db),
    current_admin: models.User = Depends(require_admin),
):
    if current_admin.id == user_id:
        raise HTTPException(status_code=400, detail="Cannot delete your own account")
    user = db.query(models.User).filter(
        models.User.id == user_id,
        models.User.is_deleted == False,
    ).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if user.role == "admin":
        admin_count = db.query(models.User).filter(
            models.User.role == "admin",
            models.User.is_deleted == False,
        ).count()
        if admin_count <= 1:
            raise HTTPException(status_code=400, detail="Cannot delete the last admin")
    # Keep the row as the owner of historical orders/payments/cash records, but
    # make the account impossible to authenticate and free its old username so
    # the business can reuse it later if desired.
    user.username = f"deleted_{user.id}_{uuid.uuid4().hex[:8]}"
    user.is_active = False
    user.is_deleted = True
    user.permissions = {}
    db.commit()
    sync_user_shadow(db, user)


@router.put("/{user_id}/permissions", response_model=schemas.UserResponse)
def update_user_permissions(
    user_id: int,
    data: schemas.UserPermissionsUpdate,
    db: Session = Depends(get_db),
    _=Depends(require_admin),
):
    user = db.query(models.User).filter(
        models.User.id == user_id,
        models.User.is_deleted == False,
    ).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.permissions = data.model_dump()
    db.commit()
    db.refresh(user)
    sync_user_shadow(db, user)
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

    user = db.query(models.User).filter(
        models.User.id == user_id,
        models.User.is_deleted == False,
    ).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    user.is_active = data.is_active
    db.commit()
    db.refresh(user)
    sync_user_shadow(db, user)
    return user
