
import os
import secrets
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from sqlalchemy.orm import Session

from .models import BankAccount, OfflineAllowance


# --------------------------------------------------
# CONFIGURATION
# --------------------------------------------------

DEFAULT_ALLOWANCE_VALIDITY_HOURS = int(
    os.getenv("OFFLINE_ALLOWANCE_VALIDITY_HOURS", "24")
)

MONEY_PLACES = Decimal("0.01")


def money(value) -> Decimal:
    return Decimal(str(value)).quantize(MONEY_PLACES)


# --------------------------------------------------
# CREATE OFFLINE ALLOWANCE
# --------------------------------------------------

def create_offline_allowance(
    db: Session,
    user_id: str,
    device_id: str,
    amount: Decimal,
) -> OfflineAllowance:

    amount = money(amount)

    if amount <= 0:
        raise ValueError("Allowance amount must be positive")

    account = (
        db.query(BankAccount)
        .filter(BankAccount.user_id == user_id)
        .with_for_update()
        .first()
    )

    if not account:
        raise ValueError("Bank account not found")

    if account.status != "ACTIVE":
        raise ValueError("Bank account is not active")

    balance = money(account.balance)
    reserved = money(account.reserved_balance)

    available = balance - reserved

    if amount > available:
        raise ValueError("Insufficient available bank balance")

    # Prevent multiple active allowances on the same device.
    existing = (
        db.query(OfflineAllowance)
        .filter(
            OfflineAllowance.user_id == user_id,
            OfflineAllowance.device_id == device_id,
            OfflineAllowance.active.is_(True),
        )
        .with_for_update()
        .all()
    )

    for old in existing:
        expiry = old.expires_at

        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=timezone.utc)

        if expiry > datetime.now(timezone.utc):
            raise ValueError(
                "An active offline allowance already exists for this device"
            )

        # Release any unused reservation from an expired allowance.
        unused = money(
            old.allowance_amount
        ) - money(old.spent_amount)

        if unused > 0:
            account.reserved_balance = (
                money(account.reserved_balance) - unused
            )

        old.active = False

    # Reserve money for offline spending.
    account.reserved_balance = (
        money(account.reserved_balance) + amount
    )

    allowance = OfflineAllowance(
        allowance_id="ALL-" + secrets.token_hex(12).upper(),
        user_id=user_id,
        device_id=device_id,
        allowance_amount=amount,
        spent_amount=Decimal("0.00"),
        expires_at=(
            datetime.now(timezone.utc)
            + timedelta(hours=DEFAULT_ALLOWANCE_VALIDITY_HOURS)
        ),
        active=True,
    )

    db.add(allowance)
    db.flush()

    return allowance


# --------------------------------------------------
# GET ALLOWANCE
# --------------------------------------------------

def get_offline_allowance(
    db: Session,
    user_id: str,
    allowance_id: str,
) -> OfflineAllowance | None:

    return (
        db.query(OfflineAllowance)
        .filter(
            OfflineAllowance.allowance_id == allowance_id,
            OfflineAllowance.user_id == user_id,
        )
        .first()
    )


# --------------------------------------------------
# RELEASE UNUSED ALLOWANCE
# --------------------------------------------------

def release_offline_allowance(
    db: Session,
    user_id: str,
    allowance_id: str,
) -> None:

    allowance = (
        db.query(OfflineAllowance)
        .filter(
            OfflineAllowance.allowance_id == allowance_id,
            OfflineAllowance.user_id == user_id,
        )
        .with_for_update()
        .first()
    )

    if not allowance:
        raise ValueError("Offline allowance not found")

    if not allowance.active:
        return

    account = (
        db.query(BankAccount)
        .filter(BankAccount.user_id == user_id)
        .with_for_update()
        .first()
    )

    if not account:
        raise ValueError("Bank account not found")

    unused = (
        money(allowance.allowance_amount)
        - money(allowance.spent_amount)
    )

    if unused < 0:
        raise ValueError("Invalid allowance spending record")

    if unused > money(account.reserved_balance):
        raise ValueError("Reserved balance is inconsistent")

    account.reserved_balance = (
        money(account.reserved_balance) - unused
    )

    allowance.active = False

    db.flush()
