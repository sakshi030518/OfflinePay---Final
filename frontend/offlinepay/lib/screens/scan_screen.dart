import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:audioplayers/audioplayers.dart';

import '../database/local_database.dart';
import '../services/api_service.dart';
import '../services/qr_service.dart';

import 'payment_screen.dart';
import 'qr_screen.dart';

enum ScanMode {
  paymentRequest,
  payment,
  confirmation,
}

class ScanScreen extends StatefulWidget {
  final ScanMode mode;

  const ScanScreen({
    super.key,
    required this.mode,
  });

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  late final MobileScannerController controller;
  final AudioPlayer successPlayer = AudioPlayer();

  bool done = false;

  ScanMode get mode => widget.mode;

  @override
  void initState() {
    super.initState();

    controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      autoStart: true,
    );

    _configureAudio();
  }

  Future<void> _configureAudio() async {
    try {
      await successPlayer.setReleaseMode(ReleaseMode.stop);
      await successPlayer.setVolume(1.0);
      await successPlayer.setPlayerMode(PlayerMode.mediaPlayer);
    } catch (e) {
      debugPrint('Audio configuration error: $e');
    }
  }

  Future<void> _playSuccessSound() async {
    try {
      await successPlayer.stop();
      await successPlayer.play(
        AssetSource('sounds/payment_success.mp3'),
      );
    } catch (e) {
      debugPrint('Payment audio error: $e');

      try {
        await SystemSound.play(SystemSoundType.alert);
      } catch (_) {}
    }
  }

  String _requiredField(Map data, String key) {
    final value = data[key]?.toString();

    if (value == null || value.isEmpty) {
      throw Exception('Invalid QR: missing $key.');
    }

    return value;
  }

  double _validAmount(Map data) {
    final value = data['amount'];

    if (value is! num || !value.isFinite || value <= 0) {
      throw Exception('Invalid payment amount.');
    }

    return value.toDouble();
  }

  Future<String> _currentUserId() async {
    final id = await ApiService.userId();

    if (id == null || id.isEmpty) {
      throw Exception('Please log in again.');
    }

    return id;
  }

  /// Gets a registered device key from the local trusted-key cache.
  /// If unavailable, retrieves it from the authenticated backend.
  Future<String> _trustedPublicKey({
    required String deviceId,
    required String expectedOwnerId,
  }) async {
    final cachedKey = await LocalDatabase.getTrustedDevicePublicKey(
      deviceId: deviceId,
      userId: expectedOwnerId,
    );

    if (cachedKey != null && cachedKey.trim().isNotEmpty) {
      return cachedKey;
    }

    final response = await ApiService.getDevicePublicKey(deviceId);

    final returnedDeviceId = response['device_id']?.toString();
    final returnedOwnerId = response['user_id']?.toString();
    final algorithm =
        response['key_algorithm']?.toString().toLowerCase();
    final publicKey = response['public_key']?.toString();

    final active =
        response['active'] == true || response['active'] == 1;

    if (returnedDeviceId != deviceId ||
        returnedOwnerId != expectedOwnerId ||
        algorithm != 'ed25519' ||
        publicKey == null ||
        publicKey.trim().isEmpty ||
        !active) {
      throw Exception(
        'The registered device key does not match the payment account.',
      );
    }

    await LocalDatabase.saveTrustedDevice(
      deviceId: deviceId,
      userId: expectedOwnerId,
      publicKey: publicKey,
      keyAlgorithm: 'Ed25519',
      active: true,
    );

    return publicKey;
  }

  // --------------------------------------------------
  // SIGNATURE VERIFICATION HELPERS
  // --------------------------------------------------

  String _signatureAmount(Map data) {
    final amount = data['amount'];

    if (amount is! num || !amount.isFinite || amount <= 0) {
      throw Exception('Invalid signed payment amount.');
    }

    return amount.toStringAsFixed(2);
  }

  String _paymentSignatureMessage(Map payment) {
    return [
      'OFFLINEPAY_PAYMENT_V1',
      _requiredField(payment, 'txn_id'),
      _requiredField(payment, 'request_id'),
      _requiredField(payment, 'customer_id'),
      _requiredField(payment, 'merchant_id'),
      _signatureAmount(payment),
      _requiredField(payment, 'token'),
      _requiredField(payment, 'allowance_id'),
      _requiredField(payment, 'device_id'),
      _requiredField(payment, 'payment_created_at'),
    ].join('\n');
  }

  String _ackSignatureMessage(Map acknowledgement) {
    return [
      'OFFLINEPAY_ACK_V1',
      _requiredField(acknowledgement, 'txn_id'),
      _requiredField(acknowledgement, 'request_id'),
      _requiredField(acknowledgement, 'customer_id'),
      _requiredField(acknowledgement, 'merchant_id'),
      _signatureAmount(acknowledgement),
      _requiredField(acknowledgement, 'token'),
      _requiredField(acknowledgement, 'allowance_id'),
      _requiredField(acknowledgement, 'device_id'),
      _requiredField(acknowledgement, 'merchant_device_id'),
      _requiredField(acknowledgement, 'payment_created_at'),
      _requiredField(acknowledgement, 'acknowledgement_created_at'),
      _requiredField(acknowledgement, 'payer_signature'),
    ].join('\n');
  }

  Future<bool> _verifyPaymentSignature({
    required Map payment,
    required String publicKey,
  }) {
    return QrService.verifySignature(
      publicKeyPem: publicKey,
      signature: _requiredField(payment, 'payer_signature'),
      message: _paymentSignatureMessage(payment),
    );
  }

  Future<bool> _verifyAckSignature({
    required Map acknowledgement,
    required String publicKey,
  }) {
    return QrService.verifySignature(
      publicKeyPem: publicKey,
      signature: _requiredField(
        acknowledgement,
        'merchant_ack_signature',
      ),
      message: _ackSignatureMessage(acknowledgement),
    );
  }

  // --------------------------------------------------
  // VERIFY ACK AGAINST ORIGINAL PAYMENT
  // --------------------------------------------------

  Future<Map<String, dynamic>> _verifyAckAgainstPendingTransaction(
    Map payload,
    String transactionId,
    String userId,
  ) async {
    final original =
        await LocalDatabase.getTransactionById(transactionId);

    if (original == null) {
      throw Exception(
        'Original payment not found. Scan using the phone that generated the payment QR.',
      );
    }

    if (original['status']?.toString().toUpperCase() !=
        'PAYMENT_QR') {
      throw Exception(
        'This payment QR has already been used or is invalid.',
      );
    }

    if (original['synced'] == 1) {
      throw Exception('This payment has already been synchronized.');
    }

    final fields = [
      'request_id',
      'customer_id',
      'merchant_id',
      'token',
      'allowance_id',
    ];

    for (final field in fields) {
      if (original[field]?.toString() !=
          payload[field]?.toString()) {
        throw Exception(
          'ACK does not match the original payment: $field.',
        );
      }
    }

    if (original['customer_id']?.toString() != userId) {
      throw Exception('Customer identity mismatch.');
    }

    final originalAmount = original['amount'];
    final ackAmount = payload['amount'];

    if (originalAmount is! num || ackAmount is! num) {
      throw Exception('Invalid ACK amount.');
    }

    if ((originalAmount.toDouble() - ackAmount.toDouble()).abs() >
        0.001) {
      throw Exception('ACK amount does not match the payment.');
    }

    // Decode the original signed payment stored in the local database.
    Map<String, dynamic>? originalPayload;

    final rawOriginalPayload = original['payload'];

    if (rawOriginalPayload is Map) {
      originalPayload = Map<String, dynamic>.from(rawOriginalPayload);
    } else if (rawOriginalPayload is String &&
        rawOriginalPayload.isNotEmpty) {
      try {
        final decoded = QrService.dec(rawOriginalPayload);
        originalPayload = Map<String, dynamic>.from(decoded);
      } catch (_) {
        throw Exception('Saved payment evidence is invalid.');
      }
    }

    if (originalPayload == null) {
      throw Exception('Original signed payment evidence is missing.');
    }

    const signedFields = [
      'device_id',
      'payment_created_at',
      'payer_signature',
    ];

    for (final field in signedFields) {
      if (originalPayload[field]?.toString() !=
          payload[field]?.toString()) {
        throw Exception(
          'ACK does not match original signed payment: $field.',
        );
      }
    }

    return original;
  }

  // --------------------------------------------------
  // MAIN QR HANDLER
  // --------------------------------------------------

  Future<void> handle(String raw) async {
    if (done) return;

    done = true;

    try {
      await controller.stop();
    } catch (_) {}

    try {
      final payload = QrService.dec(raw);

      if (QrService.expired(payload)) {
        throw Exception('QR expired. Please generate a new QR.');
      }

      final expectedType = switch (mode) {
        ScanMode.paymentRequest => 'PAYMENT_REQUEST',
        ScanMode.payment => 'PAYMENT',
        ScanMode.confirmation => 'ACK',
      };

      if (payload['type'] != expectedType) {
        throw Exception('Wrong QR type. Scan the correct QR.');
      }

      // -----------------------------------------------
      // 1. CUSTOMER SCANS MERCHANT PAYMENT REQUEST
      // -----------------------------------------------

      if (mode == ScanMode.paymentRequest) {
        _requiredField(payload, 'request_id');
        _requiredField(payload, 'merchant_id');
        _validAmount(payload);

        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => PaymentScreen(request: payload),
          ),
        );

        return;
      }

      final userId = await _currentUserId();

      // -----------------------------------------------
      // 2. MERCHANT SCANS CUSTOMER PAYMENT QR
      // -----------------------------------------------

      if (mode == ScanMode.payment) {
        final merchantId =
            _requiredField(payload, 'merchant_id');

        if (merchantId != userId) {
          throw Exception(
            'This payment QR belongs to another merchant.',
          );
        }

        final transactionId =
            _requiredField(payload, 'txn_id');

        if (await LocalDatabase.processed(transactionId)) {
          throw Exception('This transaction was already processed.');
        }

        _requiredField(payload, 'request_id');
        _requiredField(payload, 'customer_id');
        _requiredField(payload, 'token');
        _requiredField(payload, 'allowance_id');
        _requiredField(payload, 'device_id');
        _requiredField(payload, 'payment_created_at');
        _requiredField(payload, 'payer_signature');

        final amount = _validAmount(payload);

        final customerId =
            _requiredField(payload, 'customer_id');

        if (customerId == userId) {
          throw Exception(
            'You cannot make a payment to your own account.',
          );
        }

        // Verify the payer's Ed25519 signature.
        final payerDeviceId =
            _requiredField(payload, 'device_id');

        final payerPublicKey = await _trustedPublicKey(
          deviceId: payerDeviceId,
          expectedOwnerId: customerId,
        );

        final paymentSignatureValid =
            await _verifyPaymentSignature(
          payment: payload,
          publicKey: payerPublicKey,
        );

        if (!paymentSignatureValid) {
          throw Exception(
            'Customer payment signature is invalid or expired.',
          );
        }

        // Create the merchant-signed acknowledgement.
        final ackPayload = await QrService.createSignedAck(
          payment: payload,
          merchantId: userId,
        );

        // Record provisional merchant credit locally.
        // This does not increase spendable balance.
        await LocalDatabase.recordMerchantCredit(
          transactionId: transactionId,
          merchantId: userId,
          amount: amount,
          signedPayload: Map<String, dynamic>.from(ackPayload),
        );

        if (!mounted) return;

        await Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => QrScreen(
              title: 'Merchant ACK QR',
              payload: QrService.enc(ackPayload),
            ),
          ),
        );

        return;
      }

      // -----------------------------------------------
      // 3. CUSTOMER SCANS MERCHANT ACK QR
      // -----------------------------------------------

      if (mode == ScanMode.confirmation) {
        final customerId =
            _requiredField(payload, 'customer_id');

        if (customerId != userId) {
          throw Exception('This ACK is not for this customer.');
        }

        final transactionId =
            _requiredField(payload, 'txn_id');

        if (await LocalDatabase.processed(transactionId)) {
          throw Exception('This transaction was already completed.');
        }

        _requiredField(payload, 'request_id');
        _requiredField(payload, 'merchant_id');
        _requiredField(payload, 'token');

        final allowanceId =
            _requiredField(payload, 'allowance_id');

        final deviceId =
            _requiredField(payload, 'device_id');

        _requiredField(payload, 'merchant_device_id');
        _requiredField(payload, 'payer_signature');
        _requiredField(payload, 'merchant_ack_signature');
        _requiredField(payload, 'payment_created_at');
        _requiredField(payload, 'acknowledgement_created_at');

        final amount = _validAmount(payload);

        // Match ACK with the original payment saved on this phone.
        await _verifyAckAgainstPendingTransaction(
          payload,
          transactionId,
          userId,
        );

        final merchantId =
            _requiredField(payload, 'merchant_id');

        if (merchantId == userId) {
          throw Exception(
            'You cannot accept an ACK from your own account.',
          );
        }

        // Verify the merchant's registered device key.
        final merchantDeviceId =
            _requiredField(payload, 'merchant_device_id');

        final merchantPublicKey = await _trustedPublicKey(
          deviceId: merchantDeviceId,
          expectedOwnerId: merchantId,
        );

        final ackSignatureValid = await _verifyAckSignature(
          acknowledgement: payload,
          publicKey: merchantPublicKey,
        );

        if (!ackSignatureValid) {
          throw Exception(
            'Merchant acknowledgement signature is invalid or expired.',
          );
        }

        final localDeviceId = await QrService.deviceId();

        if (deviceId != localDeviceId) {
          throw Exception('Payment was created on another device.');
        }

        // Record customer debit and pending sync evidence locally.
        await LocalDatabase.recordCustomerDebit(
          transactionId: transactionId,
          userId: userId,
          allowanceId: allowanceId,
          deviceId: localDeviceId,
          amount: amount,
          signedPayload: Map<String, dynamic>.from(payload),
        );

        if (!mounted) return;

        await HapticFeedback.mediumImpact();
        _playSuccessSound();

        if (!mounted) return;

        // Offline payment remains provisional until backend sync.
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            return AlertDialog(
              icon: const Icon(
                Icons.check_circle,
                color: Colors.green,
                size: 68,
              ),
              title: const Text(
                'Payment Completed!',
                textAlign: TextAlign.center,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '₹${amount.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Your payment has been recorded on this device.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Chip(
                    avatar: Icon(
                      Icons.sync,
                      size: 18,
                    ),
                    label: Text('Pending Sync'),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Final settlement will be confirmed when internet connectivity returns.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(dialogContext).pop();
                    },
                    child: const Text('DONE'),
                  ),
                ),
              ],
            );
          },
        );

        if (!mounted) return;

        Navigator.of(context).pop();
      }
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

      await Future.delayed(
        const Duration(milliseconds: 700),
      );

      if (!mounted) return;

      setState(() {
        done = false;
      });

      try {
        await controller.start();
      } catch (e) {
        debugPrint('Scanner restart error: $e');
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    successPlayer.dispose();
    super.dispose();
  }

  // --------------------------------------------------
  // SCREEN UI
  // --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final title = switch (mode) {
      ScanMode.paymentRequest => 'Scan Merchant QR',
      ScanMode.payment => 'Scan Customer Payment QR',
      ScanMode.confirmation => 'Scan Merchant ACK QR',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Flashlight',
            icon: const Icon(Icons.flash_on),
            onPressed: () => controller.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Switch camera',
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: controller,
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
                final value = barcode.rawValue;

                if (value != null && value.isNotEmpty) {
                  handle(value);
                  break;
                }
              }
            },
          ),
          Center(
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          const Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Text(
              'Align the QR code inside the frame',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}