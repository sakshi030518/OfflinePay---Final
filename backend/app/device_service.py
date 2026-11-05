from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from sqlalchemy.orm import Session

from .models import Device


def validate_ed25519_public_key(public_key_pem: str):
    """Validate that the supplied PEM contains an Ed25519 public key."""

    try:
        public_key = serialization.load_pem_public_key(
            public_key_pem.encode("utf-8")
        )

        if not isinstance(public_key, Ed25519PublicKey):
            raise ValueError("Only Ed25519 public keys are supported.")

        return public_key

    except ValueError:
        raise
    except Exception:
        raise ValueError("Invalid public key. Provide a valid Ed25519 PEM key.")


def register_device(
    db: Session,
    user_id: str,
    device_id: str,
    device_name: str | None,
    public_key_pem: str,
    key_algorithm: str = "Ed25519",
):
    if key_algorithm != "Ed25519":
        raise ValueError("Only Ed25519 key algorithm is supported.")

    validate_ed25519_public_key(public_key_pem)

    existing_device = (
        db.query(Device)
        .filter(Device.device_id == device_id)
        .first()
    )

    if existing_device:
        if existing_device.user_id != user_id:
            raise ValueError("This device is already registered to another user.")

        if existing_device.public_key != public_key_pem:
            raise ValueError(
                "This device already has a registered key. "
                "Key replacement requires a separate secure process."
            )

        if not existing_device.active:
            raise ValueError("This device is inactive.")

        return existing_device

    device = Device(
        device_id=device_id,
        user_id=user_id,
        device_name=device_name,
        public_key=public_key_pem,
        key_algorithm="Ed25519",
        active=True,
    )

    db.add(device)
    db.flush()

    return device


def get_user_device(db: Session, user_id: str, device_id: str):
    return (
        db.query(Device)
        .filter(
            Device.user_id == user_id,
            Device.device_id == device_id,
            Device.active.is_(True),
        )
        .first()
    )