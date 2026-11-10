
from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    ForeignKey,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
    Index,
)

from .database import Base


# ==================================================
# USER
# ==================================================

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)

    user_id = Column(
        String(50),
        unique=True,
        nullable=False,
        index=True,
    )

    name = Column(String(150), nullable=False)
    phone = Column(String(20), unique=True, nullable=False)
    email = Column(String(255), unique=True, nullable=False, index=True)
    password_hash = Column(String(255), nullable=False)
    role = Column(String(20), nullable=False)

    created_at = Column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )


# ==================================================
# LEGACY OFFLINEPAY WALLET
# ==================================================

class Wallet(Base):
    __tablename__ = "wallets"

    id = Column(Integer, primary_key=True, index=True)

    wallet_id = Column(
        String(50),
        unique=True,
        nullable=False,
    )

    user_id = Column(
        String(50),
        ForeignKey("users.user_id"),
        unique=True,
        nullable=False,
        index=True,
    )

    balance = Column(
        Numeric(12, 2),
        default=Decimal("0.00"),
        nullable=False,
    )

    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        nullable=False,
    )



# ==================================================
# TRANSACTIONS
# ==================================================

class Transaction(Base):
    __tablename__ = "transactions"

    id = Column(Integer, primary_key=True, index=True)

    transaction_id = Column(
        String(100),
        unique=True,
        nullable=False,
        index=True,
    )

    request_id = Column(String(100), nullable=False)

    customer_id = Column(
        String(50),
        ForeignKey("users.user_id"),
        nullable=False,
        index=True,
    )

    merchant_id = Column(
        String(50),
        ForeignKey("users.user_id"),
        nullable=False,
        index=True,
    )

    amount = Column(
        Numeric(12, 2),
        nullable=False,
    )

    token = Column(
        String(100),
        unique=True,
        nullable=False,
    )

    status = Column(
        String(30),
        default="PENDING",
        nullable=False,
    )

    created_at = Column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )


# ==================================================
# SIMULATED BANK ACCOUNT
# ==================================================

class BankAccount(Base):
    __tablename__ = "bank_accounts"

    id = Column(Integer, primary_key=True, index=True)

    account_number = Column(
        String(30),
        unique=True,
        nullable=False,
        index=True,
    )

    user_id = Column(
        String(50),
        ForeignKey("users.user_id"),
        unique=True,
        nullable=False,
        index=True,
    )

    account_holder = Column(String(150), nullable=False)

    account_type = Column(
        String(30),
        default="SAVINGS",
        nullable=False,
    )

    balance = Column(
        Numeric(12, 2),
        default=Decimal("0.00"),
        nullable=False,
    )

    reserved_balance = Column(
        Numeric(12, 2),
        default=Decimal("0.00"),
        nullable=False,
    )

    status = Column(
        String(20),
        default="ACTIVE",
        nullable=False,
    )

    created_at = Column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )

    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        nullable=False,
    )


# ==================================================
# BANK LEDGER
# ==================================================

class BankLedger(Base):
    __tablename__ = "bank_ledger"

    id = Column(Integer, primary_key=True, index=True)

    transaction_id = Column(
        String(100),
        nullable=False,
        index=True,
    )

    user_id = Column(
        String(50),
        ForeignKey("users.user_id"),
        nullable=False,
        index=True,
    )

    entry_type = Column(
        String(20),
        nullable=False,
    )

    amount = Column(
        Numeric(12, 2),
        nullable=False,
    )

    balance_after = Column(
        Numeric(12, 2),
        nullable=False,
    )

    description = Column(String(255), nullable=True)

    reference_number = Column(
        String(100),
        unique=True,
        nullable=False,
    )

    status = Column(
        String(30),
        default="COMPLETED",
        nullable=False,
    )

    created_at = Column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
        index=True,
    )

    __table_args__ = (
        UniqueConstraint(
            "transaction_id",
            "user_id",
            name="uq_bank_ledger_transaction_user",
        ),
    )


# ==================================================
# REGISTERED DEVICES
# ==================================================

class Device(Base):
    __tablename__ = "devices"

    id = Column(Integer, primary_key=True, index=True)

    device_id = Column(
        String(150),
        unique=True,
        nullable=False,
        index=True,
    )

    user_id = Column(
        String(50),
        ForeignKey("users.user_id"),
        nullable=False,
        index=True,
    )

    device_name = Column(
        String(150),
        nullable=True,
    )

    public_key = Column(
        String(1000),
        nullable=False,
    )

    key_algorithm = Column(
        String(30),
        default="Ed25519",
        nullable=False,
    )

    active = Column(
        Boolean,
        default=True,
        nullable=False,
    )

    created_at = Column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )

    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        nullable=False,
    )


# ==================================================
# OFFLINE PAYMENT ALLOWANCES
# ==================================================

class OfflineAllowance(Base):
    __tablename__ = "offline_allowances"

    id = Column(Integer, primary_key=True, index=True)

    allowance_id = Column(
        String(100),
        unique=True,
        nullable=False,
        index=True,
    )

    user_id = Column(
        String(50),
        ForeignKey("users.user_id"),
        nullable=False,
        index=True,
    )

    device_id = Column(
        String(150),
        ForeignKey("devices.device_id"),
        nullable=False,
        index=True,
    )

    allowance_amount = Column(
        Numeric(12, 2),
        nullable=False,
    )

    spent_amount = Column(
        Numeric(12, 2),
        default=Decimal("0.00"),
        nullable=False,
    )

    expires_at = Column(
        DateTime,
        nullable=False,
        index=True,
    )

    active = Column(
        Boolean,
        default=True,
        nullable=False,
    )

    created_at = Column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )


# ==================================================
# DATABASE INDEXES
# ==================================================

Index(
    "ix_transactions_customer_created",
    Transaction.customer_id,
    Transaction.created_at,
)

Index(
    "ix_transactions_merchant_created",
    Transaction.merchant_id,
    Transaction.created_at,
)

Index(
    "ix_allowance_user_device_active",
    OfflineAllowance.user_id,
    OfflineAllowance.device_id,
    OfflineAllowance.active,
)
