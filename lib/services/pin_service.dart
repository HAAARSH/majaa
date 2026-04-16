import 'package:shared_preferences/shared_preferences.dart';

/// PIN protection for destructive operations.
/// Default PIN: 0903. Super admin can edit in settings.
class PinService {
  static PinService? _instance;
  static PinService get instance => _instance ??= PinService._();
  PinService._();

  static const _key = 'admin_pin';
  static const _defaultPin = '0903';
  static const _maxAttempts = 5;
  static const _lockoutDuration = Duration(minutes: 5);

  String? _cachedPin;

  Future<String> getPin() async {
    if (_cachedPin != null) return _cachedPin!;
    final prefs = await SharedPreferences.getInstance();
    _cachedPin = prefs.getString(_key) ?? _defaultPin;
    return _cachedPin!;
  }

  Future<bool> verify(String input) async {
    final prefs = await SharedPreferences.getInstance();
    final lockUntil = prefs.getInt('pin_lock_until') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < lockUntil) {
      return false; // Still locked out
    }

    final pin = await getPin();
    if (input == pin) {
      await prefs.setInt('pin_attempts', 0); // Reset on success
      return true;
    }

    final attempts = (prefs.getInt('pin_attempts') ?? 0) + 1;
    await prefs.setInt('pin_attempts', attempts);
    if (attempts >= _maxAttempts) {
      await prefs.setInt('pin_lock_until',
          DateTime.now().add(_lockoutDuration).millisecondsSinceEpoch);
      await prefs.setInt('pin_attempts', 0);
    }
    return false;
  }

  /// Whether the PIN is currently locked out due to too many failed attempts.
  Future<bool> get isLockedOut async {
    final prefs = await SharedPreferences.getInstance();
    final lockUntil = prefs.getInt('pin_lock_until') ?? 0;
    return DateTime.now().millisecondsSinceEpoch < lockUntil;
  }

  /// How long until the lockout expires. Returns Duration.zero if not locked.
  Future<Duration> get remainingLockout async {
    final prefs = await SharedPreferences.getInstance();
    final lockUntil = prefs.getInt('pin_lock_until') ?? 0;
    final remaining = lockUntil - DateTime.now().millisecondsSinceEpoch;
    return remaining > 0 ? Duration(milliseconds: remaining) : Duration.zero;
  }

  Future<void> setPin(String newPin) async {
    if (newPin.length != 4) throw Exception('PIN must be 4 digits');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, newPin);
    _cachedPin = newPin;
  }

  Future<void> resetToDefault() async {
    await setPin(_defaultPin);
  }
}
