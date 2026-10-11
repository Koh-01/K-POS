# Restaurant POS System — Project Requirements and Architecture Document

> This document combines the complete functional requirements and technical architecture decisions as development context for Claude Code.
> Single-store operation, with an Android App (shared by Admin and Cashier) + Admin website (desktop reporting/management).

---

## 1. Technical Architecture Overview

```
Android App (Flutter)
├── Shows the Admin / Cashier interface according to the user’s role after login
├── Local SQLite (offline-first; caches products, tables, and orders pending sync)
└── Calls the FastAPI backend

FastAPI backend (deployed on Ubuntu Server with Docker, using the existing Cloudflare Tunnel)
├── Single business logic layer (tax rates/service charges/promotion calculations/permission checks)
├── Provides both:
│   ├── JSON API (for the Flutter App)
│   └── Jinja2 + Bootstrap website (for Admin, within the same project)
├── Automatically generated Swagger API documentation
└── Connects to MariaDB

MariaDB (single source of truth for all official data)
└── Daily scheduled backup → Google Drive
    └── Monthly report automatically generated on the 1st of each month and saved to Google Drive
```

### Three-Layer Data Architecture

```
POS App
  ↓
SQLite (local, offline-first)
  ↓ Sync
Ubuntu Server
  ↓
FastAPI (business logic)
  ↓
MariaDB (primary database)
  ↓ Automatic daily backup at 12:00
Google Drive (cloud backup)
```

| Layer | Purpose |
|---|---|
| Local SQLite | Continue creating orders, recording payments, and viewing products/tables without internet access |
| Server + MariaDB | Single source of truth for all official data, reports, products, users, and orders |
| Google Drive | Daily automatic backups and monthly reports |

### Key Architecture Decisions (and Reasons)

1. **The App and website do not connect directly to the database; both use FastAPI** — This prevents business logic (tax calculations and promotion rules) from being implemented separately and drifting apart.
2. **Use FastAPI instead of Flask** — The same API must serve both the App and website. FastAPI generates Swagger documentation automatically and includes Pydantic data validation, which helps validate monetary amounts and tax rates.
3. **Use server-side rendering (Jinja2 + Bootstrap) instead of React for the website** — The website is mainly for administration and report exports. The priority is to make it usable quickly rather than build complex interactions.
4. **DuitNow QR is only a payment method label**, with no payment provider API integration — The system records the method selected by the cashier. The QR code itself is a static image for the store’s account. Customers scan it to transfer money, and the cashier manually verifies receipt. **There are no transaction callbacks, automated reconciliation, or processing fees.**
5. **The Bluetooth printer is a Chinese-made thermal printer using the Bluetooth SPP protocol** — This protocol **supports Android only** and does not support iOS (iOS Bluetooth printing requires MFi-certified devices). This project only builds an Android App, so it is unaffected. Suggested Flutter packages are `blue_thermal_printer` or `print_bluetooth_thermal`.
6. **Single-store operation** — The cloud synchronization layer does not need data isolation between multiple stores.

---

## 2. Detailed Functional Requirements

### 2.1 User Management

- Login (Username / Password). **Users log in once and do not need to log in every time** (including on Cashier devices).
- Role-based permissions:
  - **Admin**: Can view reports — sales volume for each item by year/month/week/day.
  - **Cashier**: Handles daily ordering and checkout operations.
- Change password.
- Manage user profiles.
- Login logs.
- **Cashiers must be able to operate normally without internet access** (using local SQLite).
- Registration flow: Register the first Admin account → Admin adds Cashier accounts within the system.
- Cashier devices only need to log in once; daily login is not required.

### 2.2 Product Management

> Both Admin and Cashier can manage products. **Changes must sync promptly when both manage products at the same time** (concurrent writes require conflict handling).

- Add / edit / delete products.
- Manage product categories (Category), such as soup bases, meats, drinks, and side dishes.
- Upload product images.
- Manage product prices.
- Product status: Available / Unavailable.

### 2.3 Order Management

- Create orders — **save each order against its table**.
- Modify orders — edit contents / change tables.
- **Combine orders** — for example, if a customer occupies two tables, combine them into one order.
- Delete orders.
- Order notes.
- Dining method: Dine In / Take Away.

### 2.4 Payment Module

