import logging

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy.orm import Session

from database import get_db
from email_service import email_delivery_configured, send_verification_email
from registration_service import register_admin, resend_verification, verify_email_token
import schemas


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/auth", tags=["Authentication"])


def _send_verification_safely(email: str, full_name: str, restaurant_name: str, token: str) -> None:
    try:
        send_verification_email(email, full_name, restaurant_name, token)
    except Exception:
        logger.exception("Unable to send verification email to %s", email)


@router.post("/register", status_code=202)
def register(
    data: schemas.AdminRegistrationRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    if not email_delivery_configured():
        raise HTTPException(status_code=503, detail="Email verification is not configured")
    user, token = register_admin(db, data)
    background_tasks.add_task(
        _send_verification_safely,
        user.email,
        user.full_name or user.email,
        data.restaurant_name,
        token,
    )
    return {"message": "Registration received. Check your email to verify the admin account."}


@router.post("/resend-verification", status_code=202)
def resend(
    data: schemas.ResendVerificationRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    if not email_delivery_configured():
        raise HTTPException(status_code=503, detail="Email verification is not configured")
    result = resend_verification(db, data.email)
    if result:
        user, token = result
        background_tasks.add_task(
            _send_verification_safely,
            user.email,
            user.full_name or user.email,
            user.restaurant.name,
            token,
        )
    # Always use the same response to avoid disclosing registered emails.
    return {"message": "If the account is awaiting verification, a new email will be sent."}


@router.post("/verify-email")
def verify(data: schemas.VerifyEmailRequest, db: Session = Depends(get_db)):
    user = verify_email_token(db, data.token)
    return {"message": "Email verified. You can now sign in.", "email": user.email}
