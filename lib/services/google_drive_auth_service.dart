import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Manages Google OAuth2 sign-in for Drive access.
/// Admin signs in once → tokens persisted → background WorkManager can refresh.
class GoogleDriveAuthService {
  static GoogleDriveAuthService? _instance;
  static GoogleDriveAuthService get instance =>
      _instance ??= GoogleDriveAuthService._();
  GoogleDriveAuthService._();

  // SharedPreferences keys
  static const _keyAccessToken = 'gdrive_access_token';
  static const _keyRefreshToken = 'gdrive_refresh_token';
  static const _keyTokenExpiry = 'gdrive_token_expiry';
  static const _keyUserEmail = 'gdrive_user_email';

  // State
  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  String? _userEmail;

  // Config from env.json
  String _webClientId = '';
  String _clientSecret = '';

  GoogleSignIn? _googleSignIn;

  /// Notifies listeners when sign-in state changes (for admin UI badge).
  final ValueNotifier<bool> isSignedInNotifier = ValueNotifier(false);

  bool get isSignedIn =>
      (_refreshToken != null && _refreshToken!.isNotEmpty) ||
      (_accessToken != null && _accessToken!.isNotEmpty);
  String? get userEmail => _userEmail;

  /// Load env.json config and restore persisted tokens.
  Future<void> init() async {
    try {
      final envString = await rootBundle.loadString('env.json');
      final env = jsonDecode(envString) as Map<String, dynamic>;
      _webClientId = env['GOOGLE_WEB_CLIENT_ID'] as String? ?? '';
      _clientSecret = env['GOOGLE_OAUTH_CLIENT_SECRET'] as String? ?? '';
    } catch (e) {
      debugPrint('GoogleDriveAuthService: Failed to load env.json: $e');
    }

    // Restore persisted tokens
    try {
      final prefs = await SharedPreferences.getInstance();
      _accessToken = prefs.getString(_keyAccessToken);
      _refreshToken = prefs.getString(_keyRefreshToken);
      _userEmail = prefs.getString(_keyUserEmail);
      final expiryMs = prefs.getInt(_keyTokenExpiry);
      if (expiryMs != null) {
        _expiresAt = DateTime.fromMillisecondsSinceEpoch(expiryMs);
      }
      isSignedInNotifier.value = isSignedIn;
      if (isSignedIn) {
        debugPrint('GoogleDriveAuthService: Restored session for $_userEmail');
      }
    } catch (e) {
      debugPrint('GoogleDriveAuthService: Failed to restore tokens: $e');
    }
  }

  /// Interactive Google Sign-In. Returns true on success.
  Future<bool> signIn() async {
    if (_webClientId.isEmpty) {
      throw Exception('GOOGLE_WEB_CLIENT_ID not set in env.json');
    }

    _googleSignIn ??= GoogleSignIn(
      scopes: ['https://www.googleapis.com/auth/drive'],
      serverClientId: _webClientId,
    );

    try {
      // Sign out first to force account picker
      await _googleSignIn!.signOut();
      final account = await _googleSignIn!.signIn();
      if (account == null) return false; // User cancelled

      _userEmail = account.email;

      // Get serverAuthCode to exchange for refresh token
      final serverAuthCode = account.serverAuthCode;
      if (serverAuthCode == null) {
        // Fallback: use the access token directly (no background refresh)
        final auth = await account.authentication;
        _accessToken = auth.accessToken;
        _expiresAt = DateTime.now().add(const Duration(minutes: 55));
        await _persistTokens();
        isSignedInNotifier.value = true;
        debugPrint('GoogleDriveAuthService: Signed in (no refresh token) as $_userEmail');
        return true;
      }

      // Exchange serverAuthCode for access_token + refresh_token
      await _exchangeAuthCode(serverAuthCode);
      await _persistTokens();
      isSignedInNotifier.value = true;
      debugPrint('GoogleDriveAuthService: Signed in with refresh token as $_userEmail');
      return true;
    } catch (e) {
      debugPrint('GoogleDriveAuthService: Sign-in failed: $e');
      rethrow;
    }
  }

