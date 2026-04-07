import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class LoadingHelper {
  /// Wraps any async function in a safe, unbreakable loading barrier.
  static Future<void> withLoading({
    required BuildContext context,
    required Future<void> Function() task,
    String? errorMessage,
  }) async {
    // 1. Show the unclickable barrier
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(color: AppTheme.primary),
      ),
    );

    try {
      // 2. Run whatever database code you passed in
      await task();
    } catch (e) {
      // 3. Show error if it fails
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage ?? 'Error: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      // 4. CRITICAL: Destroy the barrier no matter what happened
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }
}