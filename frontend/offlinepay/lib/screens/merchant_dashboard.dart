
import 'package:flutter/material.dart';

import '../database/local_database.dart';
import '../services/api_service.dart';
import '../services/qr_service.dart';
import 'qr_screen.dart';
import 'scan_screen.dart';
import 'transaction_history.dart';
import 'login_screen.dart';

class MerchantDashboard extends StatefulWidget {
  const MerchantDashboard({super.key});

  @override
  State<MerchantDashboard> createState() => _MerchantDashboardState();
}

class _MerchantDashboardState extends State<MerchantDashboard> {
  final amount = TextEditingController();

  double balance = 0;
  String userId = '';
  String name = 'Merchant';

  bool loading = true;
  bool online = false;

  int pendingCount = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  // --------------------------------------------------
  // LOAD ACCOUNT
  // --------------------------------------------------

  Future<void> load() async {
    if (mounted) {
      setState(() => loading = true);
    }

    final savedUserId = await ApiService.userId();

    if (savedUserId == null || savedUserId.isEmpty) {
      if (mounted) {
        setState(() => loading = false);
      }
      return;
    }

    userId = savedUserId;

    // Load cached account first.
    try {
      final local =
          await LocalDatabase.getLocalAccount(userId);

      if (local != null && mounted) {
        setState(() {
          name = local['name']?.toString() ?? 'Merchant';
          balance =
              (local['verified_balance'] as num?)?.toDouble() ??
                  0;
        });
      }
    } catch (e) {
      debugPrint('Local merchant account error: $e');
    }

    await _loadPendingCount();

    // Refresh from server.
    try {
      final results = await Future.wait([
        ApiService.wallet(),
        ApiService.me(),
      ]);

      final wallet = results[0];
final profile = results[1];

      final serverBalance =
          (wallet['balance'] as num?)?.toDouble() ?? 0;

      final serverName =
          profile['name']?.toString() ?? 'Merchant';

      final serverUserId =
          profile['user_id']?.toString() ?? userId;

      await LocalDatabase.saveAccount({
        'user_id': serverUserId,
        'name': serverName,
        'email': profile['email'],
        'phone': profile['phone'],
        'role': 'merchant',
        'verified_balance': serverBalance,
        'reserved_balance':
            wallet['reserved_balance'] ?? 0,
        'currency': 'INR',
        'account_status': 'ACTIVE',
        'is_server_verified': true,
      });

      if (!mounted) return;

      setState(() {
        balance = serverBalance;
        name = serverName;
        userId = serverUserId;
        online = true;
        loading = false;
      });
    } catch (e) {
      debugPrint('Merchant online refresh failed: $e');

      final local =
          await LocalDatabase.getLocalAccount(userId);

      if (!mounted) return;

      setState(() {
        if (local != null) {
          name = local['name']?.toString() ?? 'Merchant';
          balance =
              (local['verified_balance'] as num?)?.toDouble() ??
                  0;
        }

        online = false;
        loading = false;
      });
    }
  }

  // --------------------------------------------------
  // PENDING SYNC
  // --------------------------------------------------

  Future<void> _loadPendingCount() async {
    try {
      final records = await LocalDatabase.history();

      final count = records.where((record) {
        final role = record['role']?.toString().toLowerCase();
        final status =
            record['sync_status']?.toString().toUpperCase();

        return role == 'merchant' && status != 'SYNCED';
      }).length;

      if (mounted) {
        setState(() => pendingCount = count);
      }
    } catch (e) {
      debugPrint('Merchant pending count error: $e');
    }
  }

  // --------------------------------------------------
  // LOGOUT
  // --------------------------------------------------

