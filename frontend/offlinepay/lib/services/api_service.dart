import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../database/local_database.dart';
import 'qr_service.dart';

/// Offline-first API/session facade for OfflinePay.
///
/// Registration is online-only. Login is online-first and falls back to a
/// previously cached, server-verified account only when the network is
/// unavailable. Customer and Merchant are operating modes, not separate
/// permanent accounts.
class ApiService {
  ApiService._();

  static const Duration _timeout = Duration(seconds: 15);

  // ------------------------------------------------------------
  // DEVICE ID
  // ------------------------------------------------------------

  /// Use the same installation identity as QrService's signing key.
  static Future<String> deviceId() => QrService.deviceId();

  // ------------------------------------------------------------
  // LOCAL SESSION
  // ------------------------------------------------------------

  static Future<void> save(Map data) async {
    final prefs = await SharedPreferences.getInstance();
    final tokenValue = data['access_token'] ?? data['token'];
    if (tokenValue != null && tokenValue.toString().isNotEmpty) {
      await prefs.setString('token', tokenValue.toString());
    }

    final user = _userData(data);
    for (final key in ['user_id', 'name', 'email']) {
      if (user[key] != null) {
        await prefs.setString(key, user[key].toString());
      }
    }
    if (user['role'] != null) {
      await prefs.setString('role', user['role'].toString().toLowerCase());
    }
  }

