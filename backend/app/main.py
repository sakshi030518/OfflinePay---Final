from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4
import os
import smtplib

from email.message import EmailMessage

from fastapi import (
    FastAPI,
    Depends,
    HTTPException,
    status,
)

from fastapi.security import (
    HTTPBearer,
    HTTPAuthorizationCredentials,
)

from sqlalchemy.orm import Session
from sqlalchemy import or_

from .database import Base, engine, get_db

from .models import (
    User,
    Wallet,
    Transaction,
    BankAccount,
    BankLedger,
    Device,
    OfflineAllowance,
)

from .schemas import (
    SignupRequest,
    LoginRequest,
    TokenResponse,
    PaymentData,
    SyncPaymentRequest,
    ForgotPasswordRequest,
    ResetPasswordRequest,
    DeviceRegisterRequest,
    DeviceResponse,
    OfflineAllowanceRequest,
    OfflineAllowanceResponse,
)

from .auth import (
    hash_password,
    verify_password,
    create_access_token,
    decode_token,
    create_password_reset_token,
)

from .bank_service import (
    create_bank_account,
    get_bank_account,
    get_available_balance,
)

from .email_service import send_welcome_email
from .sync_service import synchronize_payment
from .device_service import register_device


# ==================================================
# DATABASE AND APPLICATION
# ==================================================

Base.metadata.create_all(bind=engine)

app = FastAPI(
    title="OfflinePay API",
    description="Offline-first QR payment application backend",
    version="1.0.0",
)

security = HTTPBearer()


# ==================================================
# COMMON HELPERS
# ==================================================

def decimal_money(value) -> Decimal:
    return Decimal(str(value)).quantize(
        Decimal("0.01")
    )


def rollback_safely(db: Session):
    try:
        db.rollback()
    except Exception:
        pass


# ==================================================
# AUTHENTICATED USER
# ==================================================

def get_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    try:
        token = credentials.credentials
        claims = decode_token(token)

        if claims.get("type", "access") != "access":
            raise ValueError("Wrong token type")

        uid = claims["sub"]

    except Exception:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
        )

    user = (
        db.query(User)
        .filter(User.user_id == uid)
        .first()
    )

    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found",
        )

    return user


# ==================================================
# ROOT
# ==================================================

@app.get("/")
def root():
    return {
        "message": "OfflinePay backend is running",
        "status": "active",
        "version": "1.0.0",
    }


@app.get("/health")
def health():
    return {
        "status": "healthy",
        "service": "OfflinePay API",
    }


# ==================================================
# SIGNUP
# ==================================================

@app.post(
    "/auth/signup",
    response_model=TokenResponse,
    status_code=status.HTTP_201_CREATED,
)
def signup(
    x: SignupRequest,
    db: Session = Depends(get_db),
):
    role = x.role.lower().strip()

    if role not in ("customer", "merchant"):
        raise HTTPException(
            status_code=400,
            detail="Invalid role",
        )

    email = str(x.email).lower().strip()
    phone = x.phone.strip()


    existing_user = (
        db.query(User)
        .filter(
            or_(
                User.email == email,
                User.phone == phone,
            )
        )
        .first()
    )

    if existing_user:
        raise HTTPException(
            status_code=409,
            detail="An account with this email or phone number already exists."
        )

    uid = "USR-" + uuid4().hex[:12].upper()

    user = User(
        user_id=uid,
        name=x.name.strip(),
        phone=phone,
        email=email,
        password_hash=hash_password(x.password),
        role=role,
    )

    wallet = Wallet(
        wallet_id="WAL-" + uuid4().hex[:12].upper(),
        user_id=uid,
        balance=0,
    )

    try:
        db.add_all([user, wallet])
        db.flush()

        bank_account = create_bank_account(
            db=db,
            user_id=uid,
            account_holder=user.name,
        )

        account_number = bank_account.account_number
        opening_balance = decimal_money(bank_account.balance)

        # User, wallet, bank account and opening ledger
        # entry are saved in one database transaction.
        db.commit()

        db.refresh(user)

    except Exception as exc:
        rollback_safely(db)

        print(f"Signup error: {exc}")

        raise HTTPException(
            status_code=500,
            detail="Registration failed. Please try again.",
        )

    # Email failure must not make a successfully created
    # account appear to have failed registration.
    try:
        send_welcome_email(
            recipient=user.email,
            account_holder=user.name,
            account_number=account_number,
            opening_balance=f"{opening_balance:.2f}",
        )
    except Exception as exc:
        print(f"Welcome email error: {exc}")

    return TokenResponse(
        access_token=create_access_token(uid),
        token_type="bearer",
        user_id=uid,
        role=role,
        name=user.name,
    )


