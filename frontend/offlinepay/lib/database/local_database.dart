import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._();

  static const String _databaseName = 'offlinepay.db';
  static const int _databaseVersion = 7;

  static Database? _database;

  // --------------------------------------------------
  // DATABASE INITIALIZATION
  // --------------------------------------------------

  static Future<Database> get database async {
    if (_database != null) return _database!;

    final dbPath = await getDatabasesPath();

    _database = await openDatabase(
      path.join(dbPath, _databaseName),
      version: _databaseVersion,
      onCreate: _createDatabase,
      onUpgrade: _upgradeDatabase,
    );

    return _database!;
  }

  static Future<void> _createDatabase(
  Database db,
  int version,
) async {
  await _createTables(db);

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_transactions_status
    ON transactions(sync_status)
  ''');
}

static Future<void> _upgradeDatabase(
  Database db,
  int oldVersion,
  int newVersion,
) async {
  await _createTables(db);

  await _ensureColumn(db, 'transactions', 'payload', 'TEXT');
  await _ensureColumn(
    db,
    'transactions',
    'sync_status',
    "TEXT NOT NULL DEFAULT 'PENDING'",
  );
  await _ensureColumn(db, 'transactions', 'role', 'TEXT');
  await _ensureColumn(db, 'transactions', 'updated_at', 'INTEGER');
  await _ensureColumn(db, 'transactions', 'allowance_id', 'TEXT');
  await _ensureColumn(db, 'transactions', 'synced_at', 'INTEGER');

  await _ensureColumn(
    db,
    'local_accounts',
    'offline_eligible',
    'INTEGER NOT NULL DEFAULT 0',
  );

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_transactions_status
    ON transactions(sync_status)
  ''');
}


static Future<void> _ensureColumn(
  DatabaseExecutor db,
  String table,
  String column,
  String definition,
) async {
  final columns = await db.rawQuery(
    'PRAGMA table_info($table)',
  );

  final exists = columns.any(
    (item) => item['name'] == column,
  );

  if (!exists) {
    await db.execute(
      'ALTER TABLE $table ADD COLUMN $column $definition',
    );
  }
}

