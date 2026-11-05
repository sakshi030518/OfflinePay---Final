
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class QrService {
  // Every QR stage is valid for exactly 2 minutes.
  static const int valid = 120000;

  static final _u = Uuid();
  static final _algorithm = Ed25519();

  static const FlutterSecureStorage _storage =
      FlutterSecureStorage();

  static const String _deviceIdKey = 'offlinepay_device_id';
  static const String _privateKeyKey =
      'offlinepay_ed25519_private_seed';

  // ---------------- QR HELPERS ----------------

  static String req() =>
      'REQ-${_u.v4().substring(0, 8).toUpperCase()}';

  static String tx() =>
      'TXN-${_u.v4().substring(0, 8).toUpperCase()}';

  static String token() => _u.v4();

  static String enc(Map x) => jsonEncode(x);

  static Map dec(String x) {
    final decoded = jsonDecode(x);

    if (decoded is! Map) {
      throw Exception('Invalid QR data.');
    }

    return Map<String, dynamic>.from(decoded);
  }

  static bool expired(Map p) {
    final expiry = p['expiry'];

    if (expiry is! num) return true;

    return DateTime.now().millisecondsSinceEpoch >=
        expiry.toInt();
  }

  static int remainingMilliseconds(Map p) {
    final expiry = p['expiry'];

    if (expiry is! num) return 0;

    final remaining = expiry.toInt() -
        DateTime.now().millisecondsSinceEpoch;

    return remaining > 0 ? remaining : 0;
  }

  // ---------------- DEVICE ID ----------------

  static Future<String> deviceId() async {
    String? id = await _storage.read(key: _deviceIdKey);

    if (id == null || id.isEmpty) {
      id = _u.v4();

      await _storage.write(
        key: _deviceIdKey,
        value: id,
      );
    }

    return id;
  }

  // ---------------- ED25519 KEY STORAGE ----------------

  static Future<SimpleKeyPair> _getKeyPair() async {
    String? savedSeed =
        await _storage.read(key: _privateKeyKey);

    if (savedSeed == null || savedSeed.isEmpty) {
      final newKeyPair = await _algorithm.newKeyPair();

      final privateSeed =
          await newKeyPair.extractPrivateKeyBytes();

      savedSeed = base64Encode(privateSeed);

      await _storage.write(
        key: _privateKeyKey,
        value: savedSeed,
      );
    }

    final seed = base64Decode(savedSeed);

    if (seed.length != 32) {
      throw Exception(
        'Invalid saved security key. Please register this device again.',
      );
    }

    return _algorithm.newKeyPairFromSeed(seed);
  }

  // ---------------- PUBLIC KEY ----------------

  static Future<String> publicKeyPem() async {
    final keyPair = await _getKeyPair();
    final publicKey = await keyPair.extractPublicKey();

    const derPrefix = [
      0x30, 0x2A,
      0x30, 0x05,
      0x06, 0x03, 0x2B, 0x65, 0x70,
      0x03, 0x21, 0x00,
    ];

    final derBytes = [
      ...derPrefix,
      ...publicKey.bytes,
    ];

    final encoded = base64Encode(derBytes);
    final lines = <String>[];

    for (int i = 0; i < encoded.length; i += 64) {
      final end = i + 64 < encoded.length
          ? i + 64
          : encoded.length;

      lines.add(encoded.substring(i, end));
    }

    return [
      '-----BEGIN PUBLIC KEY-----',
      ...lines,
      '-----END PUBLIC KEY-----',
    ].join('\n');
  }

  // ---------------- TIMESTAMP ----------------

  static String _utcTimestamp(DateTime dateTime) {
    final d = dateTime.toUtc();

    final fraction =
        '${d.millisecond.toString().padLeft(3, '0')}'
        '${d.microsecond.toString().padLeft(3, '0')}';

    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}T'
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}:'
        '${d.second.toString().padLeft(2, '0')}'
        '.$fraction'
        'Z';
  }

  static String _requiredString(Map data, String key) {
    final value = data[key]?.toString();

    if (value == null || value.isEmpty) {
      throw Exception('Missing required payment field: $key');
    }

    return value;
  }

  static String _amount(Map data) {
    final value = data['amount'];

    if (value is! num || !value.isFinite || value <= 0) {
      throw Exception('Invalid payment amount.');
    }

    return value.toStringAsFixed(2);
  }

  // ---------------- PAYMENT SIGNATURE MESSAGE ----------------

  static String _paymentMessage(Map payment) {
    return [
      'OFFLINEPAY_PAYMENT_V1',
      _requiredString(payment, 'txn_id'),
      _requiredString(payment, 'request_id'),
      _requiredString(payment, 'customer_id'),
      _requiredString(payment, 'merchant_id'),
      _amount(payment),
      _requiredString(payment, 'token'),
      _requiredString(payment, 'allowance_id'),
      _requiredString(payment, 'device_id'),
      _requiredString(payment, 'payment_created_at'),
    ].join('\n');
  }

  // ---------------- ACK SIGNATURE MESSAGE ----------------

  static String _acknowledgementMessage(Map payment) {
    return [
      'OFFLINEPAY_ACK_V1',
      _requiredString(payment, 'txn_id'),
      _requiredString(payment, 'request_id'),
      _requiredString(payment, 'customer_id'),
      _requiredString(payment, 'merchant_id'),
      _amount(payment),
      _requiredString(payment, 'token'),
      _requiredString(payment, 'allowance_id'),
      _requiredString(payment, 'device_id'),
      _requiredString(payment, 'merchant_device_id'),
      _requiredString(payment, 'payment_created_at'),
      _requiredString(payment, 'acknowledgement_created_at'),
      _requiredString(payment, 'payer_signature'),
    ].join('\n');
  }

  // ---------------- SIGN DATA ----------------

  static Future<String> _sign(String message) async {
    final keyPair = await _getKeyPair();

    final signature = await _algorithm.sign(
      utf8.encode(message),
      keyPair: keyPair,
    );

    return base64Encode(signature.bytes);
  }

  // ---------------- VERIFY ED25519 SIGNATURE ----------------

  static Future<bool> verifySignature({
    required String publicKeyPem,
    required String signature,
    required String message,
  }) async {
    try {
      final lines = publicKeyPem
          .replaceAll('-----BEGIN PUBLIC KEY-----', '')
          .replaceAll('-----END PUBLIC KEY-----', '')
          .replaceAll(RegExp(r'\s+'), '');

      final der = base64Decode(lines);

      const prefixLength = 12;

      if (der.length != prefixLength + 32) {
        return false;
      }

      final publicKeyBytes =
          der.sublist(prefixLength);

      final publicKey = SimplePublicKey(
        publicKeyBytes,
        type: KeyPairType.ed25519,
      );

      return await _algorithm.verify(
        utf8.encode(message),
        signature: Signature(
          base64Decode(signature),
          publicKey: publicKey,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  // ---------------- PAYMENT REQUEST QR ----------------

  static Map request(
    String rid,
    String mid,
    String name,
    double amount,
  ) {
    if (!amount.isFinite || amount <= 0) {
      throw Exception('Enter a valid payment amount.');
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    return {
      'type': 'PAYMENT_REQUEST',
      'request_id': rid,
      'merchant_id': mid,
      'merchant_name': name,
      'amount': amount,
      'timestamp': now,
      'expiry': now + valid,
    };
  }

  // ---------------- CUSTOMER PAYMENT QR ----------------

  static Future<Map<String, dynamic>> createSignedPayment({
    required String transactionId,
    required String requestId,
    required String customerId,
    required String merchantId,
    required double amount,
    required String paymentToken,
    required String allowanceId,
  }) async {
    if (!amount.isFinite || amount <= 0) {
      throw Exception('Invalid payment amount.');
    }

    final now = DateTime.now();
    final currentDeviceId = await deviceId();

    final payload = <String, dynamic>{
      'type': 'PAYMENT',
      'txn_id': transactionId,
      'request_id': requestId,
      'customer_id': customerId,
      'merchant_id': merchantId,
      'amount': amount,
      'timestamp': now.millisecondsSinceEpoch,
      'expiry': now.millisecondsSinceEpoch + valid,
      'token': paymentToken,
      'allowance_id': allowanceId,
      'device_id': currentDeviceId,
      'payment_created_at': _utcTimestamp(now),
    };

    payload['payer_signature'] =
        await _sign(_paymentMessage(payload));

    return payload;
  }

  // ---------------- MERCHANT ACK QR ----------------

  static Future<Map<String, dynamic>> createSignedAck({
    required Map payment,
    required String merchantId,
  }) async {
    if (expired(payment)) {
      throw Exception('Customer payment QR has expired.');
    }

    final now = DateTime.now();
    final currentDeviceId = await deviceId();

    if (_requiredString(payment, 'merchant_id') != merchantId) {
      throw Exception('Payment belongs to another merchant.');
    }

    final payload = <String, dynamic>{
      'type': 'ACK',
      'txn_id': _requiredString(payment, 'txn_id'),
      'request_id': _requiredString(payment, 'request_id'),
      'customer_id': _requiredString(payment, 'customer_id'),
      'merchant_id': merchantId,
      'amount': payment['amount'],
      'timestamp': now.millisecondsSinceEpoch,
      'expiry': now.millisecondsSinceEpoch + valid,
      'token': _requiredString(payment, 'token'),
      'allowance_id': _requiredString(payment, 'allowance_id'),
      'device_id': _requiredString(payment, 'device_id'),
      'merchant_device_id': currentDeviceId,
      'payment_created_at':
          _requiredString(payment, 'payment_created_at'),
      'acknowledgement_created_at': _utcTimestamp(now),
      'payer_signature':
          _requiredString(payment, 'payer_signature'),
    };

    payload['merchant_ack_signature'] =
        await _sign(_acknowledgementMessage(payload));

    return payload;
  }

  // ---------------- LEGACY METHODS ----------------

  static Map payment(
    String tid,
    String rid,
    String cid,
    String mid,
    double amount,
    String tok,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;

    return {
      'type': 'PAYMENT',
      'txn_id': tid,
      'request_id': rid,
      'customer_id': cid,
      'merchant_id': mid,
      'amount': amount,
      'timestamp': now,
      'expiry': now + valid,
      'token': tok,
    };
  }

  static Map ack(Map p, String mid) {
    final now = DateTime.now().millisecondsSinceEpoch;

    return {
      'type': 'ACK',
      'txn_id': p['txn_id'],
      'request_id': p['request_id'],
      'customer_id': p['customer_id'],
      'merchant_id': mid,
      'amount': p['amount'],
      'timestamp': now,
      'expiry': now + valid,
      'token': p['token'],
    };
  }

  static Map confirm(Map p, String cid) {
    final now = DateTime.now().millisecondsSinceEpoch;

    return {
      'type': 'CONFIRMATION',
      'txn_id': p['txn_id'],
      'request_id': p['request_id'],
      'customer_id': cid,
      'merchant_id': p['merchant_id'],
      'amount': p['amount'],
      'timestamp': now,
      'expiry': now + valid,
      'token': p['token'],
    };
  }
}