# ==================================================
# LOGIN
# ==================================================

@app.post(
    "/auth/login",
    response_model=TokenResponse,
)
def login(
    x: LoginRequest,
    db: Session = Depends(get_db),
):
    email = str(x.email).lower().strip()

    user = (
        db.query(User)
        .filter(User.email == email)
        .first()
    )

    if not user or not verify_password(
        x.password,
        user.password_hash,
    ):
        raise HTTPException(
            status_code=401,
            detail="Invalid email or password",
        )

    return TokenResponse(
        access_token=create_access_token(user.user_id),
        token_type="bearer",
        user_id=user.user_id,
        role=user.role,
        name=user.name,
    )


# ==================================================
# PASSWORD RESET EMAIL
# ==================================================

def send_reset_email(
    recipient: str,
    reset_token: str,
) -> None:

    host = os.getenv("SMTP_HOST", "").strip()
    username = os.getenv("SMTP_USERNAME", "").strip()
    password = os.getenv("SMTP_PASSWORD", "").strip()
    sender = os.getenv("SMTP_FROM", username).strip()

    if not all([host, username, password, sender]):
        raise RuntimeError(
            "Password reset email is not configured."
        )

    message = EmailMessage()

    message["Subject"] = "OfflinePay password reset"
    message["From"] = sender
    message["To"] = recipient

    message.set_content(
        "A password reset was requested for your OfflinePay account.\n\n"
        "Copy the reset token into the OfflinePay app's "
        "Reset Password screen. It expires in 30 minutes.\n\n"
        f"Reset token:\n{reset_token}\n"
    )

    port = int(os.getenv("SMTP_PORT", "587"))

    with smtplib.SMTP(host, port, timeout=15) as server:
        server.ehlo()

        if os.getenv("SMTP_USE_TLS", "true").lower() == "true":
            server.starttls()
            server.ehlo()

        server.login(username, password)
        server.send_message(message)


# ==================================================
# FORGOT PASSWORD
# ==================================================

@app.post("/auth/forgot-password")
def forgot_password(
    x: ForgotPasswordRequest,
    db: Session = Depends(get_db),
):
    email = str(x.email).lower().strip()

    user = (
        db.query(User)
        .filter(User.email == email)
        .first()
    )

    if user:
        try:
            reset_token = create_password_reset_token(
                user.user_id,
                user.email,
            )

            send_reset_email(
                user.email,
                reset_token,
            )

        except Exception as exc:
            print(f"Password reset email error: {exc}")

            raise HTTPException(
                status_code=503,
                detail=(
                    "Password reset email could not be sent. "
                    "Contact the app administrator."
                ),
            )

    return {
        "message": (
            "If an account exists for that email, "
            "reset instructions have been sent."
        )
    }


# ==================================================
# RESET PASSWORD
# ==================================================

@app.post("/auth/reset-password")
def reset_password(
    x: ResetPasswordRequest,
    db: Session = Depends(get_db),
):
    try:
        claims = decode_token(x.token)

        if claims.get("type") != "password_reset":
            raise ValueError("Wrong token type")

        user_id = claims["sub"]
        email = claims["email"]

    except Exception:
        raise HTTPException(
            status_code=400,
            detail="Reset token is invalid or expired. Request a new one.",
        )

    user = (
        db.query(User)
        .filter(
            User.user_id == user_id,
            User.email == email,
        )
        .first()
    )

    if not user:
        raise HTTPException(
            status_code=400,
            detail="Reset token is invalid or expired. Request a new one.",
        )

    try:
        user.password_hash = hash_password(x.new_password)
        db.commit()

    except Exception as exc:
        rollback_safely(db)
        print(f"Password update error: {exc}")

        raise HTTPException(
            status_code=500,
            detail="Unable to update password.",
        )

    return {
        "message": "Password updated. Please log in with your new password."
    }


# ==================================================
# CURRENT USER
# ==================================================

@app.get("/users/me")
def me(
    user: User = Depends(get_user),
):
    return {
        "user_id": user.user_id,
        "name": user.name,
        "email": user.email,
        "phone": user.phone,
        "role": user.role,
    }


# ==================================================
# DEVICE REGISTRATION
# ==================================================

