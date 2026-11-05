
import 'package:flutter/material.dart';

import '../database/local_database.dart';
import '../services/api_service.dart';
import 'scan_screen.dart';
import 'transaction_history.dart';
import 'login_screen.dart';

class CustomerDashboard extends StatefulWidget {
  const CustomerDashboard({super.key});

  @override
  State<CustomerDashboard> createState() =>
      _CustomerDashboardState();
}

class _CustomerDashboardState extends State<CustomerDashboard> {
  double balance = 0;
  String name = 'Customer';

  bool loading = true;
  bool online = false;
  bool provisioning = false;

  int pendingCount = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  // --------------------------------------------------
  // LOAD LOCAL AND ONLINE ACCOUNT DATA
  // --------------------------------------------------

  Future<void> load() async {
    if (mounted) {
      setState(() => loading = true);
    }

    final userId = await ApiService.userId();

    if (userId == null || userId.isEmpty) {
      if (mounted) {
        setState(() => loading = false);
      }
      return;
    }

    // Load saved account information first.
    try {
      final localAccount =
          await LocalDatabase.getLocalAccount(userId);

      if (localAccount != null && mounted) {
        setState(() {
          name = localAccount['name']?.toString() ?? 'Customer';
          balance =
              (localAccount['verified_balance'] as num?)?.toDouble() ??
                  0;
        });
      }
    } catch (e) {
      debugPrint('Local account loading error: $e');
    }

    // Load pending transactions.
    await _loadPendingCount();

    // Refresh account information from backend.
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
          profile['name']?.toString() ?? 'Customer';

      // Cache trusted online account information.
      await LocalDatabase.saveAccount({
        'user_id': userId,
        'name': serverName,
        'email': profile['email'],
        'phone': profile['phone'],
        'role': 'customer',
        'verified_balance': serverBalance,
        'reserved_balance': wallet['reserved_balance'] ?? 0,
        'currency': 'INR',
        'account_status': 'ACTIVE',
        'is_server_verified': true,
      });

      if (!mounted) return;

      setState(() {
        balance = serverBalance;
        name = serverName;
        online = true;
        loading = false;
      });
    } catch (e) {
      debugPrint('Online dashboard refresh failed: $e');

      // Continue using the last saved local balance.
      final localAccount =
          await LocalDatabase.getLocalAccount(userId);

      if (!mounted) return;

      setState(() {
        if (localAccount != null) {
          name = localAccount['name']?.toString() ?? 'Customer';
          balance =
              (localAccount['verified_balance'] as num?)?.toDouble() ??
                  0;
        }

        online = false;
        loading = false;
      });
    }
  }

  // --------------------------------------------------
  // PENDING SYNC COUNT
  // --------------------------------------------------

  Future<void> _loadPendingCount() async {
    try {
      final records = await LocalDatabase.history();

      final count = records.where((record) {
        final role = record['role']?.toString().toLowerCase();
        final syncStatus =
            record['sync_status']?.toString().toUpperCase();

        return role == 'customer' && syncStatus != 'SYNCED';
      }).length;

      if (mounted) {
        setState(() {
          pendingCount = count;
        });
      }
    } catch (e) {
      debugPrint('Pending transaction count error: $e');
    }
  }

  // --------------------------------------------------
  // PREPARE OFFLINE PAYMENTS
  // --------------------------------------------------

  Future<void> _provisionAllowance() async {
    if (provisioning) return;

    if (!online) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Connect to the internet before preparing an offline allowance.',
          ),
        ),
      );
      return;
    }

    final controller = TextEditingController();

    final amount = await showDialog<double>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Prepare Offline Payments'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            decoration: const InputDecoration(
              labelText: 'Allowance amount',
              prefixText: '₹ ',
              hintText: 'Example: 500',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final value =
                    double.tryParse(controller.text.trim());

                if (value == null ||
                    !value.isFinite ||
                    value <= 0) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                      content: Text('Enter a valid amount.'),
                    ),
                  );
                  return;
                }

                Navigator.pop(dialogContext, value);
              },
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (amount == null || !mounted) return;

    setState(() => provisioning = true);

    try {
      // Register device and create/download server allowance.
      final allowance =
          await ApiService.provisionOfflineAllowance(
        amount: amount,
      );

      await load();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Offline allowance ready: ₹${allowance['allowance_amount']}',
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Allowance provisioning failed: '
            '${e.toString().replaceFirst('Exception: ', '')}',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => provisioning = false);
      }
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
  // NAVIGATION
  // --------------------------------------------------

  void open(Widget page) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
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
              'Hello, ${name.split(' ').first} 👋',
              style: const TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w800,
                color: Color(0xFF14213D),
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Ready for a quick and secure payment?',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 22),

            // WALLET BALANCE
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
                  const Row(
                    children: [
                      Icon(
                        Icons.account_balance_wallet_outlined,
                        color: Colors.white70,
                      ),
                      SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'AVAILABLE WALLET BALANCE',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
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
                  Row(
                    children: [
                      Icon(
                        online ? Icons.cloud_done : Icons.cloud_off,
                        color: Colors.white,
                        size: 16,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        online
                            ? 'Connected to account'
                            : 'Offline • Showing saved balance',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 15),

            // PENDING SYNC CARD
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

            const SizedBox(height: 26),

            const Text(
              'Quick actions',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 13),

            // SCAN AND PAY
            _ActionCard(
              icon: Icons.qr_code_scanner_rounded,
              title: 'Scan & Pay',
              subtitle: 'Scan a merchant payment request',
              tint: const Color(0xFFE7EEFF),
              iconColor: const Color(0xFF1456D9),
              onTap: () => open(
                const ScanScreen(
                  mode: ScanMode.paymentRequest,
                ),
              ),
            ),

            const SizedBox(height: 12),

            // PREPARE OFFLINE ALLOWANCE
            _ActionCard(
              icon: Icons.download_for_offline_rounded,
              title: provisioning
                  ? 'Preparing Allowance...'
                  : 'Prepare Offline Payments',
              subtitle: provisioning
                  ? 'Please wait while your allowance is secured'
                  : 'Reserve money before going offline',
              tint: const Color(0xFFE2F8EF),
              iconColor: const Color(0xFF13845D),
              onTap: provisioning ? () {} : _provisionAllowance,
            ),

            const SizedBox(height: 12),

            // SCAN MERCHANT ACK
            _ActionCard(
              icon: Icons.verified_outlined,
              title: 'Scan Merchant ACK QR',
              subtitle: 'Confirm payment after merchant verification',
              tint: const Color(0xFFE2F8EF),
              iconColor: const Color(0xFF13845D),
              onTap: () => open(
                const ScanScreen(
                  mode: ScanMode.confirmation,
                ),
              ),
            ),

            const SizedBox(height: 12),

            // TRANSACTION HISTORY
            _ActionCard(
              icon: Icons.receipt_long_rounded,
              title: 'Transaction history',
              subtitle: 'Review your recent payments',
              tint: const Color(0xFFE2F8EF),
              iconColor: const Color(0xFF13845D),
              onTap: () => open(
                const TransactionHistory(),
              ),
            ),

            const SizedBox(height: 24),

            // PAYMENT SAFETY TIP
            Container(
              padding: const EdgeInsets.all(17),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7E6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFFF6E5BC),
                ),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    color: Color(0xFF9A6700),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Payment safety tip',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Always verify the merchant name and amount '
                          'before confirming a payment.',
                          style: TextStyle(
                            color: Color(0xFF6B5B36),
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------
// REUSABLE ACTION CARD
// --------------------------------------------------

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;
  final Color iconColor;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tint,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Row(
            children: [
              Container(
                height: 52,
                width: 52,
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  icon,
                  color: iconColor,
                  size: 27,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 17,
                color: Color(0xFF94A3B8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
