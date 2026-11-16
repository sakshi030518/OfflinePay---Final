
from decimal import Decimal
from datetime import datetime
from typing import Optional

from pydantic import (
    BaseModel,
    EmailStr,
    Field,
    ConfigDict,
)


# ==================================================
# AUTHENTICATION
# ==================================================

class SignupRequest(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    phone: str = Field(min_length=8, max_length=30)
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    role: str = Field(pattern=r"^(customer|merchant)$")


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class ForgotPasswordRequest(BaseModel):
    email: EmailStr


class ResetPasswordRequest(BaseModel):
    token: str = Field(min_length=20, max_length=2000)
    new_password: str = Field(min_length=8, max_length=128)


class TokenResponse(BaseModel):
    access_token: str
    token_type: str
    user_id: str
    role: str
    name: str


# ==================================================
# DEVICE REGISTRATION
# ==================================================

class DeviceRegisterRequest(BaseModel):
    device_id: str = Field(min_length=5, max_length=150)
    device_name: str = Field(min_length=2, max_length=120)
    public_key: str = Field(min_length=40, max_length=2000)
    key_algorithm: str = Field(default="Ed25519")


class DeviceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    device_id: str
    user_id: str
    device_name: Optional[str] = None
    key_algorithm: str
    active: bool


class DeviceCertificateResponse(BaseModel):
    certificate: dict
    signature: str


# ==================================================
# PAYMENT DATA
# ==================================================

class PaymentData(BaseModel):
    transaction_id: str = Field(min_length=8, max_length=100)
    request_id: str = Field(min_length=8, max_length=100)

    customer_id: str = Field(min_length=3, max_length=80)
    merchant_id: str = Field(min_length=3, max_length=80)

    amount: Decimal = Field(
        gt=0,
        max_digits=12,
        decimal_places=2,
    )

    token: str = Field(min_length=8, max_length=255)


# ==================================================
# OFFLINE PAYMENT SYNCHRONIZATION
# ==================================================

class SyncPaymentRequest(PaymentData):
    # Customer's registered device
    device_id: str = Field(min_length=5, max_length=150)

    # Merchant's registered device
    merchant_device_id: str = Field(min_length=5, max_length=150)

    allowance_id: str = Field(min_length=8, max_length=100)

    payer_signature: str = Field(
        min_length=20,
        max_length=2000,
    )

    merchant_ack_signature: str = Field(
        min_length=20,
        max_length=2000,
    )

    payment_created_at: datetime

    acknowledgement_created_at: datetime


# ==================================================
# SIMULATED BANK ACCOUNT
# ==================================================

class BankAccountResponse(BaseModel):
    account_number: str
    account_holder: str
    account_type: str

    balance: Decimal
    reserved_balance: Decimal

    status: str


class BankLedgerResponse(BaseModel):
    transaction_id: Optional[str] = None
    user_id: str

    entry_type: str
    amount: Decimal
    balance_after: Decimal

    description: str
    reference_number: str
    status: str

    created_at: str


# ==================================================
# BANK DEPOSIT
# ==================================================

class BankDepositRequest(BaseModel):
    amount: Decimal = Field(
        gt=0,
        max_digits=12,
        decimal_places=2,
    )

    reference_number: Optional[str] = Field(
        default=None,
        min_length=8,
        max_length=100,
    )


# ==================================================
# BANK WITHDRAWAL
# ==================================================

class BankWithdrawalRequest(BaseModel):
    amount: Decimal = Field(
        gt=0,
        max_digits=12,
        decimal_places=2,
    )

    reference_number: Optional[str] = Field(
        default=None,
        min_length=8,
        max_length=100,
    )


# ==================================================
# OFFLINE ALLOWANCE
# ==================================================

class OfflineAllowanceRequest(BaseModel):
    device_id: str = Field(min_length=5, max_length=150)

    amount: Decimal = Field(
        gt=0,
        max_digits=12,
        decimal_places=2,
    )


class OfflineAllowanceResponse(BaseModel):
    allowance_id: str
    user_id: str
    device_id: str

    allowance_amount: Decimal
    spent_amount: Decimal

    expires_at: str
    active: bool


# ==================================================
# WALLET
# ==================================================

class WalletResponse(BaseModel):
    user_id: str
    balance: Decimal


# ==================================================
# TRANSACTION RESPONSE
# ==================================================

class TransactionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    transaction_id: str
    request_id: str

    customer_id: str
    merchant_id: str

    amount: Decimal
    status: str


class DeviceCertificateResponse(BaseModel):
    certificate: dict
    signature: str