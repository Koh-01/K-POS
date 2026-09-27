# K POS multi-restaurant database layout

K POS uses database-per-restaurant isolation.

## Control database

`DATABASE_URL` points to the control database. It is the authoritative source
for:

- `restaurants` and each restaurant's physical database name
- Admin and Cashier accounts (`users`)
- email verification tokens
- login audit records

Admin email addresses and Cashier usernames are globally unique here, so login
can resolve a restaurant without asking for a restaurant code.

## Restaurant databases

Each restaurant receives a MariaDB database named like
`kpos_r_12_restaurant_slug`. It contains that restaurant's products,
categories, tables, orders, payments, promotions, cash records, workers,
salaries, settings and audit history. Requests are routed to this database only
after the authenticated account has resolved its restaurant.

Rows still carry `restaurant_id` as a second isolation check. A SQLAlchemy
session is not allowed to switch restaurants, preventing identity-map leakage
between databases.

## Required production configuration

```dotenv
DATABASE_URL=mysql+pymysql://kpos_app:password@db:3306/kpos_control
TENANT_DATABASE_ADMIN_URL=mysql+pymysql://root:root-password@db:3306/kpos_control
TENANT_DATABASE_APP_USER=kpos_app
TENANT_DATABASE_APP_HOST=%

PUBLIC_BASE_URL=https://pos.example.com
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=...
SMTP_PASSWORD=...
SMTP_FROM=K POS <no-reply@example.com>
SMTP_USE_TLS=true
SMTP_USE_SSL=false
```

The privileged database URL is used only to create a restaurant database and
grant the normal application user access. Normal POS queries continue to use
the less-privileged `DATABASE_URL` account.

## Google Drive backups and monthly reports

Each restaurant saves its own data to **its own** Google Drive:

- The restaurant Admin opens Web Admin → Settings → Google Drive and clicks
  **Connect Google Drive**. K POS creates a `K POS – <restaurant>` folder in
  that account.
- Every day at 12:00 a JSON backup of that restaurant, and on the 1st of each
  month last month's sales report (CSV), are uploaded to that folder. The
  Admin can also trigger both from the app (Admin Tools).
- Restaurants that have not connected Drive are skipped. Their data is never
  uploaded to the operator's Drive.
- The `drive.file` scope only lets K POS see files it created. The refresh
  token is stored encrypted in the control database (`restaurant_drive_connections`),
  using a key derived from `SECRET_KEY`. If `SECRET_KEY` changes, every
  restaurant has to reconnect.

The operator's full database dump (all restaurants) still goes to
`GDRIVE_FOLDER_ID` using `token.json`.

### One-time Google Cloud setup (operator)

1. Google Cloud Console → APIs & Services → enable **Google Drive API**.
2. OAuth consent screen: User type **External**, add the `.../auth/drive.file`
   scope, then **Publish app** (In production). In "Testing" mode, only listed
   test users can connect, and their tokens expire after 7 days.
3. Credentials → Create OAuth client ID → **Web application**. Authorized
   redirect URI: `{PUBLIC_BASE_URL}/web/settings/google-drive/callback`
   (for example `https://htd5110-ktspos.koh01.com/web/settings/google-drive/callback`).
4. Put the client ID and secret into `.env`:

```dotenv
GOOGLE_OAUTH_CLIENT_ID=xxxx.apps.googleusercontent.com
GOOGLE_OAUTH_CLIENT_SECRET=...
PUBLIC_BASE_URL=https://htd5110-ktspos.koh01.com
```

## Existing single-restaurant migration

At startup, the idempotent migration:

1. creates a control-plane restaurant for existing data;
2. adds and fills `restaurant_id` on legacy rows;
3. creates the restaurant's physical database;
4. copies existing business rows in foreign-key-safe order; and
5. routes all future business traffic to that database.

The original business tables remain in the control database as a migration
archive. They are no longer used for authenticated business traffic. A full
database backup must be taken before first deployment.

## Android APK release

The download page serves `backend/static/downloads/kts-pos.apk`. Always ship a
**release** build there, never `app-debug.apk` (debug builds are ~3x larger,
run in JIT mode and show a DEBUG banner).

Release builds are signed with the upload key in `app/android/upload-keystore.jks`,
configured through `app/android/key.properties`. Both files are git-ignored.
Keep an offline backup of them: Android refuses to install an update signed
with a different key, so losing the keystore means every device must uninstall
and reinstall the app.

```bash
cd app
flutter build apk --release        # API_BASE_URL defaults to production
cp build/app/outputs/flutter-apk/app-release.apk ../backend/static/downloads/kts-pos.apk
```

To target another server, add `--dart-define=API_BASE_URL=https://...`.
Bump `version:` in `app/pubspec.yaml` before each release so devices accept
the update. Rebuild and redeploy the backend container afterwards so the new
file is served.
