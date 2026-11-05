import base64
import json

from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from uuid import uuid4

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from sqlalchemy.orm import Session

from .models import (
    User,
    Device,
    Transaction,
    BankAccount,
    BankLedger,
    OfflineAllowance,
)


# ==================================================
# CONFIGURATION
# ==================================================

CENT = Decimal("0.01")

# Maximum allowed time between customer payment QR
# creation and merchant acknowledgement QR creation.
QR_VALIDITY_SECONDS = 120


# ==================================================
# MONEY AND DATETIME HELPERS
# ==================================================

def money(value) -> Decimal:
    return Decimal(str(value)).quantize(
        CENT,
        rounding=ROUND_HALF_UP,
    )


def normalize_datetime(value: datetime) -> datetime:
    """Convert timestamps to timezone-aware UTC."""

    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)

    return value.astimezone(timezone.utc)


def timestamp_string(value: datetime) -> str:
    value = normalize_datetime(value)

    return value.isoformat(
        timespec="microseconds"
    ).replace("+00:00", "Z")


# ==================================================
# SIGNATURE MESSAGE CREATION
# IMPORTANT: Keep compatible with Flutter QrService.
# ==================================================

def create_payment_message(payment) -> bytes:
    fields = [
        "OFFLINEPAY_PAYMENT_V1",
        payment.transaction_id,
        payment.request_id,
        payment.customer_id,
        payment.merchant_id,
        format(money(payment.amount), ".2f"),
        payment.token,
        payment.allowance_id,
        payment.device_id,
        timestamp_string(payment.payment_created_at),
    ]

    return "\n".join(fields).encode("utf-8")


def create_acknowledgement_message(payment) -> bytes:
    fields = [
        "OFFLINEPAY_ACK_V1",
        payment.transaction_id,
        payment.request_id,
        payment.customer_id,
        payment.merchant_id,
        format(money(payment.amount), ".2f"),
        payment.token,
        payment.allowance_id,
        payment.device_id,
        payment.merchant_device_id,
        timestamp_string(payment.payment_created_at),
        timestamp_string(payment.acknowledgement_created_at),
        payment.payer_signature,
    ]

    return "\n".join(fields).encode("utf-8")


# ==================================================
# ED25519 SIGNATURE VERIFICATION
# ==================================================

def verify_signature(
    public_key_pem: str,
    signature_text: str,
    message: bytes,
) -> bool:

    try:
        public_key = serialization.load_pem_public_key(
            public_key_pem.encode("utf-8")
        )

        if not isinstance(public_key, Ed25519PublicKey):
            return False

        signature = base64.b64decode(
            signature_text,
            validate=True,
        )

        public_key.verify(signature, message)

        return True

    except (
        ValueError,
        TypeError,
        InvalidSignature,
    ):
        return False

    except Exception:
        return False


def verify_offline_signatures(
    db: Session,
    payment,
) -> None:

    payer_device = (
        db.query(Device)
        .filter(
            Device.device_id == payment.device_id,
            Device.user_id == payment.customer_id,
            Device.active.is_(True),
        )
        .first()
    )

    merchant_device = (
        db.query(Device)
        .filter(
            Device.device_id == payment.merchant_device_id,
            Device.user_id == payment.merchant_id,
            Device.active.is_(True),
        )
        .first()
    )

    if not payer_device:
        raise ValueError(
            "Customer device is not registered or active."
        )

    if not merchant_device:
        raise ValueError(
            "Merchant device is not registered or active."
        )

    if payer_device.key_algorithm != "Ed25519":
        raise ValueError("Unsupported customer key algorithm.")

    if merchant_device.key_algorithm != "Ed25519":
        raise ValueError("Unsupported merchant key algorithm.")

    payment_message = create_payment_message(payment)

    if not verify_signature(
        payer_device.public_key,
        payment.payer_signature,
        payment_message,
    ):
        raise ValueError(
            "Customer payment signature is invalid."
        )

    acknowledgement_message = (
        create_acknowledgement_message(payment)
    )

    if not verify_signature(
        merchant_device.public_key,
        payment.merchant_ack_signature,
        acknowledgement_message,
    ):
        raise ValueError(
            "Merchant acknowledgement signature is invalid."
        )


# ==================================================
# TRANSACTION DUPLICATE CHECK
# ==================================================

