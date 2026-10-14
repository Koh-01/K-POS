# K POS

A restaurant point-of-sale system with an Android-first Flutter app, a FastAPI backend, and a browser-based admin dashboard. K POS supports everyday cashier operations, offline checkout, restaurant management, and sales reporting.

The system uses Malaysian Ringgit (MYR) and `Asia/Kuala_Lumpur` business time. Each restaurant has its own database, while authentication and restaurant discovery are handled by a shared control database.

## Features

- **Orders:** dine-in, takeaway, custom table names, table transfers, and bill splitting.
- **Catalogue:** categories, product images, quantity-based products, and products sold by weight.
- **Checkout:** cash, card, and DuitNow payment records, discounts, promotions, configurable service charge, and SST.
- **Printing:** PDF receipts, Android Bluetooth thermal receipts, and unpaid bills printed directly from the order screen.
- **Offline operations:** cached catalogue and settings, local order editing, checkout, cash records, and automatic synchronization when connectivity returns.
- **Administration:** Admin and Cashier accounts, configurable cashier permissions, login logs, and data retention tools.
- **Business records:** cash-in/cash-out tracking, receipt attachments, workers, salary payments, and salary slips.
- **Reports:** sales summaries, top products, annual reports, and CSV exports.
- **Backups:** optional Google Drive connections for each restaurant, scheduled backups, and monthly report uploads.

Card and DuitNow are recorded payment methods; the repository does not provide an integrated payment gateway.

## Repository Structure

```text
KTS-POS/
├── app/
│   ├── lib/core/             # API client, models, storage, and local database
│   ├── lib/features/         # Cashier, admin, payments, reports, and settings
│   ├── lib/shared/           # Shared widgets, theme, and utilities
│   ├── packages/             # Local printing and Bluetooth package overrides
│   └── test/                 # Flutter tests
├── backend/
│   ├── main.py               # FastAPI entry point and startup migrations
│   ├── models.py             # SQLAlchemy models
│   ├── schemas.py            # API request and response schemas
│   ├── tenant_database.py    # Restaurant database provisioning
│   ├── templates/            # Web admin templates
│   ├── static/               # Images and downloadable APK
│   └── tests/                # Backend tests
├── store-assets/             # Store listing assets
└── SYSTEM_OVERVIEW.md         # Architecture and offline behavior
```

## Requirements

- Python 3.11, matching the backend Docker image.
- A running MariaDB or MySQL server.
- Flutter with Dart compatible with `^3.11.5`, as specified in `app/pubspec.yaml`.
- Android SDK and JDK 17 for Android development.
- An Android device or emulator for the POS app. Bluetooth receipt printing requires a compatible physical printer and Android device.

## Backend Setup

Run the following from the repository root:

```sh
cd backend
python3 -m venv venv
source venv/bin/activate
python -m pip install -r requirements-dev.txt
cp .env.example .env
```

On Windows, activate the environment with `venv\Scripts\activate`.

### Configure the database and environment

Create an empty control database and an application database account before starting the backend. Grant that account the privileges needed to read/write data and create/alter tables in the control database. Restaurant databases are created by the provisioning connection.

Edit `backend/.env` with your own connection details and secrets:

```dotenv
DATABASE_URL=mysql+pymysql://kpos_app:YOUR_DB_PASSWORD@127.0.0.1:3306/kpos_control
TENANT_DATABASE_ADMIN_URL=mysql+pymysql://root:YOUR_ADMIN_PASSWORD@127.0.0.1:3306/kpos_control
TENANT_DATABASE_APP_USER=kpos_app
TENANT_DATABASE_APP_HOST=%

SECRET_KEY=YOUR_RANDOM_SECRET_AT_LEAST_32_CHARACTERS
SETUP_TOKEN=YOUR_SEPARATE_RANDOM_SETUP_SECRET

PUBLIC_BASE_URL=http://127.0.0.1:5001
WEB_COOKIE_SECURE=false
ENABLE_SCHEDULER=false
ENABLE_API_DOCS=true
```

Replace every placeholder. `TENANT_DATABASE_APP_HOST` must match the host component of the existing MySQL application account. URL-encode passwords containing special characters in database connection URLs.

The provisioning account must be able to create restaurant databases, grant the application user access, and copy seed data from the control database. Regular business queries use the application account. See [Multi-Restaurant Configuration](backend/MULTI_RESTAURANT.md) for the database layout and configuration details.

Generate each secret separately with:

```sh
python -c 'import secrets; print(secrets.token_urlsafe(48))'
```

The full configuration reference is [backend/.env.example](backend/.env.example). SMTP is needed for restaurant self-registration; Google Drive configuration is optional for local development.

### Start the API

From `backend/`, with the virtual environment active:

```sh
uvicorn main:app --host 127.0.0.1 --port 5001 --reload
```

Startup creates missing tables, applies compatibility migrations, and provisions restaurant databases. Check the startup logs for database or migration errors.