  /// Exchange authorization code for tokens via Google's token endpoint.
  Future<void> _exchangeAuthCode(String authCode) async {
    final response = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'code': authCode,
        'client_id': _webClientId,
        'client_secret': _clientSecret,
        'grant_type': 'authorization_code',
        'redirect_uri': '', // Empty for Android apps
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Token exchange failed (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _accessToken = data['access_token'] as String?;
    _refreshToken = data['refresh_token'] as String? ?? _refreshToken;
    final expiresIn = data['expires_in'] as int? ?? 3600;
    _expiresAt = DateTime.now().add(Duration(seconds: expiresIn - 60)); // 60s buffer
  }

  /// Refresh the access token using persisted refresh token.
  Future<String> _refreshAccessToken() async {
    if (_refreshToken == null || _refreshToken!.isEmpty) {
      throw Exception('No refresh token available. Admin needs to sign in again.');
    }

    final response = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': _webClientId,
        'client_secret': _clientSecret,
        'refresh_token': _refreshToken!,
        'grant_type': 'refresh_token',
      },
    );

    if (response.statusCode != 200) {
      // Refresh token may be revoked — clear everything
      debugPrint('GoogleDriveAuthService: Refresh failed (${response.statusCode}), clearing session');
      await signOut();
      throw Exception('Google session expired. Admin needs to sign in again.');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _accessToken = data['access_token'] as String?;
    final expiresIn = data['expires_in'] as int? ?? 3600;
    _expiresAt = DateTime.now().add(Duration(seconds: expiresIn - 60));
    await _persistTokens();
    return _accessToken!;
  }

  /// Returns auth headers for Drive API calls. Auto-refreshes if expired.
  Future<Map<String, String>> authHeaders() async {
    if (!isSignedIn) {
      throw Exception('Google Drive not connected. Admin needs to sign in.');
    }

    // Check if token needs refresh
    if (_accessToken == null ||
        _expiresAt == null ||
        DateTime.now().isAfter(_expiresAt!)) {
      debugPrint('GoogleDriveAuthService: Token expired, refreshing...');

      if (_refreshToken != null && _refreshToken!.isNotEmpty) {
        // Has refresh token — use it
        await _refreshAccessToken();
      } else {
        // No refresh token — try silent re-auth via GoogleSignIn
        try {
          _googleSignIn ??= GoogleSignIn(
            scopes: ['https://www.googleapis.com/auth/drive'],
            serverClientId: _webClientId,
          );
          final account = await _googleSignIn!.signInSilently();
          if (account != null) {
            final auth = await account.authentication;
            _accessToken = auth.accessToken;
            _expiresAt = DateTime.now().add(const Duration(minutes: 55));
            await _persistTokens();
            debugPrint('GoogleDriveAuthService: Silent re-auth succeeded');
          } else {
            throw Exception('Silent re-auth failed. Admin needs to sign in again.');
          }
        } catch (e) {
          await signOut();
          throw Exception('Google session expired. Admin needs to sign in again.');
        }
      }
    }

    return {'Authorization': 'Bearer $_accessToken'};
  }

  /// Sign out and clear all persisted tokens.
  Future<void> signOut() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _userEmail = null;
    isSignedInNotifier.value = false;

    try {
      _googleSignIn?.signOut();
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyAccessToken);
      await prefs.remove(_keyRefreshToken);
      await prefs.remove(_keyTokenExpiry);
      await prefs.remove(_keyUserEmail);
    } catch (e) {
      debugPrint('GoogleDriveAuthService: Failed to clear prefs: $e');
    }
    debugPrint('GoogleDriveAuthService: Signed out');
  }

  Future<void> _persistTokens() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_accessToken != null) await prefs.setString(_keyAccessToken, _accessToken!);
      if (_refreshToken != null) await prefs.setString(_keyRefreshToken, _refreshToken!);
      if (_userEmail != null) await prefs.setString(_keyUserEmail, _userEmail!);
      if (_expiresAt != null) await prefs.setInt(_keyTokenExpiry, _expiresAt!.millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('GoogleDriveAuthService: Failed to persist tokens: $e');
    }
  }
}