  static Future<String?> token() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('token');
  }

  static Future<String?> userId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('user_id');
  }

  static Future<String?> userName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('name');
  }

  static Future<String?> userRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('role');
  }

  static Future<String?> lastEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('last_email');
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in ['token', 'user_id', 'role', 'name', 'email']) {
      await prefs.remove(key);
    }
    // Keep selected_role, cached credentials, account data and offline work.
  }

  static Future<void> _saveLocalSession(
    Map<String, dynamic> user, {
    required String selectedRole,
    String? accessToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final id = user['user_id']?.toString();
    if (id == null || id.isEmpty) {
      throw Exception('The server did not return a valid user ID.');
    }

    await prefs.setString('user_id', id);
    await prefs.setString('name', (user['name'] ?? '').toString());
    await prefs.setString('email', (user['email'] ?? '').toString());
    await prefs.setString('last_email', (user['email'] ?? '').toString());
    await prefs.setString(
      'role',
      (user['role'] ?? selectedRole).toString().toLowerCase(),
    );
    await prefs.setString('selected_role', selectedRole);

    if (accessToken != null && accessToken.isNotEmpty) {
      await prefs.setString('token', accessToken);
    }
  }

  // ------------------------------------------------------------
  // OPERATING MODE
  // ------------------------------------------------------------

  static Future<void> setSelectedRole(String role) async {
    final normalized = role.trim().toLowerCase();
    if (normalized != 'customer' && normalized != 'merchant') {
      throw Exception('Please select Customer or Merchant.');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_role', normalized);
  }

  static Future<String> selectedRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('selected_role') ?? 'customer';
  }

  // ------------------------------------------------------------
  // REGISTRATION AND LOGIN
  // ------------------------------------------------------------

  /// Creates the real account on the backend. Registration is never local-only.
  static Future<Map> signup(
    String n,
    String ph,
    String e,
    String pw,
    String r,
  ) async {
    final role = r.trim().toLowerCase();
    if (role != 'customer' && role != 'merchant') {
      throw Exception('Please select Customer or Merchant.');
    }
    if (n.trim().isEmpty ||
        ph.trim().isEmpty ||
        e.trim().isEmpty ||
        pw.isEmpty) {
      throw Exception('Please fill in all registration details.');
    }

    final response = await _publicPost('/auth/signup', {
      'name': n.trim(),
      'phone': ph.trim(),
      'email': e.trim().toLowerCase(),
      'password': pw,
      'role': role,
    });
    final data = _decodeMap(response);
    final accessToken = _accessToken(data);
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('Registration succeeded without a login token. Please log in.');
    }

    final user = _userData(data);
    user['email'] ??= e.trim().toLowerCase();
    user['name'] ??= n.trim();
    user['phone'] ??= ph.trim();
    user['role'] ??= role;

    await save(data);
    await _saveLocalSession(
      Map<String, dynamic>.from(user),
      selectedRole: role,
      accessToken: accessToken,
    );

    // Fetch the real bank account balance after authentication, when available.
    final bank = await _tryFetchBankAccount();
    final balance = _number(
      bank?['balance'] ??
          user['balance'] ??
          user['verified_balance'] ??
          data['balance'] ??
          data['verified_balance'],
    );
    final reserved = _number(
      bank?['reserved_balance'] ??
          user['reserved_balance'] ??
          data['reserved_balance'],
    );

    await LocalDatabase.cacheOnlineUser(
      userId: user['user_id'].toString(),
      name: user['name'].toString(),
      phone: user['phone'].toString(),
      email: user['email'].toString(),
      password: pw,
      role: role,
      verifiedBalance: balance,
      reservedBalance: reserved <= balance ? reserved : 0,
    );

    return {
      ...user,
      'access_token': accessToken,
      'balance': balance,
      'selected_role': role,
    };
  }

  /// Try server login first. Only connectivity failures permit offline login.
  /// Invalid credentials and server-side account errors are never bypassed.
  static Future<Map> login(
    String e,
    String pw, {
    String role = 'customer',
  }) async {
    final selected = role.trim().toLowerCase();
    if (selected != 'customer' && selected != 'merchant') {
      throw Exception('Please select Customer or Merchant.');
    }
    if (e.trim().isEmpty || pw.isEmpty) {
      throw Exception('Please enter your email and password.');
    }

    try {
      final response = await _publicPost('/auth/login', {
        'email': e.trim().toLowerCase(),
        'password': pw,
      });
      final data = _decodeMap(response);
      final accessToken = _accessToken(data);
      if (accessToken == null || accessToken.isEmpty) {
        throw Exception('The server did not return a login token.');
      }

      final user = _userData(data);
      user['email'] ??= e.trim().toLowerCase();
      user['role'] ??= selected;
      final id = user['user_id']?.toString();
      if (id == null || id.isEmpty) {
        throw Exception('The server did not return a valid user ID.');
      }

      await save(data);
      await _saveLocalSession(
        Map<String, dynamic>.from(user),
        selectedRole: selected,
        accessToken: accessToken,
      );

      final bank = await _tryFetchBankAccount();
      final existing = await LocalDatabase.getLocalAccount(id);
      final balance = _number(
        bank?['balance'] ??
            user['balance'] ??
            user['verified_balance'] ??
            existing?['verified_balance'] ??
            0,
      );
      final reserved = _number(
        bank?['reserved_balance'] ??
            user['reserved_balance'] ??
            existing?['reserved_balance'] ??
            0,
      );

      await LocalDatabase.cacheOnlineUser(
        userId: id,
        name: (user['name'] ?? existing?['name'] ?? '').toString(),
        phone: (user['phone'] ?? existing?['phone'] ?? '').toString(),
        email: (user['email'] ?? e).toString(),
        password: pw,
        role: (user['role'] ?? selected).toString(),
        verifiedBalance: balance,
        reservedBalance: reserved <= balance ? reserved : 0,
      );

      return {
        ...user,
        'access_token': accessToken,
        'balance': balance,
        'selected_role': selected,
      };
    } on _NetworkException {
      final user = await LocalDatabase.authenticateOfflineUser(
        email: e,
        password: pw,
        role: selected,
      );
      if (user == null) {
        throw Exception(
          'Offline login is not available for this account on this phone. '
          'Please connect to the internet and log in once first.',
        );
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_email', e.trim().toLowerCase());
      await prefs.setString('selected_role', selected);
      await prefs.setString('user_id', user['user_id'].toString());
      await prefs.setString('name', user['name'].toString());
      await prefs.setString('email', user['email'].toString());
      await prefs.setString('role', user['role'].toString().toLowerCase());
      return {...user, 'selected_role': selected, 'offline_login': true};
    }
  }

  // ------------------------------------------------------------
  // PASSWORD RESET (ONLINE ONLY)
  // ------------------------------------------------------------

  static Future<void> requestPasswordReset(String email) async {
    final response = await _publicPost('/auth/forgot-password', {
      'email': email.trim().toLowerCase(),
    });
    _check(response);
  }

  static Future<void> resetPassword(
    String resetToken,
    String newPassword,
  ) async {
    final response = await _publicPost('/auth/reset-password', {
      'token': resetToken,
      'new_password': newPassword,
    });
    _check(response);
  }

  // ------------------------------------------------------------
  // USER AND BANK INFORMATION
  // ------------------------------------------------------------

  static Future<Map> me() async {
    try {
      final response = await _get('/users/me');
      final data = _decodeMap(response);
      await _cacheProfile(data);
      return data;
    } on _NetworkException {
      return _localProfile();
    }
  }

  static Future<Map> bankAccount() async {
    try {
      final response = await _get('/bank/account');
      final data = _decodeMap(response);
      await _cacheBankAccount(data);
      return data;
    } on _NetworkException {
      final profile = await _localProfile();
      final account = await LocalDatabase.getLocalAccount(
        profile['user_id'].toString(),
      );
      if (account == null) {
        throw Exception('Local bank account data is unavailable.');
      }
      return {
        'user_id': profile['user_id'],
        'account_holder': profile['name'],
        'account_number': account['account_number'] ?? 'OFFLINE',
        'account_type': account['account_type'] ?? 'Bank Account',
        'balance': account['verified_balance'] ?? 0,
        'reserved_balance': account['reserved_balance'] ?? 0,
        'provisional_credit': account['provisional_credit'] ?? 0,
        'status': account['account_status'] ?? 'ACTIVE',
        'is_server_verified': account['is_server_verified'] == 1,
        'offline_eligible': account['offline_eligible'] == 1,
      };
    }
  }

  static Future<Map> wallet() => bankAccount();

  static Future<List> bankStatement() async {
    final response = await _get('/bank/statement');
    return _decodeList(response);
  }

  static Future<Map> _localProfile() async {
    final id = await userId();
    if (id == null || id.isEmpty) {
      throw Exception('No user is currently logged in.');
    }
    final account = await LocalDatabase.getLocalAccount(id);
    if (account == null || account['is_server_verified'] != 1) {
      throw Exception('Verified local account data is unavailable.');
    }
    return {
      ...account,
      'balance': account['verified_balance'] ?? 0,
      'user_id': id,
      'is_server_verified': true,
    };
  }

  static Future<void> _cacheProfile(Map data) async {
    final user = _userData(data);
    final id = user['user_id']?.toString();
    if (id == null || id.isEmpty) return;
    final existing = await LocalDatabase.getLocalAccount(id);
    if (existing == null) return;

    await LocalDatabase.saveAccount({
      ...existing,
      'user_id': id,
      'name': user['name'] ?? existing['name'] ?? '',
      'email': user['email'] ?? existing['email'],
      'phone': user['phone'] ?? existing['phone'],
      'role': user['role'] ?? existing['role'] ?? 'customer',
      // Do not overwrite cached balances from the profile endpoint.
      'verified_balance': existing['verified_balance'] ?? 0,
      'reserved_balance': existing['reserved_balance'] ?? 0,
      'provisional_credit': existing['provisional_credit'] ?? 0,
      'currency': 'INR',
      'account_status': user['account_status'] ??
          user['status'] ??
          existing['account_status'] ??
          'ACTIVE',
      'is_server_verified': true,
      'offline_eligible': existing['offline_eligible'] == 1 ||
          existing['offline_eligible'] == true,
    });
  }

  static Future<void> _cacheBankAccount(Map data) async {
    final id = data['user_id']?.toString() ?? await userId();
    if (id == null || id.isEmpty) return;
    final existing = await LocalDatabase.getLocalAccount(id);
    if (existing == null) return;

    final balance = _number(
      data['balance'] ?? data['verified_balance'] ?? existing['verified_balance'],
    );
    final reserved = _number(
      data['reserved_balance'] ?? existing['reserved_balance'],
    );
    await LocalDatabase.saveAccount({
      ...existing,
      'user_id': id,
      'verified_balance': balance,
      'reserved_balance': reserved <= balance ? reserved : 0,
      'provisional_credit': existing['provisional_credit'] ?? 0,
      'account_number': data['account_number'] ?? existing['account_number'],
      'account_type': data['account_type'] ?? existing['account_type'],
      'account_status': data['status'] ??
          data['account_status'] ??
          existing['account_status'] ??
          'ACTIVE',
      'is_server_verified': true,
      'offline_eligible': existing['offline_eligible'] == 1 ||
          existing['offline_eligible'] == true,
    });
  }

  static Future<Map?> _tryFetchBankAccount() async {
    try {
      final response = await _get('/bank/account');
      return _decodeMap(response);
    } on _NetworkException {
      return null;
    }
  }

  // ------------------------------------------------------------
  // DEVICE REGISTRATION AND OFFLINE ALLOWANCES
  // ------------------------------------------------------------

  static Future<Map> registerDevice({
    required String deviceId,
    required String deviceName,
    required String publicKey,
    String keyAlgorithm = 'Ed25519',
  }) async {
    final response = await _post('/devices/register', {
      'device_id': deviceId,
      'device_name': deviceName,
      'public_key': publicKey,
      'key_algorithm': keyAlgorithm,
    });
    return _decodeMap(response);
  }

  /// Retrieves the public signing key of another registered device.
  /// Used to verify offline payment and acknowledgement signatures.
  static Future<Map> getDevicePublicKey(String deviceId) async {
    if (deviceId.trim().isEmpty) {
      throw Exception('Device ID is required.');
    }

    final response = await _get(
      '/devices/${Uri.encodeComponent(deviceId)}/public-key',
    );

    final data = _decodeMap(response);

    if (data['public_key'] == null ||
        data['key_algorithm']?.toString().toLowerCase() != 'ed25519') {
      throw Exception('Invalid or unsupported device public key.');
    }

    return data;
  }
    /// Downloads the backend-signed certificate for this device.
  static Future<Map<String, dynamic>> getDeviceCertificate(
    String deviceId,
  ) async {
    if (deviceId.trim().isEmpty) {
      throw Exception('Device ID is required.');
    }

    final response = await _get(
      '/devices/${Uri.encodeComponent(deviceId)}/certificate',
    );

    final data = _decodeMap(response);

    if (data['certificate'] is! Map ||
        data['signature'] == null) {
      throw Exception('Invalid device certificate response.');
    }

    return Map<String, dynamic>.from(data);
  }

  static Future<Map> createAllowance({
    required String deviceId,
    required double amount,
  }) async {
    if (!amount.isFinite || amount <= 0) {
      throw Exception('Allowance amount must be greater than zero.');
    }
    final response = await _post('/allowances/create', {
      'device_id': deviceId,
      'amount': amount,
    });
    return _decodeMap(response);
  }
    // ------------------------------------------------------------
  // PROVISION AND DOWNLOAD OFFLINE ALLOWANCE
  // ------------------------------------------------------------

  static Future<Map<String, dynamic>> provisionOfflineAllowance({
    required double amount,
  }) async {
    if (!amount.isFinite || amount <= 0) {
      throw Exception('Enter a valid allowance amount.');
    }

    final currentUserId = await userId();

    if (currentUserId == null || currentUserId.isEmpty) {
      throw Exception('Please log in before preparing offline payments.');
    }

    // Use the same device identity as the QR signing key.
    final currentDeviceId = await deviceId();
    final publicKey = await QrService.publicKeyPem();

    if (currentDeviceId.isEmpty || publicKey.trim().isEmpty) {
      throw Exception('Unable to identify this device securely.');
    }

    // 1. Register the device with the backend.
    await registerDevice(
      deviceId: currentDeviceId,
      deviceName: 'OfflinePay Android Device',
      publicKey: publicKey,
      keyAlgorithm: 'Ed25519',
    );
    final certificate = await getDeviceCertificate(currentDeviceId);

    await QrService.saveDeviceCertificate(
      certificate,
      expectedUserId: currentUserId,
    );
    // 2. Request a new allowance or retrieve the existing active one.
    final response = await createAllowance(
      deviceId: currentDeviceId,
      amount: amount,
    );

    final allowance = Map<String, dynamic>.from(response);

    // 3. Verify that the server returned the correct account and device.
    if (allowance['allowance_id'] == null ||
        allowance['user_id']?.toString() != currentUserId ||
        allowance['device_id']?.toString() != currentDeviceId) {
      throw Exception('The server returned an invalid allowance.');
    }

    final active = allowance['active'] == true ||
        allowance['active'].toString().toLowerCase() == 'true';

    if (!active) {
      throw Exception('The server allowance is not active.');
    }

    // 4. Convert the backend ISO timestamp to milliseconds.
    final expiryMillis = _allowanceExpiryMillis(
      allowance['expires_at'],
    );

    if (expiryMillis <= DateTime.now().millisecondsSinceEpoch) {
      throw Exception('The downloaded allowance has expired.');
    }

    // 5. Save the trusted signing key locally.
    await LocalDatabase.saveTrustedDevice(
      deviceId: currentDeviceId,
      userId: currentUserId,
      publicKey: publicKey,
      keyAlgorithm: 'Ed25519',
      active: true,
    );

    // 6. Save the server-authorized allowance in SQLite.
    await LocalDatabase.saveAllowance({
      'allowance_id': allowance['allowance_id'].toString(),
      'user_id': currentUserId,
      'device_id': currentDeviceId,
      'allowance_amount': allowance['allowance_amount'],
      'spent_amount': allowance['spent_amount'] ?? 0,
      'expires_at': expiryMillis,
      'status': 'ACTIVE',
    });

    // 7. Refresh the local bank balance and reserved balance.
    await bankAccount();

    // Return the saved allowance.
    final saved = await LocalDatabase.getActiveAllowance(
      userId: currentUserId,
      deviceId: currentDeviceId,
    );

    if (saved == null) {
      throw Exception('Allowance could not be saved on this device.');
    }

    return saved;
  }

  static int _allowanceExpiryMillis(dynamic value) {
    if (value is num) {
      final number = value.toInt();

      // Support either seconds or milliseconds.
      return number < 1000000000000 ? number * 1000 : number;
    }

    final raw = value?.toString().trim() ?? '';

    if (raw.isEmpty) {
      throw Exception('The server did not return an allowance expiry.');
    }

    // Backend currently sends naive UTC ISO timestamps.
    // Treat timestamps without a timezone as UTC, not local time.
    final hasTimezone = RegExp(
      r'(Z|[+-]\d{2}:\d{2})$',
      caseSensitive: false,
    ).hasMatch(raw);

    final parsed = DateTime.parse(
      hasTimezone ? raw : '${raw}Z',
    );

    return parsed.toUtc().millisecondsSinceEpoch;
  }

  static Future<Map> getAllowance(String allowanceId) async {
    final response = await _get(
      '/allowances/${Uri.encodeComponent(allowanceId)}',
    );
    return _decodeMap(response);
  }

  static Future<Map> releaseAllowance(String allowanceId) async {
    final response = await _post(
      '/allowances/${Uri.encodeComponent(allowanceId)}/release',
      <String, dynamic>{},
    );
    return _decodeMap(response);
  }

  // ------------------------------------------------------------
  // TRANSACTIONS
  // ------------------------------------------------------------

  static Future<List> transactions() async {
    final response = await _get('/transactions');
    return _decodeList(response);
  }

  static Future<Map> syncPayment(Map data) async {
    final response = await _post('/transactions/sync', data);
    return _decodeMap(response);
  }

  /// Legacy compatibility only. Secure settlement uses signed /sync.
  static Future<Map> complete(Map data) async {
    final response = await _post('/transactions/complete', data);
    return _decodeMap(response);
  }

  // ------------------------------------------------------------
  // HTTP HELPERS
  // ------------------------------------------------------------

  static Future<http.Response> _publicPost(
    String path,
    Map data,
  ) async {
    try {
      return await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(data),
          )
          .timeout(_timeout);
    } on SocketException {
      throw _NetworkException('No internet connection.');
    } on TimeoutException {
      throw _NetworkException('Server timed out.');
    } on http.ClientException {
      throw _NetworkException('Unable to connect to OfflinePay server.');
    }
  }

  static Future<http.Response> _get(String path) async {
    final accessToken = await token();
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('Please log in online before using this feature.');
    }
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}$path'),
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(_timeout);
      _check(response);
      return response;
    } on SocketException {
      throw _NetworkException('No internet connection.');
    } on TimeoutException {
      throw _NetworkException('Request timed out.');
    } on http.ClientException {
      throw _NetworkException('Unable to connect to OfflinePay server.');
    }
  }

  static Future<http.Response> _post(String path, Map data) async {
    final accessToken = await token();
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('Please log in online before using this feature.');
    }
    try {
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}$path'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(data),
          )
          .timeout(_timeout);
      _check(response);
      return response;
    } on SocketException {
      throw _NetworkException('No internet connection.');
    } on TimeoutException {
      throw _NetworkException('Request timed out.');
    } on http.ClientException {
      throw _NetworkException('Unable to connect to OfflinePay server.');
    }
  }

  // ------------------------------------------------------------
  // RESPONSE HELPERS
  // ------------------------------------------------------------

  static Map _decodeMap(http.Response response) {
    _check(response);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw Exception('Unexpected OfflinePay server response.');
    }
    return decoded;
  }

  static List _decodeList(http.Response response) {
    _check(response);
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw Exception('Unexpected OfflinePay server response.');
    }
    return decoded;
  }

  static void _check(http.Response response) {
    if (response.statusCode < 400) return;
    var message = 'Request failed (${response.statusCode}).';
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) {
        message = body['detail'].toString();
      }
    } catch (_) {
      // Keep the generic message if the response is not JSON.
    }
    throw Exception(message);
  }

  static Map<String, dynamic> _userData(Map data) {
    final nested = data['user'];
    if (nested is Map) {
      return Map<String, dynamic>.from(nested);
    }
    return Map<String, dynamic>.from(data);
  }

  static String? _accessToken(Map data) {
    final value = data['access_token'] ?? data['token'];
    return value?.toString();
  }

  static double _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _NetworkException implements Exception {
  final String message;
  const _NetworkException(this.message);

  @override
  String toString() => message;
}
