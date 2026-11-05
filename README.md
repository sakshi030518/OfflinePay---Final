# OfflinePay — source package

Flutter Android app + FastAPI backend + PostgreSQL (Neon-compatible) + on-device
SQLite. This package is cleaned of Git history, virtual environments, `.env`
secrets, test private keys, and Android signing keys.

> **Important status note:** this is a cleaned source package based on the
> uploaded project, with a small sync transport fix and Android demo-build
> signing fallback. It has not been validated by a Flutter build or a two-phone
> end-to-end payment test. The current Flutter `ApiService` still performs
> registration/login locally and queues registration to `/auth/sync-registration`,
> but the supplied FastAPI backend does not implement that endpoint. Therefore
> do not treat this archive as a verified, fully working release. The steps below
> prepare the project; the auth/device/allowance integration still needs to be
> completed and tested before relying on payment flow.

## Project layout

- `frontend/offlinepay/` — Flutter app and Android project
- `backend/app/` — FastAPI routes, authentication, SQLAlchemy models, Dummy Bank,
  device/allowance/payment synchronization services
- `backend/.env.example` — backend environment template
- `database/README.md` — PostgreSQL / Neon setup
- `render.yaml` — Render deployment configuration

## 1. Database setup

Use PostgreSQL locally or Neon. See `database/README.md`. Backend startup calls
SQLAlchemy `Base.metadata.create_all()` to create tables. Existing schemas are
not automatically migrated.

## 2. Backend setup (Windows PowerShell)

```powershell
cd backend
Copy-Item .env.example .env
```

Edit `backend/.env` and set a real database URL and a long random `SECRET_KEY`.
Do not commit `.env` or share it publicly.

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

API docs: `http://127.0.0.1:8000/docs`.

## 3. Flutter setup

Install Flutter (stable), Android Studio and Android SDK. Then:

```powershell
cd frontend/offlinepay
flutter clean
flutter pub get
flutter analyze
flutter run
```

For Android emulator use `http://10.0.2.2:8000` as the API host. For a physical
phone, set `baseUrl` in `lib/config/api_config.dart` to a reachable HTTPS Render
URL or your computer's LAN IP (both phones must be on the same Wi-Fi for a local
backend).

To build a demo APK:

```powershell
flutter build apk --release
```

The Android Gradle file uses debug signing for a local demo release build only.
For Play Store distribution, create and protect your own release keystore and
configure signing locally. Never share the keystore or its passwords.

## 4. Current intended payment flow

Merchant payment request QR → customer payment QR → merchant ACK QR → customer
scans ACK → local transaction record → pending synchronization → backend verifies
and settles the simulated Dummy Bank ledger when internet returns.

## 5. Required integration work before calling this fully working

1. Implement and test the backend `/auth/sync-registration` endpoint, or change
   the frontend to use the existing online `/auth/signup` and `/auth/login`
   endpoints. The current frontend is local-first and does not match the
   backend's online signup/login contract.
2. Complete online device registration and customer allowance provisioning
   after server-side account creation. Confirm that the same persistent device
   ID and public key are used by API registration and QR signing.
3. Cache trusted merchant public keys and verify the merchant ACK signature on
   the customer phone before recording a debit. The current scanner validates
   ACK fields against the saved payment but does not establish this trust check.
4. Test server-side allowance creation, expiry parsing, QR time limits, duplicate
   protection, provisional merchant credits and reconciliation on both phones.
5. Run `flutter analyze`, build the APK, deploy the backend, and test the complete
   flow on two real Android devices with airplane mode enabled between setup and
   payment, then reconnect and verify settlement in PostgreSQL.

## Safety / demo scope

OfflinePay is an educational prototype using simulated Dummy Bank balances. A
merchant's offline credit is provisional until the server confirms settlement.
It is not a real payment system, does not move real money, and is not approved
for production financial use.
