
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../database/local_database.dart';

class TransactionHistory extends StatefulWidget {
  const TransactionHistory({super.key});

  @override
  State<TransactionHistory> createState() => _TransactionHistoryState();
}

class _TransactionHistoryState extends State<TransactionHistory> {
  List<Map<String, dynamic>> rows = [];

  String currentUserId = '';
  String currentRole = 'customer';

  bool loading = true;
  bool usingLocalHistory = false;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        loading = true;
        errorMessage = null;
      });
    }

    try {
      // Identify the logged-in account and its role.
      final me = await ApiService.me();

      currentUserId = (me['user_id'] ?? '').toString();
      currentRole =
          (me['role'] ?? 'customer').toString().toLowerCase();

      // Load transactions from the backend.
      final result = await ApiService.transactions();

      rows = result
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      usingLocalHistory = false;
    } catch (e) {
      // Backend unavailable: use locally saved transaction history.

      // Try to retrieve the logged-in user ID independently.
      // Local history should still load if this lookup fails.
      try {
        currentUserId = await ApiService.userId() ?? '';
      } catch (_) {
        currentUserId = '';
      }

      try {
        final result = await LocalDatabase.history();

        rows = result
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();

        usingLocalHistory = true;
      } catch (_) {
        rows = [];
        errorMessage = 'Unable to load transaction history.';
      }
    }

    if (!mounted) return;

    setState(() {
      loading = false;
    });
  }

  String _text(
    dynamic value, {
    String fallback = 'Not available',
  }) {
    if (value == null || value.toString().trim().isEmpty) {
      return fallback;
    }

    return value.toString();
  }

  double _amount(dynamic value) {
    if (value is num) return value.toDouble();

    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  DateTime? _date(dynamic value) {
    if (value == null) return null;

    if (value is DateTime) return value.toLocal();

    if (value is int) {
      // Support timestamps in milliseconds or seconds.
      final milliseconds = value < 100000000000
          ? value * 1000
          : value;

      return DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
      ).toLocal();
    }

    return DateTime.tryParse(value.toString())?.toLocal();
  }

  String _formatDate(dynamic value) {
    final date = _date(value);

    if (date == null) return 'Time not available';

    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString();

    final hour12 = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final hour = hour12.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? 'PM' : 'AM';

    return '$day/$month/$year • $hour:$minute $period';
  }

  bool _isCredit(Map<String, dynamic> transaction) {
    final merchantId =
        transaction['merchant_id']?.toString() ?? '';

    // Determine direction using the logged-in account.
    if (currentUserId.isNotEmpty) {
      return merchantId == currentUserId;
    }

    // Fallback to saved direction if user ID is unavailable.
    final direction =
        (transaction['direction'] ?? transaction['type'] ?? '')
            .toString()
            .toLowerCase();

    return direction == 'credit' ||
        direction == 'credited' ||
        direction == 'received';
  }

  Color _statusColor(String status) {
    switch (status.toUpperCase()) {
      case 'COMPLETED':
      case 'SYNCED':
        return Colors.green.shade700;

      case 'PENDING':
      case 'VERIFIED':
      case 'ACKNOWLEDGED':
        return Colors.orange.shade800;

      case 'FAILED':
      case 'ROLLED_BACK':
        return Colors.red.shade700;

      default:
        return Colors.blueGrey;
    }
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _transactionCard(
    Map<String, dynamic> transaction,
  ) {
    final amount = _amount(transaction['amount']);
    final credit = _isCredit(transaction);

    final status = _text(
      transaction['status'],
      fallback: 'UNKNOWN',
    ).toUpperCase();

    final transactionId = _text(
      transaction['transaction_id'],
      fallback: 'Not recorded',
    );

    final token = _text(
      transaction['token'] ?? transaction['payment_token'],
      fallback: 'Not returned by backend',
    );

    final requestId = _text(
      transaction['request_id'],
      fallback: 'Not recorded',
    );

    final counterpartyId = credit
        ? transaction['customer_id']
        : transaction['merchant_id'];

    final timestamp = transaction['completed_at'] ??
        transaction['created_at'] ??
        transaction['timestamp'];

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 46,
                  width: 46,
                  decoration: BoxDecoration(
                    color: credit
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    credit
                        ? Icons.south_west_rounded
                        : Icons.north_east_rounded,
                    color: credit
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        credit ? 'CREDITED' : 'DEBITED',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: credit
                              ? Colors.green.shade700
                              : Colors.red.shade700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatDate(timestamp),
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${credit ? '+' : '-'}₹${amount.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    color: credit
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),
            const Divider(),

            Row(
              children: [
                const Text(
                  'Payment status',
                  style: TextStyle(fontSize: 13),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _statusColor(status)
                        .withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: _statusColor(status),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),

            _detail('Transaction ID', transactionId),
            _detail('Payment token', token),
            _detail('Request ID', requestId),
            _detail(
              credit ? 'Customer ID' : 'Merchant ID',
              _text(counterpartyId),
            ),

            if (transaction['synced'] != null)
              _detail(
                'Local sync',
                transaction['synced'].toString() == '1'
                    ? 'Synced'
                    : 'Not synced',
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction History'),
        actions: [
          IconButton(
            tooltip: 'Refresh history',
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: loading
            ? ListView(
                children: const [
                  SizedBox(height: 250),
                  Center(
                    child: CircularProgressIndicator(),
                  ),
                ],
              )
            : errorMessage != null
                ? ListView(
                    children: [
                      const SizedBox(height: 150),
                      Center(child: Text(errorMessage!)),
                      Center(
                        child: TextButton(
                          onPressed: load,
                          child: const Text('Try again'),
                        ),
                      ),
                    ],
                  )
                : rows.isEmpty
                    ? ListView(
                        children: [
                          const SizedBox(height: 170),
                          Icon(
                            Icons.receipt_long_outlined,
                            size: 65,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 16),
                          const Center(
                            child: Text('No transactions yet'),
                          ),
                          const SizedBox(height: 8),
                          Center(
                            child: Text(
                              'Your payments will appear here.',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          if (usingLocalHistory)
                            Container(
                              margin: const EdgeInsets.only(
                                bottom: 14,
                              ),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                'Showing locally saved transactions. '
                                'Some server details may be unavailable.',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ...rows.map(_transactionCard),
                        ],
                      ),
      ),
    );
  }
}