def get_existing_transaction(
    db: Session,
    payment,
):

    existing = (
        db.query(Transaction)
        .filter(
            Transaction.transaction_id == payment.transaction_id
        )
        .first()
    )

    if not existing:
        token_transaction = (
            db.query(Transaction)
            .filter(Transaction.token == payment.token)
            .first()
        )

        if token_transaction:
            raise ValueError(
                "Payment token has already been used."
            )

        return None

    same = (
        existing.request_id == payment.request_id
        and existing.customer_id == payment.customer_id
        and existing.merchant_id == payment.merchant_id
        and money(existing.amount) == money(payment.amount)
        and existing.token == payment.token
    )

    if not same:
        raise ValueError(
            "Transaction ID already exists with different payment details."
        )

    if existing.status != "COMPLETED":
        raise ValueError(
            "Transaction exists but is not completed. Manual review required."
        )

    return {
        "status": existing.status,
        "transaction_id": existing.transaction_id,
        "message": "Payment already synchronized.",
    }


# ==================================================
# TWO-MINUTE QR VALIDATION
# ==================================================

def validate_qr_timing(payment) -> None:
    """
    Enforce the maximum 2-minute interval between
    customer payment QR creation and merchant ACK creation.

    Internet synchronization can happen later. The
    offline handshake itself must have completed in time.
    """

    payment_time = normalize_datetime(
        payment.payment_created_at
    )

    acknowledgement_time = normalize_datetime(
        payment.acknowledgement_created_at
    )

    now = datetime.now(timezone.utc)

    if payment_time > now:
        raise ValueError(
            "Payment timestamp cannot be in the future."
        )

    if acknowledgement_time > now:
        raise ValueError(
            "Acknowledgement timestamp cannot be in the future."
        )

    if acknowledgement_time < payment_time:
        raise ValueError(
            "Acknowledgement cannot be created before payment."
        )

    elapsed = (
        acknowledgement_time - payment_time
    ).total_seconds()

    if elapsed > QR_VALIDITY_SECONDS:
        raise ValueError(
            "Payment QR expired. The merchant acknowledgement "
            "must be created within 2 minutes."
        )


# ==================================================
# OFFLINE ALLOWANCE VALIDATION
# ==================================================


def validate_allowance(
    db: Session,
    payment,
) -> OfflineAllowance:

    allowance = (
        db.query(OfflineAllowance)
        .filter(
            OfflineAllowance.allowance_id == payment.allowance_id
        )
        .with_for_update()
        .first()
    )

    if not allowance:
        raise ValueError("Offline allowance not found.")

    if allowance.user_id != payment.customer_id:
        raise ValueError(
            "Offline allowance does not belong to the customer."
        )

    if allowance.device_id != payment.device_id:
        raise ValueError(
            "Offline allowance is assigned to another device."
        )

    if not allowance.active:
        raise ValueError("Offline allowance is inactive.")

    payment_time = normalize_datetime(
        payment.payment_created_at
    )

    expiry_time = normalize_datetime(
        allowance.expires_at
    )

    if payment_time > expiry_time:
        raise ValueError(
            "Payment was created after the allowance expired."
        )

    amount = money(payment.amount)

    allowance_amount = money(
        allowance.allowance_amount
    )

    spent_amount = money(
        allowance.spent_amount
    )

    if spent_amount + amount > allowance_amount:
        raise ValueError(
            "Offline allowance limit exceeded."
        )

    return allowance


# ==================================================
# BANK ACCOUNT LOCKING
# ==================================================

def get_locked_bank_accounts(
    db: Session,
    customer_id: str,
    merchant_id: str,
):

    account_ids = sorted([
        customer_id,
        merchant_id,
    ])

    accounts = (
        db.query(BankAccount)
        .filter(
            BankAccount.user_id.in_(account_ids)
        )
        .order_by(BankAccount.user_id)
        .with_for_update()
        .all()
    )

    account_map = {
        account.user_id: account
        for account in accounts
    }

    payer_account = account_map.get(customer_id)
    merchant_account = account_map.get(merchant_id)

    if not payer_account:
        raise ValueError(
            "Customer bank account not found."
        )

    if not merchant_account:
        raise ValueError(
            "Merchant bank account not found."
        )

    if payer_account.status != "ACTIVE":
        raise ValueError(
            "Customer bank account is inactive."
        )

    if merchant_account.status != "ACTIVE":
        raise ValueError(
            "Merchant bank account is inactive."
        )

    return payer_account, merchant_account


# ==================================================
# BANK LEDGER ENTRIES
# ==================================================

