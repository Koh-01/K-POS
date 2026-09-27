# KTS POS system overview

## Runtime architecture

- `app/` is the Flutter POS client. Riverpod owns session, cart, catalogue,
  settings, open-order and payment state. Dio talks to the API and SQLite
  stores the offline catalogue and retry queues.
- `backend/` is a FastAPI application. SQLAlchemy persists operational data in
  MariaDB, Jinja templates provide the admin web UI, and APScheduler runs daily
  backups and monthly reports.
- Malaysia time (`Asia/Kuala_Lumpur`) is the business time used by database
  sessions, reports, promotions and scheduled work.

## Checkout paths

Online checkout writes the order and payment directly. A UUID supplied as
`offline_ref` makes payment and cash-record submission idempotent, including
the case where the server committed but the device lost the response.

Offline checkout uses four durable SQLite queues:

1. New orders are stored with table/custom-table data, price snapshots,
   quantities and weights.
2. Edits to an already-synced open order are stored separately by server order
   ID.
3. Payments retain the complete amount snapshot: subtotal, discount,
   promotion, service charge, SST, payment method, tendered cash and device
   timestamp.
4. Cash-in/cash-out records and an optional local receipt path are queued.

The app retries every 30 seconds and immediately after connectivity returns.
Order IDs are mapped transactionally before payments retry, so a successful
order upload followed by a failed payment upload cannot orphan the payment.
The orange `pending` action on the cashier screen shows rejected rows and their
retry count.

Cashiers can also print an unpaid bill directly from the order screen without
entering checkout. It uses the same cached SST/service-charge calculation and
is marked `BILL - NOT PAID` / `NOT A PAYMENT RECEIPT`; it never creates a
payment or changes the order to paid. On the Android POS device it is sent only
to the Bluetooth thermal printer saved in Settings, reconnecting automatically
when needed; it never opens a browser or PDF print dialog.

The server recalculates the order subtotal, charges and tax before accepting an
offline payment. A promotion captured by an online preview is revalidated at
the device checkout time. Duplicate UUIDs return the original record instead
of creating another payment or cash movement.

## Offline operating requirements

The device must have logged in and loaded the catalogue/settings online at
least once. While offline it can create dine-in, custom-table and takeaway
orders, sell quantity or weighted products, accept cash/card/DuitNow, calculate
cached SST/service charge, print a basic receipt, and queue cash records.

Creating or changing users, catalogue data, promotions, reports and settings
still requires the server. A promotion cannot be newly discovered while fully
offline; only a promotion already approved in the current checkout preview can
survive a connection loss.

## Security and data integrity

- Disabled users are rejected on every authenticated server request; expired
  cached JWTs cannot restore an offline session.
- Admin report and table-management APIs enforce role checks.
- Web mutation requests enforce same-origin checks, login attempts are rate
  limited, and the session cookie is HTTP-only, secure and SameSite=Lax.
- Initial admin creation requires the `X-Setup-Token` header. The token comes
  from `SETUP_TOKEN` and the endpoint disables itself after the first admin.
- Image uploads are decoded with a 10 MB / 40 MP safety limit and resized.
  Existing files are removed only after the replacement is saved and committed.
- If a configured JWT signing secret is too short, the backend creates a
  private persistent 64-byte-class secret at `backend/.jwt_secret`; production
  should still configure a strong `SECRET_KEY` explicitly.

## Deployment and verification

On backend startup, compatibility migrations create missing tables and columns
independently so one legacy difference does not skip later migrations. The
current live database has the payment/cash `offline_ref` columns required by
the new sync protocol.

Useful checks:

```sh
cd backend
./venv/bin/python -m pytest -q tests

cd ../app
flutter analyze lib test
flutter test
flutter build apk --debug
```

After deploying the backend, restart it before installing the new APK. Because
the old signing secret was weak, the first restart may require users to sign in
again; queued SQLite transactions remain on the device.
