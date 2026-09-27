from datetime import datetime, timedelta, timezone
from jose import jwt, JWTError
import os
from pathlib import Path
import secrets
import logging
import time
from dotenv import load_dotenv

load_dotenv()
logger = logging.getLogger(__name__)
_configured_secret = os.getenv("SECRET_KEY")
if not _configured_secret:
    raise RuntimeError("SECRET_KEY must be configured")


def _persistent_generated_secret() -> str:
    secret_path = Path(os.getenv("JWT_SECRET_FILE", ".jwt_secret"))
    if not secret_path.is_absolute():
        secret_path = Path(__file__).parent / secret_path
    try:
        existing = secret_path.read_text(encoding="utf-8").strip()
        if len(existing) < 32:
            raise RuntimeError("JWT secret file is invalid or truncated")
        return existing
    except FileNotFoundError:
        generated = secrets.token_urlsafe(48)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        try:
            fd = os.open(secret_path, flags, 0o600)
        except FileExistsError:
            for _ in range(50):
                existing = secret_path.read_text(encoding="utf-8").strip()
                if len(existing) >= 32:
                    return existing
                time.sleep(0.01)
            raise RuntimeError("JWT secret file is invalid or truncated")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(generated)
        return generated


if len(_configured_secret) < 32:
    logger.warning(
        "Configured SECRET_KEY is too short; using a generated persistent secret. "
        "Existing sessions will need to sign in again."
    )
    SECRET_KEY = _persistent_generated_secret()
else:
    SECRET_KEY = _configured_secret
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_DAYS = 30  # cashier设备登录一次不用每天登录，所以设长一点

def create_access_token(data: dict):
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + timedelta(days=ACCESS_TOKEN_EXPIRE_DAYS)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def decode_access_token(token: str):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload
    except JWTError:
        return None
