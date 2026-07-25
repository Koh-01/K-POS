from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from database import get_db
from token_utils import decode_access_token
import models

bearer_scheme = HTTPBearer()

def get_current_user(credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme), db: Session = Depends(get_db)):
    payload = decode_access_token(credentials.credentials)
    if payload is None:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    username = payload.get("sub")
    user = db.query(models.User).filter(models.User.username == username).first()
    if user is None:
        raise HTTPException(status_code=401, detail="User not found")

    return user

def require_admin(current_user: models.User = Depends(get_current_user)):
    if current_user.role != "admin":
        raise HTTPException(status_code=403, detail="Admin access required")
    return current_user


def require_permission(perm_key: str, default_for_cashier: bool = False):
    """Factory: allows admin unconditionally, cashier only if they have the named permission."""
    def _check(current_user: models.User = Depends(get_current_user)):
        if current_user.role == "admin":
            return current_user
        perms = current_user.permissions or {}
        if not perms.get(perm_key, default_for_cashier):
            raise HTTPException(status_code=403, detail=f"Permission denied: {perm_key}")
        return current_user
    return _check