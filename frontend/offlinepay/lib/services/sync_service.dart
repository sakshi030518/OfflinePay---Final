
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../database/local_database.dart';
import 'api_service.dart';

class SyncService {
  SyncService._();

  static final Connectivity _connectivity = Connectivity();

  static StreamSubscription<dynamic>? _connectivitySubscription;

  static bool _isSyncing = false;
  static bool _isInitialized = false;

  /// Initializes automatic synchronization.
  ///
  /// Call this once when the application starts.
  static Future<void> initialize() async {
    if (_isInitialized) return;

    _isInitialized = true;

    _connectivitySubscription =
        _connectivity.onConnectivityChanged.listen(
      (dynamic result) {
        if (_hasConnection(result)) {
          syncPendingTransactions();
        }
      },
      onError: (error) {
        debugPrint('OfflinePay connectivity listener error: $error');
      },
    );

    // Check connectivity when the application starts.
    try {
      final result = await _connectivity.checkConnectivity();

      if (_hasConnection(result)) {
        await syncPendingTransactions();
      }
    } catch (error) {
      debugPrint(
        'OfflinePay initial connectivity check failed: $error',
      );
    }
  }

  /// Supports connectivity results returned as either a single
  /// ConnectivityResult or a list of ConnectivityResult values.
  static bool _hasConnection(dynamic result) {
    if (result is Iterable) {
      return result.any(
        (item) => item != ConnectivityResult.none,
      );
    }

    return result != ConnectivityResult.none;
  }

  /// Synchronizes all locally pending transactions.
  static Future<void> syncPendingTransactions() async {
    if (_isSyncing) return;

    _isSyncing = true;

    try {
      final pendingTransactions =
          await LocalDatabase.pendingSync();

      if (pendingTransactions.isEmpty) {
        debugPrint('OfflinePay: No pending transactions.');
        return;
      }

      debugPrint(
        'OfflinePay: ${pendingTransactions.length} '
        'pending transaction(s) found.',
      );

      for (final row in pendingTransactions) {
        try {
          await _syncSingleTransaction(row);
        } catch (error) {
          final id = row['transaction_id']?.toString();

          if (id != null && id.isNotEmpty) {
            await LocalDatabase.markSyncAttempt(
              id,
              error: error.toString(),
            );
          }

          // Keep unsuccessful transactions pending for retry.
          debugPrint(
            'OfflinePay: Transaction synchronization failed: $error',
          );
        }
      }
    } catch (error) {
      debugPrint(
        'OfflinePay synchronization error: $error',
      );
    } finally {
      _isSyncing = false;
    }
  }

  /// Synchronizes one transaction with the backend.
  static Future<void> _syncSingleTransaction(
    Map<String, dynamic> row,
  ) async {
    final transactionId =
        row['transaction_id']?.toString();

    if (transactionId == null || transactionId.isEmpty) {
      throw Exception(
        'Transaction ID is missing from the sync queue.',
      );
    }

    final rawPayload = row['payload'];

    if (rawPayload == null) {
      throw Exception(
        'Transaction payload is missing: $transactionId',
      );
    }

    Map<String, dynamic> payload;

    if (rawPayload is String) {
      final decoded = jsonDecode(rawPayload);

      if (decoded is! Map) {
        throw Exception('Invalid transaction payload.');
      }

      payload = Map<String, dynamic>.from(decoded);
    } else if (rawPayload is Map) {
      payload = Map<String, dynamic>.from(rawPayload);
    } else {
      throw Exception(
        'Unsupported transaction payload format.',
      );
    }

    // Preserve the original signed QR evidence.
    // Add the backend transport identifier without changing
    // the original signed QR fields.
    final apiPayload = <String, dynamic>{
      ...payload,
      'transaction_id':
          payload['transaction_id'] ?? payload['txn_id'],
    };

    final response = await ApiService.syncPayment(apiPayload);

    if (response['status']?.toString().toUpperCase() !=
        'COMPLETED') {
      throw Exception(
        response['message']?.toString() ??
            'Backend did not confirm payment settlement.',
      );
    }

    // Mark the transaction synchronized only after
    // successful backend confirmation.
    await LocalDatabase.markSynced(transactionId);

    debugPrint(
      'OfflinePay: Transaction $transactionId synchronized.',
    );
  }

  /// Returns whether synchronization is currently running.
  static bool get isSyncing => _isSyncing;

  /// Manually retries pending transactions.
  ///
  /// Can be called from a Retry button or dashboard refresh.
  static Future<void> retryPendingTransactions() async {
    try {
      final result = await _connectivity.checkConnectivity();

      if (!_hasConnection(result)) {
        debugPrint(
          'OfflinePay: Internet connection unavailable.',
        );
        return;
      }

      await syncPendingTransactions();
    } catch (error) {
      debugPrint(
        'OfflinePay retry error: $error',
      );
    }
  }

  /// Stops listening for connectivity changes.
  static Future<void> dispose() async {
    await _connectivitySubscription?.cancel();

    _connectivitySubscription = null;
    _isInitialized = false;
  }
}