| Endpoint | Purpose |
| --- | --- |
| `http://127.0.0.1:5001/` | API status response |
| `http://127.0.0.1:5001/web/login` | Web admin sign-in |
| `http://127.0.0.1:5001/web/register` | Restaurant registration; requires SMTP |
| `http://127.0.0.1:5001/docs` | Interactive API docs when `ENABLE_API_DOCS=true` |

### Create the first admin

For a fresh local installation without SMTP, use the setup endpoint. Replace the setup token with the value in `.env` and choose your own password:

```sh
curl -X POST http://127.0.0.1:5001/setup/first-admin \
  -H 'Content-Type: application/json' \
  -H 'X-Setup-Token: YOUR_SEPARATE_RANDOM_SETUP_SECRET' \
  -d '{"username":"admin","password":"YOUR_ADMIN_PASSWORD","role":"admin","full_name":"Local Admin"}'
```

Passwords must contain at least eight characters. This endpoint creates an active admin for a default restaurant and rejects requests after any admin exists. Sign in with these credentials through the app or web admin.

For additional restaurants, configure `SMTP_*` and `PUBLIC_BASE_URL`, register through the app or `/web/register`, and verify the admin email. Each registered admin belongs to a separate restaurant. Admins create their restaurant's cashier accounts through user management.

## Run the Flutter App

From the repository root:

```sh
cd app
flutter pub get
flutter devices
flutter run --dart-define=API_BASE_URL=https://YOUR_BACKEND_HOST
```

Use an HTTPS backend URL reachable from the device. The Android manifest disables cleartext HTTP traffic, including for the current debug configuration. For local Android development, expose the local API through an HTTPS development proxy or tunnel. A device's `localhost` refers to the device itself.

The app defaults to the hosted backend configured in `app/lib/core/constants/api_constants.dart`. Override it with `API_BASE_URL` for your environment, or use **Change server URL** on the login screen. A saved server URL takes precedence over the build-time default.

To print receipts, pair a compatible Bluetooth SPP thermal printer with the Android device and select it in the app's Settings.

## Offline Behavior

The device must sign in and load the catalogue and settings online at least once. With a valid cached session, the app can create orders, edit cached open orders, record payments and cash movements, and print basic receipts while the API is unreachable.

Pending transactions are stored in SQLite. Synchronization retries every 30 seconds and when connectivity returns. UUID references make order, payment, and cash-record submissions idempotent; the server validates payment totals before accepting them. The cashier screen's pending action shows rejected entries and retry counts.

User management, catalogue changes, settings changes, promotions management, and reports require a server connection. A new promotion cannot be discovered offline; an already approved promotion in the current checkout preview can survive a connection loss. An expired cached token cannot restore an offline session.

See [System Overview](SYSTEM_OVERVIEW.md) for the complete checkout and synchronization behavior.

## Development Checks

Backend, from the repository root:

```sh
cd backend
source venv/bin/activate
python -m pytest -q tests
```

Flutter, from the repository root:

```sh
cd app
flutter analyze lib test
flutter test
flutter build apk --debug --dart-define=API_BASE_URL=https://YOUR_BACKEND_HOST
```

The debug APK is written to `app/build/app/outputs/flutter-apk/app-debug.apk`.

## Android Releases

Configure `app/android/key.properties` and your release keystore before distributing the app. The build configuration falls back to the debug signing key when `key.properties` is absent, so verify release signing before publishing an APK. Keep the signing files private and backed up so future updates use the same key.

Update `version:` in `app/pubspec.yaml`, then run from the repository root:

```sh
cd app
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR_BACKEND_HOST
cp build/app/outputs/flutter-apk/app-release.apk ../backend/static/downloads/kts-pos.apk
```

The backend serves this APK at `/static/downloads/kts-pos.apk`. If using the backend Docker image, rebuild and redeploy it to include the updated APK.

## Deployment Notes

- Set a persistent, strong `SECRET_KEY`, use HTTPS, and set `WEB_COOKIE_SECURE=true`.
- Disable interactive API docs in production with `ENABLE_API_DOCS=false`.
- Keep database credentials, `.env`, OAuth tokens, and signing keys outside version control.
- Persist uploaded files under `backend/static/images/` and `backend/static/receipts/`, and back up both the control database and restaurant databases.
- Take a full database backup before upgrading an existing single-restaurant installation; startup can migrate its data into a restaurant database.
- Enable scheduled jobs with `ENABLE_SCHEDULER=true` when backup integrations are configured. Run only one scheduler instance to avoid duplicate jobs.

With Google Drive configured, each connected restaurant receives a daily JSON backup at 12:00 and a report for the previous month on the first day of the month at 01:00, in Malaysia time. Restaurant admins connect their own Google account through **Web Admin → Settings → Google Drive**. The operator backup uses a separate Drive token and folder configuration.
