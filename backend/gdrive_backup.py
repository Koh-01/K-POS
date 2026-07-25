"""
Google Drive backup module — pure Python dump (no mysqldump binary needed).

Dumps all tables via pymysql, uploads the .sql file to Google Drive.
Called automatically every day at 12:00 (APScheduler in main.py),
and exposed as POST /admin/backup for manual triggers.
"""
import os
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import pymysql
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload

_SCOPES = ["https://www.googleapis.com/auth/drive.file"]
_TOKEN_FILE = Path(__file__).parent / "token.json"


# ── Google Drive helpers ──────────────────────────────────────────────────────

def _drive_service():
    if not _TOKEN_FILE.exists():
        raise RuntimeError(
            "token.json not found. Run `python gdrive_auth_setup.py` once to authorize."
        )
    creds = Credentials.from_authorized_user_file(str(_TOKEN_FILE), _SCOPES)
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
        with open(_TOKEN_FILE, "w") as f:
            f.write(creds.to_json())
    return build("drive", "v3", credentials=creds, cache_discovery=False)


def _do_upload(service, local_path: str, filename: str, folder_id: str) -> str:
    metadata = {"name": filename, "parents": [folder_id]}
    media = MediaFileUpload(local_path, mimetype="application/octet-stream", resumable=True)
    file = service.files().create(body=metadata, media_body=media, fields="id").execute()
    return file.get("id")


def _delete_oldest_backup(service, folder_id: str):
    resp = service.files().list(
        q=f"'{folder_id}' in parents and trashed=false",
        orderBy="createdTime asc",
        pageSize=1,
        fields="files(id,name)",
    ).execute()
    files = resp.get("files", [])
    if files:
        oldest = files[0]
        service.files().delete(fileId=oldest["id"]).execute()
        print(f"[backup] Deleted oldest backup to free quota: {oldest['name']}")


def _upload(local_path: str, filename: str, folder_id: str) -> str:
    service = _drive_service()
    try:
        return _do_upload(service, local_path, filename, folder_id)
    except HttpError as exc:
        if exc.status_code == 403 and "storageQuotaExceeded" in str(exc):
            print("[backup] Storage quota exceeded — deleting oldest backup and retrying")
            _delete_oldest_backup(service, folder_id)
            return _do_upload(service, local_path, filename, folder_id)
        raise


# ── Pure-Python SQL dump ──────────────────────────────────────────────────────

def _escape(val) -> str:
    if val is None:
        return "NULL"
    if isinstance(val, bool):
        return "1" if val else "0"
    if isinstance(val, (int, float, Decimal)):
        return str(val)
    if isinstance(val, (datetime, date)):
        return f"'{val}'"
    if isinstance(val, bytes):
        return f"0x{val.hex()}"
    return "'" + str(val).replace("\\", "\\\\").replace("'", "\\'") + "'"


def _python_dump(host: str, port: str, user: str, password: str, dbname: str, output_path: str):
    conn = pymysql.connect(
        host=host, port=int(port), user=user,
        password=password, database=dbname, charset="utf8mb4",
    )
    cur = conn.cursor()

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(f"-- POS System backup {datetime.now().isoformat()}\n")
        f.write("SET NAMES utf8mb4;\n")
        f.write("SET FOREIGN_KEY_CHECKS=0;\n\n")

        cur.execute("SHOW TABLES")
        tables = [row[0] for row in cur.fetchall()]

        for table in tables:
            cur.execute(f"SHOW CREATE TABLE `{table}`")
            create_sql = cur.fetchone()[1]
            f.write(f"DROP TABLE IF EXISTS `{table}`;\n")
            f.write(f"{create_sql};\n\n")

            cur.execute(f"SELECT * FROM `{table}`")
            rows = cur.fetchall()
            for row in rows:
                vals = ", ".join(_escape(v) for v in row)
                f.write(f"INSERT INTO `{table}` VALUES ({vals});\n")
            if rows:
                f.write("\n")

        f.write("SET FOREIGN_KEY_CHECKS=1;\n")

    cur.close()
    conn.close()


# ── Public entry point ────────────────────────────────────────────────────────

def run_backup() -> dict:
    folder_id = os.getenv("GDRIVE_FOLDER_ID")
    if not folder_id:
        raise RuntimeError("GDRIVE_FOLDER_ID not set in environment")

    db_url = os.getenv("DATABASE_URL", "")
    try:
        without_scheme = db_url.split("://", 1)[1]
        userpass, hostpart = without_scheme.rsplit("@", 1)
        user, password = userpass.split(":", 1)
        hostport, dbname = hostpart.split("/", 1)
        host, port = (hostport.split(":", 1) + ["3306"])[:2]
    except Exception as e:
        raise RuntimeError(f"Cannot parse DATABASE_URL: {e}")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"pos_backup_{timestamp}.sql"

    backup_dir = Path(__file__).parent / "backups"
    backup_dir.mkdir(exist_ok=True)
    dump_path = str(backup_dir / filename)

    try:
        _python_dump(host, port, user, password, dbname, dump_path)
        drive_file_id = _upload(dump_path, filename, folder_id)
    finally:
        try:
            os.remove(dump_path)
        except Exception:
            pass

    return {"status": "ok", "filename": filename, "drive_file_id": drive_file_id}
