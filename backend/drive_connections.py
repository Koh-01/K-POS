"""
Per-restaurant Google Drive connections.

Each restaurant Admin connects their own Google account from Web Admin →
Settings. Backups and monthly reports for that restaurant are then uploaded to
a "K POS – <restaurant>" folder in *their* Drive instead of the operator's.

Uses the `drive.file` scope, so K POS can only see files it created itself.
Requires a "Web application" OAuth client whose authorised redirect URI is
`{PUBLIC_BASE_URL}/web/settings/google-drive/callback`.
"""
import base64
import hashlib
import os
import secrets
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode

import requests
from cryptography.fernet import Fernet, InvalidToken
from google.auth.exceptions import RefreshError
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from jose import JWTError, jwt
from sqlalchemy.orm import Session

import models
from gdrive_backup import upload_with_service
from time_utils import local_now
from token_utils import ALGORITHM, SECRET_KEY

SCOPES = ["https://www.googleapis.com/auth/drive.file"]
_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
_TOKEN_URL = "https://oauth2.googleapis.com/token"
_REVOKE_URL = "https://oauth2.googleapis.com/revoke"
_FOLDER_MIME = "application/vnd.google-apps.folder"
STATE_COOKIE = "gdrive_oauth_nonce"


class DriveNotConnected(RuntimeError):
    """The restaurant has not connected (or has lost access to) Google Drive."""


# ── Configuration ────────────────────────────────────────────────────────────

def _client_id() -> str:
    return os.getenv("GOOGLE_OAUTH_CLIENT_ID", "").strip()


def _client_secret() -> str:
    return os.getenv("GOOGLE_OAUTH_CLIENT_SECRET", "").strip()


def oauth_configured() -> bool:
    return bool(_client_id() and _client_secret())


def redirect_uri() -> str:
    base = os.getenv("PUBLIC_BASE_URL", "http://localhost:8000").rstrip("/")
    return f"{base}/web/settings/google-drive/callback"


# ── Refresh-token encryption ─────────────────────────────────────────────────

def _fernet() -> Fernet:
    digest = hashlib.sha256(f"kpos-drive-token:{SECRET_KEY}".encode()).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def encrypt_token(token: str) -> str:
    return _fernet().encrypt(token.encode()).decode()


def decrypt_token(value: str) -> str:
    try:
        return _fernet().decrypt(value.encode()).decode()
    except InvalidToken as exc:
        # SECRET_KEY changed since the account was connected.
        raise DriveNotConnected("Google Drive must be reconnected.") from exc


# ── OAuth flow ───────────────────────────────────────────────────────────────

def build_authorization_url(user: models.User) -> tuple[str, str]:
    """Return (Google consent URL, nonce to store in the browser cookie)."""
    nonce = secrets.token_urlsafe(24)
    state = jwt.encode({
        "purpose": "gdrive-connect",
        "uid": user.id,
        "rid": user.restaurant_id,
        "nonce": nonce,
        "exp": datetime.now(timezone.utc) + timedelta(minutes=10),
    }, SECRET_KEY, algorithm=ALGORITHM)
    params = {
        "client_id": _client_id(),
        "redirect_uri": redirect_uri(),
        "response_type": "code",
        "scope": " ".join(SCOPES),
        "access_type": "offline",
        # Always show consent so Google issues a refresh token on reconnect.
        "prompt": "consent",
        "include_granted_scopes": "true",
        "state": state,
    }
    return f"{_AUTH_URL}?{urlencode(params)}", nonce


