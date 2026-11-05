
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'customer_dashboard.dart';
import 'merchant_dashboard.dart';
import 'login_screen.dart';

class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key});

  Future<Widget> next() async {
    try {
      // Verify the existing login session.
      await ApiService.me();

      // Read the role selected at login.
      final role = await ApiService.selectedRole();

      if (role == 'merchant') {
        return const MerchantDashboard();
      }

      return const CustomerDashboard();
    } catch (_) {
      await ApiService.logout();
      return const LoginScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: next(),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return snapshot.data!;
        }

        if (snapshot.hasError) {
          return const Scaffold(
            body: Center(
              child: Text('Unable to open OfflinePay. Please log in again.'),
            ),
          );
        }

        return const Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        );
      },
    );
  }
}