- Cash payment.
- DuitNow QR (payment method label only; see Architecture Decision #4).
- View orders for which payment has already been processed.
- **Delete / edit orders after payment has been processed**:
  - Deletion scenario: The cashier entered the wrong items and needs to recreate the entire order and reprint the receipt.
  - Editing scenario: The cashier can correct a small mistake directly and reprint the receipt.
  - ⚠️ An audit trail is required (record the content before modification, who made the change, and when) so changes to financial records remain traceable.
- Automatically calculate:
  - SST and Service Charge — **users can choose to enable or disable them**.
  - Subtotal.
  - Service Charge.
  - SST.
  - Discount — **show it on the receipt only when a discount actually applies**.
  - Grand Total.

### 2.5 Promotion Management

> Both Admin and Cashier can add / delete / edit promotion types and discount values.

- Discount %.
- Buy 1 Free 1.
- Happy Hour.
- Promo Code.

### 2.6 Reporting

> Support Export to CSV.

- Daily / weekly / monthly sales revenue.
- Best-selling products.
- **Cash In / Cash Out**: Record every inflow and expense.
- Automatically generate a monthly report: revenue / Cash In / Cash Out.
- **Generate an annual report for tax filing** — it must include:
  - Sales revenue for every day of the year.
  - All Cash In / Cash Out records for the year.
  - Sales revenue for every item for the year.

**Admin Dashboard:**
- Today's Revenue.
- Orders Today.
- Top Selling Product.
- Active Tables.

### 2.7 Receipt Printing

- Bluetooth Printer (Chinese-made thermal printer, SPP protocol):
  - Configurable receipt paper thickness.
  - Test Connection.
- Export to PDF.

**Receipt content (user-editable):**
- Store name.
- Order number.
- Product list.
- Tax information.
- Total amount.
- QR Code.

### 2.8 Cloud Sync

- Automatically save to Google Drive.
- Automatically generate a monthly report on the first day of each month and save it to Google Drive.
- Cloud sync: **Automatically back up once a day at 12:00**.
- Data backup.
- Multi-device sync.
- Offline Mode.
- Automatic recovery.

### 2.9 Settings

- Store information.
- Tax rate settings.
- Printer settings.
- Payment method settings.
- Theme switching (Dark / Light).

### 2.10 Data Retention Policy

- Every two years, clean up the previous year’s data from the database.
- When Google Drive backup storage is full, automatically delete old backups **and send a notification**.

---

## 3. Admin Website (Desktop)

- Full feature parity with the App (everything the App can do must also be available on the website).
- Only Admin users can log in.
- Primary use case: Export accounting data (CSV / PDF) from a computer.
- Assumes an internet connection; **offline mode is not required**.
- Technology: Jinja2 + Bootstrap pages within the FastAPI project, using the same business logic layer.

---

## 4. Development Phases

### Phase 0 — Foundation
- Design the database schema (keep MariaDB and SQLite structures aligned to simplify sync).
- Design the sync strategy (`updated_at` / `synced_at` / `device_id` and conflict resolution rules).
- Create the FastAPI project skeleton and connect it to the existing Ubuntu Server.
- Create the Flutter project skeleton.

### Phase 1 — Operational MVP
- Login (Admin / Cashier, persistent login, offline access).
- Product management (CRUD + categories).
- Ordering (create / edit orders, Dine In / Take Away, tables, combine orders).
- Checkout (Cash / DuitNow QR label; automatic Subtotal / SST / Service Charge / Discount calculations).
- Receipt printing (Bluetooth thermal printer integration).

### Phase 2 — Operational Enhancements
- Edit / delete paid orders (with audit records).
- Promotion management.
- Daily operations reporting (daily / weekly / monthly revenue and best-selling products).
- Admin Dashboard.

### Phase 3 — Cloud Backup and Tax Reporting
- Automatic Google Drive backup (daily at 12:00).
- Automatic monthly / annual report generation.
- Cash In / Cash Out recording.

### Phase 4 — Refinement
- System settings (store information / tax rates / printer / theme).
- Login logs.
- Automatic recovery after offline operation.
- Data retention policy (two-year cleanup and Google Drive storage-full notification).

---

## 5. Items Pending Design / Confirmation

- [ ] Detailed database schema (core tables: users, products, categories, tables, orders, order_items, payments, promotions, cash_records).
- [ ] Soft deletion rules (whether deleted products/orders are permanently removed or marked with a status to preserve auditability).
- [ ] Specific audit trail implementation for editing/deleting paid orders.
- [ ] SQLite ↔ MariaDB sync conflict rules (which change takes precedence when the same product is edited on two devices).
- [ ] ESC/POS command compatibility testing for the specific Bluetooth printer model.

---

## 6. Technology Stack Summary

| Layer | Technology |
|---|---|
| Mobile App | Flutter (Android, shared by Admin and Cashier) |
| Local storage | SQLite |
| Backend API | FastAPI (Python) |
| Website frontend | Jinja2 + Bootstrap (within the FastAPI project) |
| Primary database | MariaDB |
| Server | Existing Ubuntu Server 24.04 LTS (Docker deployment) |
| Remote access | Existing Cloudflare Tunnel configuration |
| Cloud backup | Google Drive |
| Printing | thermal printer, Bluetooth SPP protocol (Android only) |