  Future<void> logout() async {
    await ApiService.logout();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => const LoginScreen(),
      ),
      (_) => false,
    );
  }

  // --------------------------------------------------
  // HISTORY
  // --------------------------------------------------

  void history() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const TransactionHistory(),
      ),
    ).then((_) => load());
  }

  // --------------------------------------------------
  // GENERATE PAYMENT REQUEST
  // --------------------------------------------------

  void generate() {
    final value = double.tryParse(amount.text.trim());

    if (value == null ||
        !value.isFinite ||
        value <= 0 ||
        value > 10000000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid amount greater than ₹0.'),
        ),
      );
      return;
    }

    if (userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Merchant account is not loaded.'),
        ),
      );
      return;
    }

    final payload = QrService.request(
      QrService.req(),
      userId,
      name,
      value,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QrScreen(
          title: 'Payment Request QR',
          payload: QrService.enc(payload),
        ),
      ),
    ).then((_) => load());
  }

  // --------------------------------------------------
  // SCAN CUSTOMER PAYMENT
  // --------------------------------------------------

  void scanPayment() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ScanScreen(
          mode: ScanMode.payment,
        ),
      ),
    ).then((_) => load());
  }

  // --------------------------------------------------
  // UI
  // --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(
              Icons.qr_code_2_rounded,
              color: Color(0xFF1456D9),
            ),
            SizedBox(width: 8),
            Text(
              'OfflinePay',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh balance',
            onPressed: load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: logout,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Text(
              'Welcome, ${name.split(' ').first} 👋',
              style: const TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w800,
                color: Color(0xFF14213D),
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Your counter. Your QR. Simple payments.',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 22),

            // MERCHANT WALLET
            Container(
              padding: const EdgeInsets.all(23),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF123A9D),
                    Color(0xFF3478F6),
                  ],
                ),
                borderRadius: BorderRadius.circular(26),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.account_balance_wallet_outlined,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 9),
                      const Text(
                        'MERCHANT WALLET',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        online
                            ? Icons.verified_rounded
                            : Icons.cloud_off_rounded,
                        color: Colors.white70,
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Text(
                    loading
                        ? 'Loading…'
                        : '₹${balance.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 34,
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    online
                        ? '●  Account connected'
                        : '●  Offline • Showing saved balance',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 15),

            // PENDING SYNC
            Container(
              padding: const EdgeInsets.all(17),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7E6),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFFF6E5BC),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.sync,
                    color: Color(0xFF9A6700),
                    size: 27,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Pending Sync',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$pendingCount transaction(s) awaiting synchronization',
                          style: const TextStyle(
                            color: Color(0xFF6B5B36),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '$pendingCount',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF9A6700),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 25),

            const Text(
              'Create a payment request',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              'Enter the bill amount. Your customer scans the QR to receive the exact amount.',
              style: TextStyle(
                color: Color(0xFF64748B),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),

            // AMOUNT ENTRY
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Payment amount',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: amount,
                      keyboardType:
                          const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        prefixText: '₹  ',
                        hintText: '0.00',
                        suffixIcon:
                            Icon(Icons.currency_rupee_rounded),
                      ),
                    ),
                    const SizedBox(height: 15),
                    FilledButton.icon(
                      onPressed: userId.isEmpty ? null : generate,
                      icon: const Icon(Icons.qr_code_2_rounded),
                      label: const Text('Generate payment QR'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 13),

            // SCAN CUSTOMER PAYMENT
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: scanPayment,
                child: const Padding(
                  padding: EdgeInsets.all(17),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: Color(0xFFE2F8EF),
                        child: Icon(
                          Icons.qr_code_scanner_rounded,
                          color: Color(0xFF13845D),
                        ),
                      ),
                      SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Scan customer payment QR',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Continue the payment handshake',
                              style: TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 17,
                        color: Color(0xFF94A3B8),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            OutlinedButton.icon(
              onPressed: history,
              icon: const Icon(Icons.receipt_long_rounded),
              label: const Text('View transaction history'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),

            const SizedBox(height: 20),

            const Row(
              children: [
                Icon(
                  Icons.timer_outlined,
                  size: 18,
                  color: Color(0xFF64748B),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Payment request QR expires after 2 minutes. Verify each payment status before handing over goods.',
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