def create_bank_entries(
    db: Session,
    payment,
    payer_account: BankAccount,
    merchant_account: BankAccount,
    amount: Decimal,
):

    debit_entry = BankLedger(
        transaction_id=payment.transaction_id,
        user_id=payment.customer_id,
        entry_type="DEBIT",
        amount=amount,
        balance_after=money(payer_account.balance),
        description="OfflinePay payment debit",
        reference_number="SYNC-" + uuid4().hex.upper(),
        status="COMPLETED",
    )

    credit_entry = BankLedger(
        transaction_id=payment.transaction_id,
        user_id=payment.merchant_id,
        entry_type="CREDIT",
        amount=amount,
        balance_after=money(merchant_account.balance),
        description="OfflinePay payment credit",
        reference_number="SYNC-" + uuid4().hex.upper(),
        status="COMPLETED",
    )

    db.add_all([
        debit_entry,
        credit_entry,
    ])


# ==================================================
# MAIN PAYMENT SYNCHRONIZATION
# ==================================================

def synchronize_payment(
    db: Session,
    payment,
    authenticated_user_id: str,
):

    if authenticated_user_id not in (
        payment.customer_id,
        payment.merchant_id,
    ):
        raise ValueError(
            "Authenticated user is not a payment participant."
        )

    if payment.customer_id == payment.merchant_id:
        raise ValueError(
            "Customer and merchant cannot be the same user."
        )

    amount = money(payment.amount)

    if amount <= 0:
        raise ValueError(
            "Payment amount must be greater than zero."
        )

    # Verify QR handshake timing.
    validate_qr_timing(payment)

    # Both device signatures must be valid.
    verify_offline_signatures(
        db,
        payment,
    )

    # Prevent duplicate transaction and token usage.
    existing = get_existing_transaction(
        db,
        payment,
    )

    if existing:
        return existing

    customer = (
        db.query(User)
        .filter(User.user_id == payment.customer_id)
        .first()
    )

    merchant = (
        db.query(User)
        .filter(User.user_id == payment.merchant_id)
        .first()
    )

    if not customer or not merchant:
        raise ValueError(
            "Invalid customer or merchant."
        )

    if customer.role != "customer":
        raise ValueError(
            "Payment sender is not a customer account."
        )

    if merchant.role != "merchant":
        raise ValueError(
            "Payment receiver is not a merchant account."
        )

    # Validate the device-bound offline allowance.
    allowance = validate_allowance(
        db,
        payment,
    )

    # Lock both accounts to prevent concurrent settlements.
    payer_account, merchant_account = (
        get_locked_bank_accounts(
            db,
            payment.customer_id,
            payment.merchant_id,
        )
    )

    payer_balance = money(
        payer_account.balance
    )

    payer_reserved = money(
        payer_account.reserved_balance
    )

    allowance_remaining = (
        money(allowance.allowance_amount)
        - money(allowance.spent_amount)
    )

    available_reserved = min(
        payer_reserved,
        allowance_remaining,
    )

    if available_reserved < amount:
        raise ValueError(
            "Insufficient reserved bank balance."
        )

    if payer_balance < amount:
        raise ValueError(
            "Insufficient bank balance."
        )

    # ==================================================
    # ATOMIC SIMULATED BANK SETTLEMENT
    # ==================================================

    payer_account.balance = money(
        payer_balance - amount
    )

    payer_account.reserved_balance = money(
        payer_reserved - amount
    )

    merchant_account.balance = money(
        money(merchant_account.balance) + amount
    )

    allowance.spent_amount = money(
        money(allowance.spent_amount) + amount
    )

    # Record the transaction.
    transaction = Transaction(
        transaction_id=payment.transaction_id,
        request_id=payment.request_id,
        customer_id=payment.customer_id,
        merchant_id=payment.merchant_id,
        amount=float(amount),
        token=payment.token,
        status="COMPLETED",
        synced_at=datetime.utcnow(),
    )

    db.add(transaction)

    # Flush to make the transaction available for ledger FK.
    db.flush()

    # Create debit and credit ledger records.
    create_bank_entries(
        db=db,
        payment=payment,
        payer_account=payer_account,
        merchant_account=merchant_account,
        amount=amount,
    )

    db.flush()

    return {
        "status": "COMPLETED",
        "transaction_id": payment.transaction_id,
        "amount": str(amount),
        "message": "Payment synchronized successfully.",
    }