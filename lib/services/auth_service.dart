import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/login_pin_dialog.dart';
import 'login_pin_service.dart';
import 'supabase_service.dart';

class AuthService {
  static AuthService? _instance;
  static AuthService get instance => _instance ??= AuthService._();
  AuthService._();

  // ─── THE MULTI-TEAM GATEKEEPERS ───
  static String currentTeam = 'JA'; // Defaults to JA to prevent null errors
  static String teamUpi = '';
  static String get currentUserName =>
      SupabaseService.instance.currentUserName ?? 'there';

  SupabaseClient get client => Supabase.instance.client;

  // ─── LOGIN-PIN CREDENTIAL STORE ───
  // Backed by Keystore (Android) / Keychain (iOS). Holds at most one user's
  // email + password — wiped on signOut and rotated on every fresh login so
  // a multi-rep device never carries stale creds. Read by attemptPinRelogin.
  static const _kSavedEmail = 'saved_email';
  static const _kSavedPassword = 'saved_password';
  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Returns the current session if it exists
  Session? get currentSession => client.auth.currentSession;

  /// Returns the current user if they are logged in
  User? get currentUser => client.auth.currentUser;

  Future<bool> loginWithCredentials(String email, String password) async {
    try {
      // 1. Authenticate with Supabase
      final AuthResponse res = await client.auth.signInWithPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );

      if (res.user == null) return false;

      // 2. Fetch Team Info from app_users table
      final userData = await client
          .from('app_users')
          .select('team_id, upi_id, full_name, role')
          .eq('email', email.trim().toLowerCase())
          .maybeSingle();

      if (userData == null) {
        debugPrint('[AuthService] No app_users record found for $email');
        return false;
      }

      // 3. Set Global Variables — clear old cache if team is switching
      final newTeam = userData['team_id'] as String? ?? 'JA';
      if (newTeam != currentTeam && Hive.isBoxOpen('cache_$currentTeam')) {
        await Hive.box('cache_$currentTeam').clear();
        debugPrint('[AuthService] Cleared cache for old team: $currentTeam');
      }
      currentTeam = newTeam;
      teamUpi = userData['upi_id'] ?? '';
      SupabaseService.instance.currentUserId = res.user!.id;
      SupabaseService.instance.clearResolvedUserId(); // Reset cached user ID on new login
      try {
        SupabaseService.instance.currentUserName = userData['full_name'] as String?;
      } catch (_) {
        SupabaseService.instance.currentUserName = null;
      }

      // 4. Initialize the specific Team Cache
      await initTeamCache(currentTeam);

      // Save to SharedPreferences for offline resume. Persisting role lets
      // attemptOfflineResume route the user correctly (admin → admin panel,
      // delivery_rep → delivery dashboard) even when the network is down.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_team', currentTeam);
      await prefs.setString('team_upi', teamUpi);
      final role = userData['role'] as String? ?? 'sales_rep';
      await prefs.setString('last_role', role);
      SupabaseService.instance.currentUserRole = role;
      final fullName = userData['full_name'] as String?;
      if (fullName != null && fullName.isNotEmpty) {
        await prefs.setString('last_full_name', fullName);
      } else {
        await prefs.remove('last_full_name');
      }

      // Report installed app version to app_users so admin can see at a
      // glance which reps are still on an old build. Fire-and-forget —
      // login must not fail if this write errors (older DB, offline, etc).
      _reportAppVersion(res.user!.id);

      // Persist creds for the login-PIN re-sign-in path. Wipe first so the
      // device only ever carries the most recent rep's credentials.
      await _secure.delete(key: _kSavedEmail);
      await _secure.delete(key: _kSavedPassword);
      await _secure.write(key: _kSavedEmail, value: email.trim().toLowerCase());
      await _secure.write(key: _kSavedPassword, value: password);

      return true;
    } catch (e) {
      debugPrint('Login Error: $e');
      return await attemptOfflineResume();
    }
  }

  /// Writes the installed semver + timestamp to app_users so admin can spot
  /// devices still on old versions. Swallows all errors — this is telemetry,
  /// not a login gate.
  Future<void> _reportAppVersion(String userId) async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version; // e.g. "1.2.3"
      if (version.isEmpty) return;
      await client.from('app_users').update({
        'app_version': version,
        'app_version_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', userId);
    } catch (e) {
      debugPrint('[AuthService] App version report failed: $e');
    }
  }

  Future<bool> attemptOfflineResume() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTeam = prefs.getString('current_team');

    // Restore team scope first so screens that read currentTeam pre-route
    // work correctly even if the session refresh fails.
    if (savedTeam != null) {
      currentTeam = savedTeam;
      teamUpi = prefs.getString('team_upi') ?? '';
      final cachedName = prefs.getString('last_full_name');
      if (cachedName != null && cachedName.isNotEmpty) {
        SupabaseService.instance.currentUserName = cachedName;
      }
      await initTeamCache(currentTeam);
    }

    // Refresh the cached JWT so auth.uid() resolves on every cold start. A
    // dead token surfaces as RLS-empty results (e.g. Rules tab) rather than
    // a clear sign-out — the refresh here is the durable fix.
    final session = client.auth.currentSession;
    if (session == null) return false;
    try {
      await client.auth.refreshSession();
      return true;
    } on AuthException catch (e) {
      debugPrint('[AuthService] refreshSession failed: ${e.message}');
      try {
        await client.auth.signOut();
      } catch (_) {/* best-effort */}
      return false;
    } catch (e) {
      debugPrint('[AuthService] refreshSession unexpected error: $e');
      return false;
    }
  }

  /// Re-sign-in via the per-user login PIN when the cached JWT cannot be
  /// refreshed. Reads the saved email + password from secure storage and,
  /// after a correct PIN, calls signInWithPassword to mint a fresh session.
  /// Returns false if no creds are stored, no PIN is configured for the
  /// saved user, the user taps "Forgot PIN", or the dialog is dismissed —
  /// the caller should fall through to the email/password screen in those
  /// cases.
  Future<bool> attemptPinRelogin(BuildContext context) async {
    final email = await _secure.read(key: _kSavedEmail);
    final password = await _secure.read(key: _kSavedPassword);
    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      return false;
    }

    final hasPin = await LoginPinService.instance.hasPinSet(email);
    if (!hasPin) return false;

    if (!context.mounted) return false;
    final result = await showLoginPinDialog(
      context,
      mode: LoginPinDialogMode.verify,
      email: email,
    );
    if (result == null || result.forgotPressed) {
      // User chose password fallback — wipe the saved password so the
      // password screen is the next thing they see and PIN-relogin won't
      // re-prompt until they sign in fresh.
      await _secure.delete(key: _kSavedPassword);
      return false;
    }
    if (!result.verified) return false;

    try {
      return await loginWithCredentials(email, password);
    } on AuthException catch (e) {
      // Password changed server-side — saved copy is stale.
      debugPrint('[AuthService] PIN relogin signIn failed: ${e.message}');
      await _secure.delete(key: _kSavedPassword);
      return false;
    } catch (e) {
      debugPrint('[AuthService] PIN relogin unexpected error: $e');
      return false;
    }
  }

  Future<void> initTeamCache(String teamId) async {
    // Opens a totally separate local database based on the team
    if (!Hive.isBoxOpen('cache_$teamId')) {
      await Hive.openBox('cache_$teamId');
    }
  }

  Future<void> signOut() async {
    try {
      await client.auth.signOut();
    } catch (e) {
      debugPrint('Sign Out Error: $e');
    }
    currentTeam = 'JA';
    teamUpi = '';
    SupabaseService.instance.currentUserName = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_team');
    await prefs.remove('team_upi');
    await prefs.remove('last_full_name');
    await prefs.remove('last_role');
    // Wipe saved credentials so the next launch shows the password screen,
    // not the PIN dialog. The server-side login_pin_hash is left alone —
    // when the user signs back in, their existing PIN still works.
    await _secure.delete(key: _kSavedEmail);
    await _secure.delete(key: _kSavedPassword);
  }
}
