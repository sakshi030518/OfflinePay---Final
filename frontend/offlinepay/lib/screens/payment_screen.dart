
import 'package:flutter/material.dart';

import '../database/local_database.dart';
import '../services/api_service.dart';
import '../services/qr_service.dart';
import 'qr_screen.dart';

class PaymentScreen extends StatefulWidget {
  final Map request;

  const PaymentScreen({
    super.key,
    required this.request,
  });

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  bool processing = false;


  Future<void> generatePaymentQr() async {
    if (processing) return;

    setState(() => processing = true);

    try {
      // 1. Get the logged-in customer.
      final customerId = await ApiService.userId();

      if (customerId == null || customerId.isEmpty) {
        throw Exception(
          'Customer account not found. Please log in again.',
        );
      }

      // 2. Validate merchant payment request.
      final requestId = widget.request['request_id']?.toString();
      final merchantId = widget.request['merchant_id']?.toString();
      final amountValue = widget.request['amount'];

      if (requestId == null || requestId.isEmpty) {
        throw Exception('Invalid merchant request ID.');
      }

      if (merchantId == null || merchantId.isEmpty) {
        throw Exception('Invalid merchant ID.');
      }

      if (merchantId == customerId) {
        throw Exception('You cannot make a payment to your own account.');
      }

      if (amountValue is! num ||
          !amountValue.isFinite ||
          amountValue <= 0) {
        throw Exception('Invalid payment amount.');
      }

      final amount = amountValue.toDouble();

      // 3. Check merchant request expiry.
      final requestExpiry = widget.request['expiry'];

      if (requestExpiry is! num ||
          DateTime.now().millisecondsSinceEpoch >=
              requestExpiry.toInt()) {
        throw Exception(
          'Payment request expired. Ask the merchant for a new QR.',
        );
      }

      // 4. Get this phone's existing device identity.
      // Do not register the device here because this payment
      // must also work when the phone has no internet.
      final deviceId = await QrService.deviceId();

      if (deviceId.isEmpty) {
        throw Exception('Device identity is unavailable.');
      }

      // 5. Find the server-provisioned local allowance.
      final allowance = await LocalDatabase.getActiveAllowance(
        userId: customerId,
        deviceId: deviceId,
      );

      if (allowance == null) {
        throw Exception(
          'No active offline allowance found. '
          'Connect to the internet and prepare an allowance first.',
        );
      }

      final allowanceId =
          allowance['allowance_id']?.toString();

      if (allowanceId == null || allowanceId.isEmpty) {
        throw Exception('Invalid offline allowance.');
      }

      // 6. Validate allowance with specific error messages.
      if (allowance['user_id']?.toString() != customerId ||
          allowance['device_id']?.toString() != deviceId) {
        throw Exception(
          'This allowance is not valid for this device.',
        );
      }

      if (allowance['status']?.toString() != 'ACTIVE') {
        throw Exception('Offline allowance is not active.');
      }

      final expiry = (allowance['expires_at'] as num?)?.toInt() ?? 0;

      if (DateTime.now().millisecondsSinceEpoch >= expiry) {
        throw Exception('Offline allowance has expired.');
      }

      final allowanceLimit =
          (allowance['allowance_amount'] as num?)?.toDouble() ?? 0;

      final allowanceSpent =
          (allowance['spent_amount'] as num?)?.toDouble() ?? 0;

      final remainingAllowance = allowanceLimit - allowanceSpent;

      if (amount > remainingAllowance) {
        throw Exception(
          'Insufficient allowance. Available: '
          '₹${remainingAllowance.toStringAsFixed(2)}',
        );
      }

      // Check locally cached, server-verified customer balance.
      final account = await LocalDatabase.getLocalAccount(customerId);

      if (account == null || account['is_server_verified'] != 1) {
        throw Exception(
          'Customer account is not verified for offline payments.',
        );
      }

      final balance =
          (account['verified_balance'] as num?)?.toDouble() ?? 0;

      final reserved =
          (account['reserved_balance'] as num?)?.toDouble() ?? 0;

      if (amount > balance || amount > reserved) {
        throw Exception(
          'Insufficient reserved balance. '
          'Available: ₹${reserved.toStringAsFixed(2)}',
        );
      }


      // 7. Generate unique transaction ID and payment token.
      final transactionId = QrService.tx();
      final paymentToken = QrService.token();

      // 8. Generate signed customer payment QR.
      final paymentPayload = await QrService.createSignedPayment(
        transactionId: transactionId,
        requestId: requestId,
        customerId: customerId,
        merchantId: merchantId,
        amount: amount,
        paymentToken: paymentToken,
        allowanceId: allowanceId,
      );

      // 9. Apply a two-minute QR validity period.
      // Timestamp and expiry are already included in the signed payload.
      // Actual customer debit occurs only after the customer
      // verifies the merchant's signed ACK QR.
      await LocalDatabase.save({
        'transaction_id': transactionId,
        'request_id': requestId,
        'customer_id': customerId,
        'merchant_id': merchantId,
        'amount': amount,
        'token': paymentToken,
        'status': 'PAYMENT_QR',
        'timestamp': paymentPayload['timestamp'],
        'expiry': paymentPayload['expiry'],
        'synced': 0,
        'allowance_id': allowanceId,
        'payload': paymentPayload,
        'role': 'customer',
        'sync_status': 'PENDING',
      });

      if (!mounted) return;

      // 11. Display customer payment QR.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => QrScreen(
            title: 'Customer Payment QR',
            payload: QrService.enc(paymentPayload),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst('Exception: ', ''),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );

      setState(() => processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final merchantName =
        widget.request['merchant_name']?.toString() ?? 'Merchant';

    final amount =
        (widget.request['amount'] as num?)?.toDouble() ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Payment'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(25),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.account_balance_wallet,
                size: 70,
                color: Colors.blue,
              ),
              const SizedBox(height: 25),
              Text(
                merchantName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 15),
              Text(
                '₹${amount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 15),
              const Text(
                'Confirm this payment to generate your '
                'Customer Payment QR.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15),
              ),
              const SizedBox(height: 35),
              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton.icon(
                  onPressed:
                      processing ? null : generatePaymentQr,
                  icon: processing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.qr_code_2),
                  label: Text(
                    processing
                        ? 'Preparing Secure Payment...'
                        : 'Confirm & Generate Payment QR',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
