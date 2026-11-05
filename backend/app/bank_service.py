
import os
import secrets
from decimal import Decimal

from sqlalchemy.orm import Session

from .models import BankAccount, BankLedger


# --------------------------------------------------
# BANK CONFIGURATION
# --------------------------------------------------

OPENING_BALANCE = Decimal(
    os.getenv("BANK_OPENING_BALANCE", "10000.00")
).quantize(Decimal("0.01"))

CURRENCY = "INR"


# --------------------------------------------------
# ACCOUNT NUMBER GENERATOR
# --------------------------------------------------

def generate_account_number(db: Session) -> str:
    """Generate a unique 12-digit simulated bank account number."""

    for _ in range(10):
        account_number = "".join(
            str(secrets.randbelow(10)) for _ in range(12)
        )

        existing = db.query(BankAccount).filter(
            BankAccount.account_number == account_number
        ).first()

        if not existing:
            return account_number

    raise RuntimeError("Could not generate a unique bank account number")


# --------------------------------------------------
# CREATE BANK ACCOUNT
# --------------------------------------------------

def create_bank_account(
    db: Session,
    user_id: str,
    account_holder: str,
) -> BankAccount:
    """
    Create one simulated bank account for a newly registered user.

    This function must only be called during registration,
    not during login.
    """

    existing = db.query(BankAccount).filter(
        BankAccount.user_id == user_id
    ).first()

    if existing:
        return existing

    account = BankAccount(
        user_id=user_id,
        account_number=generate_account_number(db),
        account_holder=account_holder,
        account_type="SAVINGS",
        balance=OPENING_BALANCE,
        reserved_balance=Decimal("0.00"),
        status="ACTIVE",
    )

    db.add(account)
    db.flush()

    # Record the opening balance in the bank statement.
    opening_entry = BankLedger(
        transaction_id=None,
        user_id=user_id,
        entry_type="CREDIT",
        amount=OPENING_BALANCE,
        balance_after=OPENING_BALANCE,
        description="OfflinePay simulated bank opening balance",
        reference_number="OPEN-" + secrets.token_hex(8).upper(),
        status="COMPLETED",
    )

    db.add(opening_entry)

    return account


# --------------------------------------------------
# GET BANK ACCOUNT
# --------------------------------------------------

def get_bank_account(
    db: Session,
    user_id: str,
) -> BankAccount | None:

    return db.query(BankAccount).filter(
        BankAccount.user_id == user_id
    ).first()


# --------------------------------------------------
# AVAILABLE BALANCE
# --------------------------------------------------

def get_available_balance(account: BankAccount) -> Decimal:

    balance = Decimal(str(account.balance))
    reserved = Decimal(str(account.reserved_balance))

    return (balance - reserved).quantize(Decimal("0.01"))