def verify_state(state: str, nonce: str | None, user: models.User) -> bool:
    try:
        payload = jwt.decode(state, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return False
    return bool(
        nonce
        and payload.get("purpose") == "gdrive-connect"
        and payload.get("uid") == user.id
        and payload.get("rid") == user.restaurant_id
        and secrets.compare_digest(str(payload.get("nonce", "")), nonce)
    )


def _credentials(refresh_token: str, access_token: str | None = None) -> Credentials:
    return Credentials(
        token=access_token,
        refresh_token=refresh_token,
        token_uri=_TOKEN_URL,
        client_id=_client_id(),
        client_secret=_client_secret(),
        scopes=SCOPES,
    )


def _service(creds: Credentials):
    return build("drive", "v3", credentials=creds, cache_discovery=False)


def _create_folder(service, restaurant: models.Restaurant) -> str:
    folder = service.files().create(
        body={"name": f"K POS – {restaurant.name}", "mimeType": _FOLDER_MIME},
        fields="id",
    ).execute()
    return folder["id"]


def complete_connection(db: Session, user: models.User, code: str) -> models.RestaurantDriveConnection:
    """Exchange the OAuth code, create the Drive folder and store the connection."""
    resp = requests.post(_TOKEN_URL, data={
        "code": code,
        "client_id": _client_id(),
        "client_secret": _client_secret(),
        "redirect_uri": redirect_uri(),
        "grant_type": "authorization_code",
    }, timeout=15)
    if resp.status_code != 200:
        raise RuntimeError(f"Google rejected the authorisation code ({resp.status_code}).")
    tokens = resp.json()
    refresh_token = tokens.get("refresh_token")
    if not refresh_token:
        raise RuntimeError("Google did not return a refresh token. Please try connecting again.")
    granted = set((tokens.get("scope") or "").split())
    if SCOPES[0] not in granted:
        raise RuntimeError("Google Drive permission was not granted.")

    service = _service(_credentials(refresh_token, tokens.get("access_token")))
    email = service.about().get(fields="user(emailAddress)").execute().get("user", {}).get("emailAddress")
    restaurant = user.restaurant
    folder_id = _create_folder(service, restaurant)

    conn = restaurant.drive_connection
    if conn is None:
        conn = models.RestaurantDriveConnection(restaurant_id=restaurant.id)
        db.add(conn)
    elif conn.refresh_token_encrypted:
        _revoke_quietly(conn.refresh_token_encrypted)
    conn.google_email = email
    conn.refresh_token_encrypted = encrypt_token(refresh_token)
    conn.folder_id = folder_id
    conn.connected_by_user_id = user.id
    conn.connected_at = local_now()
    conn.last_error = None
    db.commit()
    return conn


def _revoke_quietly(encrypted: str) -> None:
    try:
        requests.post(_REVOKE_URL, params={"token": decrypt_token(encrypted)}, timeout=10)
    except Exception:
        pass


def disconnect(db: Session, restaurant: models.Restaurant) -> None:
    conn = restaurant.drive_connection
    if conn is None:
        return
    _revoke_quietly(conn.refresh_token_encrypted)
    db.delete(conn)
    db.commit()


# ── Status / upload ──────────────────────────────────────────────────────────

def folder_url(conn: models.RestaurantDriveConnection | None) -> str | None:
    if conn and conn.folder_id:
        return f"https://drive.google.com/drive/folders/{conn.folder_id}"
    return None


def status(restaurant: models.Restaurant) -> dict:
    conn = restaurant.drive_connection
    return {
        "configured": oauth_configured(),
        "connected": conn is not None,
        "google_email": conn.google_email if conn else None,
        "folder_url": folder_url(conn),
        "last_upload_at": conn.last_upload_at.isoformat() if conn and conn.last_upload_at else None,
        "last_error": conn.last_error if conn else None,
        "settings_url": os.getenv("PUBLIC_BASE_URL", "").rstrip("/") + "/web/settings#google-drive",
    }


def upload_for_restaurant(
    db: Session,
    restaurant: models.Restaurant,
    local_path: str,
    filename: str,
    prune_prefix: str,
) -> str:
    """Upload a file to the restaurant's own Drive folder. Returns the Drive file id."""
    conn = restaurant.drive_connection
    if conn is None:
        raise DriveNotConnected(
            "Google Drive is not connected. Connect it in Web Admin → Settings → Google Drive."
        )
    if not oauth_configured():
        raise RuntimeError("Google OAuth client is not configured on the server.")

    service = _service(_credentials(decrypt_token(conn.refresh_token_encrypted)))
    try:
        if not conn.folder_id:
            conn.folder_id = _create_folder(service, restaurant)
        try:
            file_id = upload_with_service(service, local_path, filename, conn.folder_id, prune_prefix)
        except HttpError as exc:
            if exc.status_code != 404:
                raise
            # The Admin deleted the K POS folder — recreate it and retry once.
            conn.folder_id = _create_folder(service, restaurant)
            file_id = upload_with_service(service, local_path, filename, conn.folder_id, prune_prefix)
    except RefreshError as exc:
        conn.last_error = "Google access was revoked or expired. Please reconnect Google Drive."
        db.commit()
        raise DriveNotConnected(conn.last_error) from exc
    except Exception as exc:
        conn.last_error = str(exc)[:500]
        db.commit()
        raise
    conn.last_upload_at = local_now()
    conn.last_error = None
    db.commit()
    return file_id
