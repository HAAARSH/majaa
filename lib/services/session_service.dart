import 'package:shared_preferences/shared_preferences.dart';

/// Tracks user activity for 6-hour idle session expiry.
/// Persists to SharedPreferences so kill+reopen respects the timeout.
class SessionService {
  static SessionService? _instance;
  static SessionService get instance => _instance ??= SessionService._();
  SessionService._();

  static const int timeoutHours = 6;
  static const _prefKey = 'session_last_active_ms';

  int? _lastActiveMs; // in-memory cache of SharedPrefs value

  /// Load saved timestamp from SharedPreferences on app startup.
  /// Call once in main() after Hive init.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _lastActiveMs = prefs.getInt(_prefKey);
  }

  /// Record the current time as the last-active timestamp.
  /// Called on every user touch gesture AND on app resume.
  void markActive() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastActiveMs = now;
    // Fire-and-forget — don't await in gesture handler
    SharedPreferences.getInstance().then((p) => p.setInt(_prefKey, now));
  }

  /// Returns true if the user has been inactive for more than [timeoutHours].
  /// Returns false if no timestamp recorded yet (fresh install / just logged in).
  bool isSessionExpired() {
    if (_lastActiveMs == null) return false;
    final elapsed = DateTime.now().millisecondsSinceEpoch - _lastActiveMs!;
    return elapsed > timeoutHours * 60 * 60 * 1000;
  }

  /// Clear the timestamp on logout.
  Future<void> reset() async {
    _lastActiveMs = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }
}
