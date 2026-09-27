import hashlib
import re
import secrets
from datetime import datetime, timedelta

from fastapi import HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session

import models
import schemas
from auth import hash_password
from tenant_database import provision_restaurant_database, sync_user_shadow


VERIFICATION_LIFETIME = timedelta(hours=24)


def _now() -> datetime:
    return datetime.utcnow()


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _unique_slug(db: Session, name: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:140] or "restaurant"
    slug = base
    while db.query(models.Restaurant.id).filter(models.Restaurant.slug == slug).first():
        slug = f"{base[:131]}-{secrets.token_hex(4)}"
    return slug


def issue_verification_token(db: Session, user: models.User) -> str:
    now = _now()
    db.query(models.EmailVerificationToken).filter(
        models.EmailVerificationToken.user_id == user.id,
        models.EmailVerificationToken.used_at.is_(None),
    ).update({"used_at": now}, synchronize_session=False)
    raw_token = secrets.token_urlsafe(40)
    db.add(models.EmailVerificationToken(
        restaurant_id=user.restaurant_id,
        user_id=user.id,
        token_hash=_token_hash(raw_token),
        expires_at=now + VERIFICATION_LIFETIME,
    ))
    db.commit()
    return raw_token


def register_admin(db: Session, data: schemas.AdminRegistrationRequest) -> tuple[models.User, str]:
    email = data.email.lower()
    existing = db.query(models.User).filter(func.lower(models.User.email) == email).first()
    if existing:
        if existing.email_verified:
            raise HTTPException(status_code=409, detail="An account already exists for this email")
        raise HTTPException(
            status_code=409,
            detail="This email is awaiting verification. Use resend verification.",
        )

    restaurant = models.Restaurant(
        name=data.restaurant_name,
        slug=_unique_slug(db, data.restaurant_name),
        is_active=False,
    )
    db.add(restaurant)
    db.flush()

    user = models.User(
        restaurant_id=restaurant.id,
        username=email,
        email=email,
        email_verified=False,
        password_hash=hash_password(data.password),
        role="admin",
        full_name=data.full_name,
        is_active=False,
    )
    db.add(user)
    db.flush()
    db.add(models.StoreSettings(
        restaurant_id=restaurant.id,
        key="store_name",
        value=data.restaurant_name,
    ))
    db.commit()
    db.refresh(user)
    db.refresh(restaurant)
    provision_restaurant_database(db, restaurant)
    return user, issue_verification_token(db, user)


def resend_verification(db: Session, email: str) -> tuple[models.User, str] | None:
    user = db.query(models.User).filter(func.lower(models.User.email) == email.lower()).first()
    if not user or user.email_verified or user.role != "admin":
        return None
    if not user.restaurant.database_ready:
        provision_restaurant_database(db, user.restaurant)
    return user, issue_verification_token(db, user)


def verify_email_token(db: Session, raw_token: str) -> models.User:
    now = _now()
    token = db.query(models.EmailVerificationToken).filter(
        models.EmailVerificationToken.token_hash == _token_hash(raw_token),
        models.EmailVerificationToken.used_at.is_(None),
    ).first()
    if not token or token.expires_at < now:
        raise HTTPException(status_code=400, detail="Verification link is invalid or expired")

    user = db.query(models.User).filter(models.User.id == token.user_id).first()
    restaurant = db.query(models.Restaurant).filter(models.Restaurant.id == token.restaurant_id).first()
    if not user or not restaurant:
        raise HTTPException(status_code=400, detail="Verification account no longer exists")
    if not restaurant.database_ready:
        raise HTTPException(status_code=503, detail="Restaurant database is not ready")

    token.used_at = now
    user.email_verified = True
    user.is_active = True
    restaurant.is_active = True
    db.commit()
    db.refresh(user)
    sync_user_shadow(db, user)
    return user