@app.post(
    "/devices/register",
    response_model=DeviceResponse,
)
def register_user_device(
    data: DeviceRegisterRequest,
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    try:
        device = register_device(
            db=db,
            user_id=user.user_id,
            device_id=data.device_id,
            device_name=data.device_name,
            public_key_pem=data.public_key,
            key_algorithm=data.key_algorithm,
        )

        db.commit()
        db.refresh(device)

        return device

    except ValueError as error:
        rollback_safely(db)

        raise HTTPException(
            status_code=400,
            detail=str(error),
        )

    except Exception as error:
        rollback_safely(db)

        print(f"Device registration error: {error}")

        raise HTTPException(
            status_code=500,
            detail="Unable to register device.",
        )


# ==================================================
# GET REGISTERED DEVICE PUBLIC KEY
# ==================================================

@app.get("/devices/{device_id}/public-key")
def get_device_public_key(
    device_id: str,
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    device = (
        db.query(Device)
        .filter(
            Device.device_id == device_id,
            Device.active.is_(True),
        )
        .first()
    )

    if not device:
        raise HTTPException(
            status_code=404,
            detail="Active registered device not found.",
        )

    return {
        "device_id": device.device_id,
        "user_id": device.user_id,
        "public_key": device.public_key,
        "key_algorithm": device.key_algorithm,
        "active": device.active,
    }


# ==================================================
# OFFLINE ALLOWANCE RESPONSE
# ==================================================

def allowance_response(allowance: OfflineAllowance):
    return {
        "allowance_id": allowance.allowance_id,
        "user_id": allowance.user_id,
        "device_id": allowance.device_id,
        "allowance_amount": decimal_money(
            allowance.allowance_amount
        ),
        "spent_amount": decimal_money(
            allowance.spent_amount
        ),
        "expires_at": allowance.expires_at.isoformat(),
        "active": allowance.active,
    }


# ==================================================
# CREATE OFFLINE ALLOWANCE
# ==================================================

@app.post(
    "/allowances/create",
    response_model=OfflineAllowanceResponse,
    status_code=201,
)
def create_allowance(
    data: OfflineAllowanceRequest,
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    amount = decimal_money(data.amount)

    if amount <= 0:
        raise HTTPException(
            status_code=400,
            detail="Allowance amount must be greater than zero.",
        )

    try:
        device = (
            db.query(Device)
            .filter(
                Device.device_id == data.device_id,
                Device.user_id == user.user_id,
                Device.active.is_(True),
            )
            .first()
        )

        if not device:
            raise HTTPException(
                status_code=400,
                detail="Register this device before requesting an offline allowance.",
            )

        account = (
            db.query(BankAccount)
            .filter(BankAccount.user_id == user.user_id)
            .with_for_update()
            .first()
        )

        if not account:
            raise HTTPException(
                status_code=404,
                detail="Bank account not found.",
            )

        if account.status != "ACTIVE":
            raise HTTPException(
                status_code=400,
                detail="Bank account is inactive.",
            )

        existing_allowances = (
            db.query(OfflineAllowance)
            .filter(
                OfflineAllowance.user_id == user.user_id,
                OfflineAllowance.device_id == data.device_id,
                OfflineAllowance.active.is_(True),
            )
            .with_for_update()
            .all()
        )

        # Compare all expiry timestamps as naive UTC, matching the
        # existing database convention used by this backend.
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        valid_allowance = None

        for existing in existing_allowances:
            expiry = existing.expires_at

            if expiry.tzinfo is not None:
                expiry = expiry.astimezone(timezone.utc).replace(tzinfo=None)

            if expiry > now:
                if valid_allowance is not None:
                    raise HTTPException(
                        status_code=409,
                        detail=(
                            "Multiple active allowances found for this device. "
                            "Manual review required."
                        ),
                    )
                valid_allowance = existing
                continue

            # Expired allowance: release only its unused reservation.
            unused = (
                decimal_money(existing.allowance_amount)
                - decimal_money(existing.spent_amount)
            )
            reserved_now = decimal_money(account.reserved_balance)

            if unused < 0 or unused > reserved_now:
                raise HTTPException(
                    status_code=409,
                    detail=(
                        "Reserved balance is inconsistent. "
                        "Manual review required."
                    ),
                )

            account.reserved_balance = reserved_now - unused
            existing.active = False

        # Reuse an unexpired allowance; never reserve its amount twice.
        if valid_allowance is not None:
            db.commit()
            db.refresh(valid_allowance)
            return allowance_response(valid_allowance)

        balance = decimal_money(account.balance)
        reserved = decimal_money(account.reserved_balance)
        available = balance - reserved

        if amount > available:
            raise HTTPException(
                status_code=400,
                detail=f"Insufficient available balance. Available: {available:.2f}",
            )

        validity_hours = int(
            os.getenv("OFFLINE_ALLOWANCE_VALIDITY_HOURS", "24")
        )

        if validity_hours <= 0:
            raise HTTPException(
                status_code=500,
                detail="Offline allowance validity must be positive.",
            )

        now = datetime.utcnow()

        allowance = OfflineAllowance(
            allowance_id="ALL-" + uuid4().hex[:20].upper(),
            user_id=user.user_id,
            device_id=data.device_id,
            allowance_amount=amount,
            spent_amount=Decimal("0.00"),
            expires_at=now + timedelta(hours=validity_hours),
            active=True,
        )

        account.reserved_balance = reserved + amount

        db.add(allowance)
        db.commit()
        db.refresh(allowance)

        return allowance_response(allowance)

    except HTTPException:
        rollback_safely(db)
        raise

    except Exception as exc:
        rollback_safely(db)

        print(f"Offline allowance creation error: {exc}")

        raise HTTPException(
            status_code=500,
            detail="Unable to create offline allowance.",
        )


# ==================================================
# GET OFFLINE ALLOWANCE
# ==================================================

@app.get(
    "/allowances/{allowance_id}",
    response_model=OfflineAllowanceResponse,
)
def get_allowance(
    allowance_id: str,
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    allowance = (
        db.query(OfflineAllowance)
        .filter(
            OfflineAllowance.allowance_id == allowance_id,
            OfflineAllowance.user_id == user.user_id,
        )
        .first()
    )

    if not allowance:
        raise HTTPException(
            status_code=404,
            detail="Offline allowance not found.",
        )

    return allowance_response(allowance)


# ==================================================
# RELEASE OFFLINE ALLOWANCE
# ==================================================

@app.post("/allowances/{allowance_id}/release")
def release_allowance(
    allowance_id: str,
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    try:
        allowance = (
            db.query(OfflineAllowance)
            .filter(
                OfflineAllowance.allowance_id == allowance_id,
                OfflineAllowance.user_id == user.user_id,
            )
            .with_for_update()
            .first()
        )

        if not allowance:
            raise HTTPException(
                status_code=404,
                detail="Offline allowance not found.",
            )

        if not allowance.active:
            raise HTTPException(
                status_code=400,
                detail="Offline allowance is already inactive.",
            )

        account = (
            db.query(BankAccount)
            .filter(BankAccount.user_id == user.user_id)
            .with_for_update()
            .first()
        )

        if not account:
            raise HTTPException(
                status_code=404,
                detail="Bank account not found.",
            )

        allowance_amount = decimal_money(
            allowance.allowance_amount
        )

        spent_amount = decimal_money(
            allowance.spent_amount
        )

        unused_amount = allowance_amount - spent_amount

        reserved = decimal_money(
            account.reserved_balance
        )

        if unused_amount < 0 or reserved < unused_amount:
            raise HTTPException(
                status_code=409,
                detail="Reserved balance is inconsistent. Manual review is required.",
            )

        account.reserved_balance = reserved - unused_amount
        allowance.active = False

        db.commit()

        return {
            "allowance_id": allowance.allowance_id,
            "status": "RELEASED",
            "released_amount": f"{unused_amount:.2f}",
            "message": "Unused allowance released.",
        }

    except HTTPException:
        rollback_safely(db)
        raise

    except Exception as exc:
        rollback_safely(db)

        print(f"Offline allowance release error: {exc}")

        raise HTTPException(
            status_code=500,
            detail="Unable to release offline allowance.",
        )


# ==================================================
# OFFLINEPAY WALLET
# ==================================================

@app.get("/wallet")
def wallet(
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    wallet_data = (
        db.query(Wallet)
        .filter(Wallet.user_id == user.user_id)
        .first()
    )

    if not wallet_data:
        raise HTTPException(
            status_code=404,
            detail="Wallet not found.",
        )

    return {
        "user_id": user.user_id,
        "balance": wallet_data.balance,
    }


# ==================================================
# SIMULATED BANK ACCOUNT
# ==================================================

@app.get("/bank/account")
def bank_account_details(
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    account = get_bank_account(
        db,
        user.user_id,
    )

    if not account:
        raise HTTPException(
            status_code=404,
            detail="Bank account not found.",
        )

    return {
        "account_number": account.account_number,
        "account_holder": account.account_holder,
        "account_type": account.account_type,
        "balance": str(account.balance),
        "reserved_balance": str(account.reserved_balance),
        "available_balance": str(
            get_available_balance(account)
        ),
        "status": account.status,
        "currency": "INR",
        "simulation": True,
    }


# ==================================================
# INITIALIZE BANK ACCOUNT
# ==================================================

@app.post("/bank/account/initialize")
def initialize_bank_account(
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    existing_account = get_bank_account(
        db,
        user.user_id,
    )

    if existing_account:
        return {
            "message": "Bank account already exists.",
            "account_number": existing_account.account_number,
            "balance": str(existing_account.balance),
        }

    try:
        account = create_bank_account(
            db=db,
            user_id=user.user_id,
            account_holder=user.name,
        )

        db.commit()
        db.refresh(account)

        return {
            "message": "Bank account created successfully.",
            "account_number": account.account_number,
            "account_holder": account.account_holder,
            "balance": str(account.balance),
            "reserved_balance": str(account.reserved_balance),
            "status": account.status,
            "currency": "INR",
            "simulation": True,
        }

    except Exception as exc:
        rollback_safely(db)

        print(f"Bank account initialization error: {exc}")

        raise HTTPException(
            status_code=500,
            detail="Unable to initialize bank account.",
        )


# ==================================================
# SIMULATED BANK STATEMENT
# ==================================================

@app.get("/bank/statement")
def bank_statement(
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    account = get_bank_account(
        db,
        user.user_id,
    )

    if not account:
        raise HTTPException(
            status_code=404,
            detail="Bank account not found.",
        )

    entries = (
        db.query(BankLedger)
        .filter(BankLedger.user_id == user.user_id)
        .order_by(BankLedger.created_at.desc())
        .all()
    )

    return [
        {
            "transaction_id": entry.transaction_id,
            "entry_type": entry.entry_type,
            "amount": str(entry.amount),
            "balance_after": str(entry.balance_after),
            "description": entry.description,
            "reference_number": entry.reference_number,
            "status": entry.status,
            "created_at": (
                entry.created_at.isoformat()
                if entry.created_at
                else None
            ),
        }
        for entry in entries
    ]


# ==================================================
# LEGACY WALLET SETTLEMENT
# ==================================================

@app.post("/transactions/complete")
def complete(
    x: PaymentData,
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    """
    Legacy unsigned settlement is intentionally disabled.

    All new payments must use /transactions/sync,
    which verifies both Ed25519 signatures and the
    device-bound offline allowance.
    """

    raise HTTPException(
        status_code=410,
        detail=(
            "Legacy wallet settlement is disabled. "
            "Use the secure offline payment synchronization endpoint."
        ),
    )


# ==================================================
# OFFLINE PAYMENT SYNCHRONIZATION
# ==================================================

@app.post("/transactions/sync")
def sync(
    x: SyncPaymentRequest,
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    if user.user_id not in (
        x.customer_id,
        x.merchant_id,
    ):
        raise HTTPException(
            status_code=403,
            detail="Not a transaction participant.",
        )

    try:
        result = synchronize_payment(
            db=db,
            payment=x,
            authenticated_user_id=user.user_id,
        )

        db.commit()

        return result

    except ValueError as exc:
        rollback_safely(db)

        raise HTTPException(
            status_code=400,
            detail=str(exc),
        )

    except Exception as exc:
        rollback_safely(db)

        print(f"Payment synchronization error: {exc}")

        raise HTTPException(
            status_code=500,
            detail="Payment synchronization failed.",
        )


# ==================================================
# TRANSACTION HISTORY
# ==================================================

@app.get("/transactions")
def transactions(
    user: User = Depends(get_user),
    db: Session = Depends(get_db),
):
    rows = (
        db.query(Transaction)
        .filter(
            or_(
                Transaction.customer_id == user.user_id,
                Transaction.merchant_id == user.user_id,
            )
        )
        .order_by(Transaction.created_at.desc())
        .all()
    )

    return [
        {
            "transaction_id": row.transaction_id,
            "request_id": row.request_id,
            "customer_id": row.customer_id,
            "merchant_id": row.merchant_id,
            "amount": row.amount,
            "status": row.status,
            "created_at": (
                row.created_at.isoformat()
                if row.created_at
                else None
            ),
        }
        for row in rows
    ]