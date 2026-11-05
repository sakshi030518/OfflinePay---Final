
import os
import smtplib
from email.message import EmailMessage

from dotenv import load_dotenv

load_dotenv()


def send_email(
    recipient: str,
    subject: str,
    body: str,
) -> bool:
    """Send an email using the configured SMTP account."""

    smtp_host = os.getenv("SMTP_HOST")
    smtp_port = int(os.getenv("SMTP_PORT", "587"))
    smtp_username = os.getenv("SMTP_USERNAME")
    smtp_password = os.getenv("SMTP_PASSWORD")
    smtp_from = os.getenv("SMTP_FROM", smtp_username or "")
    use_tls = os.getenv("SMTP_USE_TLS", "true").lower() == "true"

    if not all([smtp_host, smtp_username, smtp_password, smtp_from]):
        print("Email not sent: SMTP configuration is incomplete.")
        return False

    message = EmailMessage()
    message["From"] = smtp_from
    message["To"] = recipient
    message["Subject"] = subject
    message.set_content(body)

    try:
        with smtplib.SMTP(smtp_host, smtp_port, timeout=15) as server:
            server.ehlo()

            if use_tls:
                server.starttls()
                server.ehlo()

            server.login(smtp_username, smtp_password)
            server.send_message(message)

        return True

    except Exception as error:
        # Email failure should not interrupt registration or payment.
        print(f"Email delivery failed: {error}")
        return False


def send_welcome_email(
    recipient: str,
    account_holder: str,
    account_number: str,
    opening_balance: str,
) -> bool:

    subject = "Welcome to OfflinePay!"

    body = f"""
Hello {account_holder},

Welcome to OfflinePay!

Your account has been successfully registered.

Your simulated bank account details:

Account Holder: {account_holder}
Account Number: {account_number}
Opening Balance: ₹{opening_balance}

You can now explore OfflinePay's QR-based payment features.

Important:
This is a simulated bank account for the OfflinePay project.
It is not connected to a real bank.

Thank you for joining OfflinePay!

Regards,
OfflinePay Team
"""

    return send_email(recipient, subject, body)
