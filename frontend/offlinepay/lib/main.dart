
import 'package:flutter/material.dart';

import 'config/api_config.dart';
import 'screens/login_screen.dart';
import 'services/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize API configuration.
  await ApiConfig.init();

  // Start automatic pending-payment synchronization.
  await SyncService.initialize();

  runApp(const OfflinePayApp());
}

class OfflinePayApp extends StatelessWidget {
  const OfflinePayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OfflinePay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1456D9),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FC),
      ),
      home: const LoginScreen(),
    );
  }
}
