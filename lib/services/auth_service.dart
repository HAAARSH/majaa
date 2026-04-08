import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
          .select('team_id, upi_id, full_name')
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
      try {
        SupabaseService.instance.currentUserName = userData['full_name'] as String?;
      } catch (_) {
        SupabaseService.instance.currentUserName = null;
      }

      // 4. Initialize the specific Team Cache
      await initTeamCache(currentTeam);

      // Save to SharedPreferences for offline resume
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_team', currentTeam);
      await prefs.setString('team_upi', teamUpi);

      return true;
    } catch (e) {
      debugPrint('Login Error: $e');
      return await attemptOfflineResume();
    }
  }

  Future<bool> attemptOfflineResume() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTeam = prefs.getString('current_team');
    
    // Check if we have a valid Supabase session first
    final session = client.auth.currentSession;
    
    if (savedTeam != null) {
      currentTeam = savedTeam;
      teamUpi = prefs.getString('team_upi') ?? '';
      await initTeamCache(currentTeam);
      return session != null || kIsWeb; // On web/offline we might want to allow entry if team is cached
    }
    return false;
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_team');
    await prefs.remove('team_upi');
  }
}
