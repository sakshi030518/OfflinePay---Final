
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'scan_screen.dart';

class QrScreen extends StatefulWidget {
  final String title;
  final String payload;

  const QrScreen({
    super.key,
    required this.title,
    required this.payload,
  });

  @override
  State<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends State<QrScreen> {
  int left = 300;
  Timer? timer;

  bool get isCustomerPaymentQr =>
      widget.title == 'Customer Payment QR';

  @override
  void initState() {
    super.initState();

    timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;

        if (left > 0) {
          setState(() {
            left--;
          });
        } else {
          timer?.cancel();
        }
      },
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void openAckScanner() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ScanScreen(
          mode: ScanMode.confirmation,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final minutes = left ~/ 60;
    final seconds = (left % 60).toString().padLeft(2, '0');

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (left > 0)
                  QrImageView(
                    data: widget.payload,
                    size: 280,
                  )
                else
                  const Icon(
                    Icons.timer_off,
                    size: 100,
                    color: Colors.red,
                  ),

                const SizedBox(height: 20),

                Text(
                  left > 0
                      ? 'Expires in $minutes:$seconds'
                      : 'QR EXPIRED',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                if (isCustomerPaymentQr && left > 0) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Ask the merchant to scan this payment QR.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton.icon(
                      onPressed: openAckScanner,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text(
                        'Scan Merchant ACK QR',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'After the merchant displays the ACK QR, '
                    'scan it here to complete verification.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
