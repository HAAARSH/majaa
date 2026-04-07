import 'package:shared_preferences/shared_preferences.dart';

/// PIN protection for destructive operations.
/// Default PIN: 0903. Super admin can edit in settings.
class PinService {
  static PinService? _instance;
  static PinService get instance => _instance ??= PinService._();
  PinService._();

  static const _key = 'admin_pin';
  static const _defaultPin = '0903';

  String? _cachedPin;

  Future<String> getPin() async {
    if (_cachedPin != null) return _cachedPin!;
    final prefs = await SharedPreferences.getInstance();
    _cachedPin = prefs.getString(_key) ?? _defaultPin;
    return _cachedPin!;
  }

  Future<bool> verify(String input) async {
    final pin = await getPin();
    return input == pin;
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
