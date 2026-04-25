import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_service.dart';

/// Per-user login PIN service.
///
/// Strictly separate from [PinService] (admin destructive-op gate). Different
/// SharedPreferences keys, different RPCs, different dialog widget. The two
/// systems must never share state.
class LoginPinService {
  static LoginPinService? _instance;
  static LoginPinService get instance => _instance ??= LoginPinService._();
  LoginPinService._();

  // Distinct key namespace — never overlap with PinService's
  // 'pin_attempts' / 'pin_lock_until'.
  static const _kAttempts = 'login_pin_attempts';
  static const _kLockUntil = 'login_pin_lock_until';

  static const _maxAttempts = 5;
  static const _lockoutDuration = Duration(minutes: 5);

  /// Whether [email] has a login PIN configured server-side.
  Future<bool> hasPinSet(String email) async {
    try {
      final res = await SupabaseService.instance.client
          .rpc('has_login_pin', params: {'p_email': email});
      return res == true;
    } catch (e) {
      debugPrint('[LoginPinService] hasPinSet failed: $e');
      return false;
    }
  }

  /// Sets/replaces the caller's login PIN. Requires an authenticated session.
  /// Throws if [pin] is not exactly 4 digits or if the RPC fails.
  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw Exception('PIN must be exactly 4 digits');
    }
    await SupabaseService.instance.client
        .rpc('set_login_pin', params: {'p_pin': pin});
  }

  /// Verifies [pin] against the server-side hash for [email]. Honors a local
  /// 5-attempt / 5-minute lockout to slow brute-force on a stolen device.
  Future<bool> verify(String email, String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final lockUntil = prefs.getInt(_kLockUntil) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < lockUntil) {
      return false; // still locked out
    }

    bool ok;
    try {
      final res = await SupabaseService.instance.client
          .rpc('verify_login_pin', params: {'p_email': email, 'p_pin': pin});
      ok = res == true;
    } catch (e) {
      debugPrint('[LoginPinService] verify failed: $e');
      ok = false;
    }

    if (ok) {
      await prefs.setInt(_kAttempts, 0);
      return true;
    }

    final attempts = (prefs.getInt(_kAttempts) ?? 0) + 1;
    await prefs.setInt(_kAttempts, attempts);
    if (attempts >= _maxAttempts) {
      await prefs.setInt(
        _kLockUntil,
        DateTime.now().add(_lockoutDuration).millisecondsSinceEpoch,
      );
      await prefs.setInt(_kAttempts, 0);
    }
    return false;
  }

  Future<bool> get isLockedOut async {
    final prefs = await SharedPreferences.getInstance();
    final lockUntil = prefs.getInt(_kLockUntil) ?? 0;
    return DateTime.now().millisecondsSinceEpoch < lockUntil;
  }

  Future<Duration> get remainingLockout async {
    final prefs = await SharedPreferences.getInstance();
    final lockUntil = prefs.getInt(_kLockUntil) ?? 0;
    final remaining = lockUntil - DateTime.now().millisecondsSinceEpoch;
    return remaining > 0 ? Duration(milliseconds: remaining) : Duration.zero;
  }
}