static Future<void> _createTables(
  DatabaseExecutor db,
) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_users (
      user_id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      phone TEXT NOT NULL,
      email TEXT NOT NULL,
      role TEXT NOT NULL CHECK(role IN ('customer', 'merchant')),
      password_hash TEXT NOT NULL,
      synced INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_local_users_email
    ON local_users(email COLLATE NOCASE)
  ''');

  await db.execute('''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_local_users_phone
    ON local_users(phone)
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS registration_sync_queue (
      user_id TEXT PRIMARY KEY,
      payload TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'PENDING',
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_accounts (
      user_id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      email TEXT,
      phone TEXT,
      role TEXT NOT NULL,
      verified_balance REAL NOT NULL DEFAULT 0,
      reserved_balance REAL NOT NULL DEFAULT 0,
      provisional_credit REAL NOT NULL DEFAULT 0,
      currency TEXT NOT NULL DEFAULT 'INR',
      account_status TEXT NOT NULL DEFAULT 'ACTIVE',
      is_server_verified INTEGER NOT NULL DEFAULT 0,
      offline_eligible INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS offline_allowances (
      allowance_id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      allowance_amount REAL NOT NULL,
      spent_amount REAL NOT NULL DEFAULT 0,
      expires_at INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'ACTIVE',
      created_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS transactions (
      transaction_id TEXT PRIMARY KEY,
      request_id TEXT,
      customer_id TEXT,
      merchant_id TEXT,
      amount REAL NOT NULL,
      token TEXT,
      status TEXT NOT NULL DEFAULT 'PENDING',
      sync_status TEXT NOT NULL DEFAULT 'PENDING',
      role TEXT,
      timestamp INTEGER NOT NULL,
      expiry INTEGER,
      synced INTEGER NOT NULL DEFAULT 0,
      allowance_id TEXT,
      payload TEXT,
      updated_at INTEGER,
      synced_at INTEGER
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS trusted_devices (
      device_id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      public_key TEXT NOT NULL,
      key_algorithm TEXT NOT NULL DEFAULT 'Ed25519',
      active INTEGER NOT NULL DEFAULT 1,
      updated_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_trusted_devices_user
    ON trusted_devices(user_id)
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS processed_transactions (
      transaction_id TEXT PRIMARY KEY,
      processed_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_queue (
      transaction_id TEXT PRIMARY KEY,
      payload TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'PENDING',
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_transactions_customer
    ON transactions(customer_id)
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_transactions_merchant
    ON transactions(merchant_id)
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_sync_queue_status
    ON sync_queue(status)
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_allowances_user
    ON offline_allowances(user_id)
  ''');
}


  // --------------------------------------------------
  // OFFLINE REGISTRATION AND LOGIN
  // --------------------------------------------------

  static const int _passwordIterations = 120000;

  static final Pbkdf2 _passwordKdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _passwordIterations,
    bits: 256,
  );

  static Future<String> _hashPassword(String password) async {
    if (password.length < 8) {
      throw Exception('Password must contain at least 8 characters.');
    }

    final random = math.Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));

    final key = await _passwordKdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );

    final digest = await key.extractBytes();

    return 'pbkdf2_sha256\$$_passwordIterations\$${base64Encode(salt)}\$${base64Encode(digest)}';
  }

    static Future<bool> _verifyPassword(
    String password,
    String encoded,
  ) async {
    try {
      final parts = encoded.split(r'$');
      if (parts.length != 4 || parts[0] != 'pbkdf2_sha256') {
        return false;
      }

      final iterations = int.parse(parts[1]);
      if (iterations < 100000 || iterations > 500000) return false;

      final salt = base64Decode(parts[2]);
      final expected = base64Decode(parts[3]);

      final kdf = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: expected.length * 8,
      );

      final key = await kdf.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );

      final actual = await key.extractBytes();
      if (actual.length != expected.length) return false;

      var difference = 0;
      for (var i = 0; i < actual.length; i++) {
        difference |= actual[i] ^ expected[i];
      }

      return difference == 0;
    } catch (_) {
      return false;
    }
  }

  /// Offline registration is disabled. New accounts must be created by the server.
  /// This method remains temporarily for compatibility with older callers.
  static Future<Map<String, dynamic>> registerOfflineUser({
    required String name,
    required String phone,
    required String email,
    required String password,
    required String role,
    required String deviceId,
    double openingBalance = 0,
    int allowanceValidityHours = 24,
  }) async {
    throw Exception(
      'Offline registration is disabled. '
      'Please connect to the internet and register your account.',
    );
  }

  /// Cache an account only after successful server registration or login.
  /// This does not create bank funds or an offline spending allowance.
  static Future<void> cacheOnlineUser({
    required String userId,
    required String name,
    required String phone,
    required String email,
    required String password,
    required String role,
    double verifiedBalance = 0,
    double reservedBalance = 0,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final cleanRole = role.trim().toLowerCase();

    if (userId.trim().isEmpty || cleanEmail.isEmpty) {
      throw Exception('Invalid server account details.');
    }

    if (!{'customer', 'merchant'}.contains(cleanRole)) {
      throw Exception('Invalid account mode.');
    }

    if (!verifiedBalance.isFinite ||
        verifiedBalance < 0 ||
        !reservedBalance.isFinite ||
        reservedBalance < 0 ||
        reservedBalance > verifiedBalance) {
      throw Exception('Invalid server account balance.');
    }

    final passwordHash = await _hashPassword(password);
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      final existingAccounts = await txn.query(
        'local_accounts',
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1,
      );

      final existingAccount = existingAccounts.isEmpty
          ? <String, Object?>{}
          : existingAccounts.first;

      await txn.insert(
        'local_users',
        {
          'user_id': userId,
          'name': name.trim(),
          'phone': phone.trim(),
          'email': cleanEmail,
          'role': cleanRole,
          'password_hash': passwordHash,
          'synced': 1,
          'created_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.insert(
        'local_accounts',
        {
          'user_id': userId,
          'name': name.trim(),
          'email': cleanEmail,
          'phone': phone.trim(),
          'role': cleanRole,
          'verified_balance': verifiedBalance,
          'reserved_balance': reservedBalance,
          'provisional_credit':
              (existingAccount['provisional_credit'] as num?)?.toDouble() ?? 0,
          'currency': existingAccount['currency']?.toString() ?? 'INR',
          'account_status': 'ACTIVE',
          'is_server_verified': 1,
          'offline_eligible': existingAccount['offline_eligible'] == 1 ? 1 : 0,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Authenticates an account that was previously registered online and cached.
  /// The selected operating mode does not restrict the account identity.
  static Future<Map<String, dynamic>?> authenticateOfflineUser({
    required String email,
    required String password,
    required String role,
  }) async {
    final db = await database;
    final cleanEmail = email.trim().toLowerCase();
    final selectedRole = role.trim().toLowerCase();

    if (!{'customer', 'merchant'}.contains(selectedRole)) {
      throw Exception('Please select Customer or Merchant.');
    }

    final rows = await db.query(
      'local_users',
      where: 'email = ? COLLATE NOCASE AND synced = 1',
      whereArgs: [cleanEmail],
      limit: 1,
    );

    if (rows.isEmpty) return null;

    final user = Map<String, dynamic>.from(rows.first);

    final valid = await _verifyPassword(
      password,
      user['password_hash'].toString(),
    );

    if (!valid) return null;

    final account = await getLocalAccount(user['user_id'].toString());

    if (account == null) return null;
    if (account['is_server_verified'] != 1) return null;

    if (account['account_status'] != 'ACTIVE') {
      throw Exception('This account is not available for offline login.');
    }

    return {
      ...user,
      'verified_balance': account['verified_balance'],
      'reserved_balance': account['reserved_balance'],
      'provisional_credit': account['provisional_credit'],
      'account_status': account['account_status'],
      'is_server_verified': account['is_server_verified'],
      'offline_eligible': account['offline_eligible'],
      'selected_role': selectedRole,
    };
  }

  static Future<List<Map<String, dynamic>>> pendingRegistrations() async {
    final db = await database;

    final rows = await db.query(
      'registration_sync_queue',
      where: "status IN ('PENDING', 'FAILED')",
      orderBy: 'created_at ASC',
    );

    return rows.map((row) {
      final item = Map<String, dynamic>.from(row);
      item['payload'] = jsonDecode(item['payload'].toString());
      return item;
    }).toList();
  }

  static Future<void> markRegistrationSynced(
    String userId,
  ) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      await txn.update(
        'registration_sync_queue',
        {
          'status': 'SYNCED',
          'updated_at': now,
          'last_error': null,
        },
        where: 'user_id = ?',
        whereArgs: [userId],
      );

      await txn.update(
        'local_users',
        {'synced': 1},
        where: 'user_id = ?',
        whereArgs: [userId],
      );
    });
  }

  static Future<void> markRegistrationFailed(
    String userId,
    String error,
  ) async {
    final db = await database;

    await db.rawUpdate(
      '''
      UPDATE registration_sync_queue
      SET status = 'FAILED',
          attempts = attempts + 1,
          last_error = ?,
          updated_at = ?
      WHERE user_id = ?
      ''',
      [
        error,
        DateTime.now().millisecondsSinceEpoch,
        userId,
      ],
    );
  }

  static Future<Map<String, dynamic>?> localUserById(
    String userId,
  ) async {
    final db = await database;

    final rows = await db.query(
      'local_users',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );

    if (rows.isEmpty) return null;

    return Map<String, dynamic>.from(rows.first);
  }

  // --------------------------------------------------
  // LOCAL ACCOUNT METHODS
  // --------------------------------------------------

  static Future<void> saveAccount(
    Map<String, dynamic> account,
  ) async {
    final db = await database;
    final userId = account['user_id']?.toString();

    if (userId == null || userId.isEmpty) {
      throw Exception('Account user ID is required.');
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert(
      'local_accounts',
      {
        'user_id': userId,
        'name': account['name']?.toString() ?? '',
        'email': account['email']?.toString(),
        'phone': account['phone']?.toString(),
        'role': (account['role'] ?? 'customer').toString().toLowerCase(),
        'verified_balance': _number(
          account['verified_balance'] ?? account['balance'],
        ),
        'reserved_balance': _number(account['reserved_balance']),
        'provisional_credit': _number(account['provisional_credit']),
        'currency': account['currency']?.toString() ?? 'INR',
        'account_status': account['account_status']?.toString() ?? 'ACTIVE',
        'is_server_verified':
            account['is_server_verified'] == true ||
                    account['is_server_verified'] == 1
                ? 1
                : 0,
        'offline_eligible':
            account['offline_eligible'] == true ||
                    account['offline_eligible'] == 1
                ? 1
                : 0,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> getLocalAccount(
    String userId,
  ) async {
    final db = await database;

    final rows = await db.query(
      'local_accounts',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );

    if (rows.isEmpty) return null;

    return Map<String, dynamic>.from(rows.first);
  }

  static Future<double> getBalance(String userId) async {
    final account = await getLocalAccount(userId);

    if (account == null) return 0;

    return _number(account['verified_balance']);
  }

  static Future<double> getAvailableBalance(
    String userId,
  ) async {
    final account = await getLocalAccount(userId);

    if (account == null) return 0;

    final balance = _number(account['verified_balance']);
    final reserved = _number(account['reserved_balance']);

    return (balance - reserved).clamp(0, double.infinity);
  }

    // --------------------------------------------------
  // TRUSTED DEVICE PUBLIC KEYS
  // --------------------------------------------------

  /// Save or refresh a public key returned by the authenticated backend.
  static Future<void> saveTrustedDevice({
    required String deviceId,
    required String userId,
    required String publicKey,
    String keyAlgorithm = 'Ed25519',
    bool active = true,
  }) async {
    final cleanDeviceId = deviceId.trim();
    final cleanUserId = userId.trim();
    final cleanPublicKey = publicKey.trim();

    if (cleanDeviceId.isEmpty ||
        cleanUserId.isEmpty ||
        cleanPublicKey.isEmpty) {
      throw Exception('Trusted device details are incomplete.');
    }

    if (keyAlgorithm.trim().toLowerCase() != 'ed25519') {
      throw Exception('Unsupported device signing algorithm.');
    }

    final db = await database;

    await db.insert(
      'trusted_devices',
      {
        'device_id': cleanDeviceId,
        'user_id': cleanUserId,
        'public_key': cleanPublicKey,
        'key_algorithm': 'Ed25519',
        'active': active ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> getTrustedDevice({
    required String deviceId,
    String? userId,
  }) async {
    final db = await database;

    final rows = await db.query(
      'trusted_devices',
      where: userId == null
          ? 'device_id = ? AND active = 1'
          : 'device_id = ? AND user_id = ? AND active = 1',
      whereArgs: userId == null ? [deviceId] : [deviceId, userId],
      limit: 1,
    );

    if (rows.isEmpty) return null;

    return Map<String, dynamic>.from(rows.first);
  }

  static Future<String?> getTrustedDevicePublicKey({
    required String deviceId,
    String? userId,
  }) async {
    final device = await getTrustedDevice(
      deviceId: deviceId,
      userId: userId,
    );

    return device?['public_key']?.toString();
  }

  static Future<void> deactivateTrustedDevice(
    String deviceId,
  ) async {
    final db = await database;

    await db.update(
      'trusted_devices',
      {
        'active': 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  // --------------------------------------------------
// OFFLINE ALLOWANCE METHODS
// --------------------------------------------------

static Future<void> saveAllowance(
  Map<String, dynamic> allowance,
) async {
  final db = await database;

  final id = allowance['allowance_id']?.toString();
  final userId = allowance['user_id']?.toString();
  final deviceId = allowance['device_id']?.toString();

  if (id == null || id.isEmpty ||
      userId == null || userId.isEmpty ||
      deviceId == null || deviceId.isEmpty) {
    throw Exception('Invalid offline allowance.');
  }

  final amount = _number(allowance['allowance_amount']);
  final expiry = _integer(allowance['expires_at']);

  if (amount <= 0 || expiry <= 0) {
    throw Exception('Invalid allowance amount or expiry.');
  }

  await db.transaction((txn) async {
    final existing = await txn.query(
      'offline_allowances',
      where: 'allowance_id = ?',
      whereArgs: [id],
      limit: 1,
    );

    final now = DateTime.now().millisecondsSinceEpoch;

    if (existing.isNotEmpty) {
      final old = existing.first;
      final oldSpent = _number(old['spent_amount']);
      final serverSpent = _number(allowance['spent_amount']);
      final safeSpent = oldSpent > serverSpent
          ? oldSpent
          : serverSpent;

      await txn.update(
        'offline_allowances',
        {
          'allowance_amount': amount,
          'spent_amount': safeSpent,
          'expires_at': expiry,
          'status': allowance['status']?.toString() ?? 'ACTIVE',
        },
        where: 'allowance_id = ?',
        whereArgs: [id],
      );
    } else {
      await txn.insert(
        'offline_allowances',
        {
          'allowance_id': id,
          'user_id': userId,
          'device_id': deviceId,
          'allowance_amount': amount,
          'spent_amount': _number(allowance['spent_amount']),
          'expires_at': expiry,
          'status': allowance['status']?.toString() ?? 'ACTIVE',
          'created_at': now,
        },
      );
    }
  });
}


static Future<Map<String, dynamic>?> getAllowance(
  String allowanceId,
) async {
  final db = await database;

  final rows = await db.query(
    'offline_allowances',
    where: 'allowance_id = ?',
    whereArgs: [allowanceId],
    limit: 1,
  );

  if (rows.isEmpty) return null;

  return Map<String, dynamic>.from(rows.first);
}

static Future<Map<String, dynamic>?> getActiveAllowance({
  required String userId,
  required String deviceId,
}) async {
  final db = await database;

  final rows = await db.query(
    'offline_allowances',
    where: 'user_id = ? AND device_id = ? AND status = ?',
    whereArgs: [userId, deviceId, 'ACTIVE'],
    orderBy: 'created_at DESC',
    limit: 1,
  );

  if (rows.isEmpty) return null;

  return Map<String, dynamic>.from(rows.first);
}

static Future<bool> canSpendFromAllowance({
  required String allowanceId,
  required String userId,
  required String deviceId,
  required double amount,
}) async {
  if (amount <= 0 || !amount.isFinite) return false;

  final allowance = await getAllowance(allowanceId);

  if (allowance == null) return false;

  if (allowance['user_id'] != userId ||
      allowance['device_id'] != deviceId ||
      allowance['status'] != 'ACTIVE') {
    return false;
  }

  final expiry = _integer(allowance['expires_at']);

  if (DateTime.now().millisecondsSinceEpoch >= expiry) {
    return false;
  }

  final limit = _number(allowance['allowance_amount']);
  final spent = _number(allowance['spent_amount']);

  return amount <= limit - spent;
}

  // --------------------------------------------------
  // TRANSACTION METHODS
  // --------------------------------------------------

  static Future<void> save(
    Map<String, dynamic> transaction,
  ) async {
    final db = await database;

    final id = transaction['transaction_id']?.toString();

    if (id == null || id.isEmpty) {
      throw Exception('Transaction ID is required.');
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert(
      'transactions',
      {
        'transaction_id': id,
        'request_id': transaction['request_id']?.toString(),
        'customer_id': transaction['customer_id']?.toString(),
        'merchant_id': transaction['merchant_id']?.toString(),
        'amount': _number(transaction['amount']),
        'token': transaction['token']?.toString(),
        'status': transaction['status']?.toString() ?? 'PENDING',
        'sync_status': transaction['sync_status']?.toString() ?? 'PENDING',
        'role': transaction['role']?.toString(),
        'timestamp': _integer(transaction['timestamp'] ?? now),
        'expiry': transaction['expiry'] == null
            ? null
            : _integer(transaction['expiry']),
        'synced': transaction['synced'] == true ||
                transaction['synced'] == 1
            ? 1
            : 0,
        'allowance_id': transaction['allowance_id']?.toString(),
        'payload': jsonEncode(
          transaction['payload'] is Map
        ? transaction['payload']
        : transaction,
        ),
        'updated_at': now,
    },
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  static Future<Map<String, dynamic>?> getTransactionById(
    String transactionId,
  ) async {
    final db = await database;

    final rows = await db.query(
      'transactions',
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
      limit: 1,
    );

    if (rows.isEmpty) return null;

    final row = Map<String, dynamic>.from(rows.first);
    final rawPayload = row['payload'];

    if (rawPayload != null) {
      try {
        final decoded = jsonDecode(rawPayload.toString());

        if (decoded is Map) {
          return {
            ...Map<String, dynamic>.from(decoded),
            ...row,
          };
        }
      } catch (_) {
        // Fall back to the database columns.
      }
    }

    return row;
  }

  static Future<void> updateAllowanceId(
    String transactionId,
    String allowanceId,
  ) async {
    final db = await database;

    await db.update(
      'transactions',
      {
        'allowance_id': allowanceId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
    );
  }

    // --------------------------------------------------
  // CUSTOMER PHONE: RECORD DEBIT AFTER ACK
  // --------------------------------------------------

  static Future<void> recordCustomerDebit({
    required String transactionId,
    required String userId,
    required String allowanceId,
    required String deviceId,
    required double amount,
    required Map<String, dynamic> signedPayload,
  }) async {
    if (amount <= 0 || !amount.isFinite) {
      throw Exception('Invalid payment amount.');
    }

    final db = await database;

    await db.transaction((txn) async {
      final existing = await txn.query(
        'transactions',
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
        limit: 1,
      );

      Map<String, dynamic>? draft;

      if (existing.isNotEmpty) {
        draft = Map<String, dynamic>.from(existing.first);

        // Only a previously saved payment QR draft may be finalized.
        if (draft['status'] != 'PAYMENT_QR' ||
            draft['sync_status'] != 'PENDING') {
          throw Exception('This transaction has already been processed.');
        }

        if (draft['customer_id'] != userId ||
            draft['allowance_id'] != allowanceId ||
            _number(draft['amount']) != amount) {
          throw Exception('Saved payment details do not match.');
        }
      }

      final allowanceRows = await txn.query(
        'offline_allowances',
        where: 'allowance_id = ?',
        whereArgs: [allowanceId],
        limit: 1,
      );

      if (allowanceRows.isEmpty) {
        throw Exception('Offline allowance not found.');
      }

      final allowance = allowanceRows.first;

      if (allowance['user_id'] != userId ||
          allowance['device_id'] != deviceId ||
          allowance['status'] != 'ACTIVE') {
        throw Exception('Offline allowance is not valid.');
      }

      final expiry = _integer(allowance['expires_at']);

      if (DateTime.now().millisecondsSinceEpoch >= expiry) {
        throw Exception('Offline allowance has expired.');
      }

      final limit = _number(allowance['allowance_amount']);
      final spent = _number(allowance['spent_amount']);

      if (amount > limit - spent) {
        throw Exception('Offline allowance limit exceeded.');
      }

      final accountRows = await txn.query(
        'local_accounts',
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1,
      );

      if (accountRows.isEmpty) {
        throw Exception('Customer local account not found.');
      }

      final account = accountRows.first;

      // A locally registered demo account may spend its locally
      // provisioned demo balance before its registration is synchronized.
      // Server-verified accounts may spend only against their downloaded
      // server-authorized allowance.
      if (account['is_server_verified'] != 1) {
  throw Exception(
    'Only server-verified accounts can make offline payments.',
  );
}

      final balance = _number(account['verified_balance']);
      final reserved = _number(account['reserved_balance']);

      // This payment spends from the money reserved in the allowance.
      if (amount > balance || amount > reserved) {
        throw Exception('Insufficient reserved demo/bank balance.');
      }

      final now = DateTime.now().millisecondsSinceEpoch;

      // Debit both the account balance and its reserved amount atomically.
      await txn.update(
        'local_accounts',
        {
          'verified_balance': balance - amount,
          'reserved_balance': reserved - amount,
          'updated_at': now,
        },
        where: 'user_id = ?',
        whereArgs: [userId],
      );

      await txn.update(
        'offline_allowances',
        {
          'spent_amount': spent + amount,
        },
        where: 'allowance_id = ?',
        whereArgs: [allowanceId],
      );

      final transactionData = {
        'transaction_id': transactionId,
        'request_id': signedPayload['request_id']?.toString(),
        'customer_id': userId,
        'merchant_id': signedPayload['merchant_id']?.toString(),
        'amount': amount,
        'token': signedPayload['token']?.toString(),
        'status': 'PENDING_SYNC',
        'sync_status': 'PENDING',
        'role': 'customer',
        'timestamp': now,
        'expiry': signedPayload['expiry'] == null
            ? null
            : _integer(signedPayload['expiry']),
        'synced': 0,
        'allowance_id': allowanceId,
        'payload': jsonEncode(signedPayload),
        'updated_at': now,
      };

      if (draft != null) {
        await txn.update(
          'transactions',
          transactionData,
          where: 'transaction_id = ?',
          whereArgs: [transactionId],
        );
      } else {
        await txn.insert(
          'transactions',
          transactionData,
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }

      await _insertSyncQueue(
        txn,
        transactionId,
        signedPayload,
        now,
      );
    });
  }

  // --------------------------------------------------
  // MERCHANT PHONE: RECORD PROVISIONAL CREDIT
  // --------------------------------------------------

  static Future<void> recordMerchantCredit({
    required String transactionId,
    required String merchantId,
    required double amount,
    required Map<String, dynamic> signedPayload,
  }) async {
    if (amount <= 0 || !amount.isFinite) {
      throw Exception('Invalid payment amount.');
    }

    final db = await database;

    await db.transaction((txn) async {
      final existing = await txn.query(
        'transactions',
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
        limit: 1,
      );

      if (existing.isNotEmpty) {
        throw Exception('This transaction was already recorded.');
      }

      final accountRows = await txn.query(
        'local_accounts',
        where: 'user_id = ?',
        whereArgs: [merchantId],
        limit: 1,
      );

      if (accountRows.isEmpty) {
        throw Exception('Merchant local account not found.');
      }

      final account = accountRows.first;
      final now = DateTime.now().millisecondsSinceEpoch;

      final provisional = _number(
        account['provisional_credit'],
      );

      await txn.update(
        'local_accounts',
        {
          'provisional_credit': provisional + amount,
          'updated_at': now,
        },
        where: 'user_id = ?',
        whereArgs: [merchantId],
      );

      await txn.insert(
        'transactions',
        {
          'transaction_id': transactionId,
          'request_id': signedPayload['request_id']?.toString(),
          'customer_id': signedPayload['customer_id']?.toString(),
          'merchant_id': merchantId,
          'amount': amount,
          'token': signedPayload['token']?.toString(),
          'status': 'PENDING_SYNC',
          'sync_status': 'PENDING',
          'role': 'merchant',
          'timestamp': now,
          'expiry': signedPayload['expiry'] == null
              ? null
              : _integer(signedPayload['expiry']),
          'synced': 0,
          'allowance_id': signedPayload['allowance_id']?.toString(),
          'payload': jsonEncode(signedPayload),
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

      await _insertSyncQueue(
        txn,
        transactionId,
        signedPayload,
        now,
      );
    });
  }

    // --------------------------------------------------
  // SYNC QUEUE
  // --------------------------------------------------

  static Future<void> _insertSyncQueue(
    Transaction txn,
    String transactionId,
    Map<String, dynamic> payload,
    int now,
  ) async {
    await txn.insert(
      'sync_queue',
      {
        'transaction_id': transactionId,
        'payload': jsonEncode(payload),
        'status': 'PENDING',
        'attempts': 0,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  static Future<void> queueForSync(
    String transactionId,
    Map<String, dynamic> payload,
  ) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert(
      'sync_queue',
      {
        'transaction_id': transactionId,
        'payload': jsonEncode(payload),
        'status': 'PENDING',
        'attempts': 0,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<List<Map<String, dynamic>>> pendingSync() async {
    final db = await database;

    final rows = await db.query(
      'sync_queue',
      where: "status IN ('PENDING', 'FAILED')",
      orderBy: 'created_at ASC',
    );

    return rows
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  static Future<void> markSyncAttempt(
    String transactionId, {
    String? error,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.rawUpdate(
      '''
      UPDATE sync_queue
      SET attempts = attempts + 1,
          status = ?,
          last_error = ?,
          updated_at = ?
      WHERE transaction_id = ?
      ''',
      [
        error == null ? 'PENDING' : 'FAILED',
        error,
        now,
        transactionId,
      ],
    );
  }

  static Future<void> markSynced(
    String transactionId,
  ) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      await txn.update(
        'transactions',
        {
          'status': 'COMPLETED',
          'sync_status': 'SYNCED',
          'synced': 1,
          'synced_at': now,
          'updated_at': now,
        },
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
      );

      await txn.update(
        'sync_queue',
        {
          'status': 'SYNCED',
          'updated_at': now,
          'last_error': null,
        },
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
      );

      await txn.insert(
        'processed_transactions',
        {
          'transaction_id': transactionId,
          'processed_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
  }

  // --------------------------------------------------
  // LEGACY COMPATIBILITY METHODS
  // --------------------------------------------------

  static Future<bool> processed(
    String transactionId,
  ) async {
    final db = await database;

    final rows = await db.query(
      'processed_transactions',
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
      limit: 1,
    );

    return rows.isNotEmpty;
  }

  static Future<void> mark(
    String transactionId,
  ) async {
    await markSynced(transactionId);
  }

  static Future<void> updateStatus(
    String transactionId, {
    required String status,
    required String syncStatus,
  }) async {
    final db = await database;

    await db.update(
      'transactions',
      {
        'status': status,
        'sync_status': syncStatus,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
    );
  }

  // --------------------------------------------------
  // TRANSACTION HISTORY
  // --------------------------------------------------

  static Future<List<Map<String, dynamic>>> history() async {
    final db = await database;

    final rows = await db.query(
      'transactions',
      orderBy: 'timestamp DESC',
    );

    return rows
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  // --------------------------------------------------
  // SMALL HELPERS
  // --------------------------------------------------

  static double _number(dynamic value) {
    if (value is num) return value.toDouble();

    return double.tryParse(
          value?.toString() ?? '',
        ) ??
        0;
  }

  static int _integer(dynamic value) {
    if (value is int) return value;

    if (value is num) return value.toInt();

    return int.tryParse(
          value?.toString() ?? '',
        ) ??
        0;
  }

  // --------------------------------------------------
  // CLOSE DATABASE
  // --------------------------------------------------

  static Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}