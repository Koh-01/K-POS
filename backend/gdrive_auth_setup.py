"""
Run this ONCE to authorize Google Drive access.
It will open a browser for you to log in, then save token.json.
After that, gdrive_backup.py will use token.json automatically.

Usage:
    python gdrive_auth_setup.py
"""
from pathlib import Path
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
import json

SCOPES = ["https://www.googleapis.com/auth/drive.file"]
CLIENT_SECRET = Path(__file__).parent / "oauth_client_secret.json"
TOKEN_FILE = Path(__file__).parent / "token.json"


def main():
    if not CLIENT_SECRET.exists():
        print("ERROR: oauth_client_secret.json not found in backend/")
        print("Download it from Google Cloud Console → Credentials → OAuth 2.0 Client IDs")
        return

    flow = InstalledAppFlow.from_client_secrets_file(str(CLIENT_SECRET), SCOPES)
    creds = flow.run_local_server(port=0)

    with open(TOKEN_FILE, "w") as f:
        f.write(creds.to_json())

    print(f"✓ token.json saved to {TOKEN_FILE}")
    print("You can now run the backup via POST /admin/backup")


if __name__ == "__main__":
    main()
