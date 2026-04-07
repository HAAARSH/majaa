import 'dart:convert';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Exchanges a Google service account key for a short-lived OAuth2 access token.
/// Token is cached for 55 minutes (Google issues 60-minute tokens).
///
/// Setup:
///   1. In Google Cloud Console, create a service account.
///   2. Grant access to your Drive folders (share each folder with the service account email).
///   3. Create a JSON key file, download it.
///   4. Base64-encode the downloaded JSON file, then add to env.json:
///        "GOOGLE_SERVICE_ACCOUNT_JSON": "base64-encoded string"
class ServiceAccountAuth {
  static ServiceAccountAuth? _instance;
  static ServiceAccountAuth get instance => _instance ??= ServiceAccountAuth._();
  ServiceAccountAuth._();

  static const String _driveScope = 'https://www.googleapis.com/auth/drive.file';
  static const String _tokenUrl = 'https://oauth2.googleapis.com/token';

  // Cached token state
  String? _accessToken;
  DateTime? _expiresAt;

  // Cached env.json data (loaded once at runtime)
  static Map<String, dynamic>? _envData;

  /// Loads env.json at runtime (same approach as SupabaseService.initialize).
  static Future<Map<String, dynamic>> _loadEnv() async {
    if (_envData != null) return _envData!;
    final envString = await rootBundle.loadString('env.json');
    _envData = jsonDecode(envString) as Map<String, dynamic>;
    return _envData!;
  }

  /// Returns a valid Bearer token. Refreshes automatically when near expiry.
  Future<String> getAccessToken() async {
    if (_accessToken != null &&
        _expiresAt != null &&
        DateTime.now().isBefore(_expiresAt!)) {
      return _accessToken!;
    }
    return _fetchToken();
  }

  /// Convenience: returns headers map ready for Drive API calls.
  Future<Map<String, String>> authHeaders() async {
    final token = await getAccessToken();
    return {'Authorization': 'Bearer $token'};
  }

  Future<String> _fetchToken() async {
    // Read service account JSON from env.json at runtime
    final env = await _loadEnv();
    final saBase64 = env['GOOGLE_SERVICE_ACCOUNT_JSON'] as String? ?? '';
    if (saBase64.isEmpty) {
      throw Exception(
        'GOOGLE_SERVICE_ACCOUNT_JSON is not set in env.json. '
        'See lib/services/service_account_auth.dart for setup instructions.',
      );
    }

    late Map<String, dynamic> sa;
    try {
      final decoded = utf8.decode(base64Decode(saBase64));
      sa = jsonDecode(decoded) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('GOOGLE_SERVICE_ACCOUNT_JSON could not be decoded. Ensure it is base64-encoded in env.json.');
    }

    final clientEmail = sa['client_email'] as String?;
    final privateKey = sa['private_key'] as String?;
    if (clientEmail == null || privateKey == null) {
      throw Exception('Service account JSON missing client_email or private_key.');
    }

    // Build JWT claim set
    final now = DateTime.now().toUtc();
    final jwt = JWT(
      {
        'iss': clientEmail,
        'scope': _driveScope,
        'aud': _tokenUrl,
        'iat': now.millisecondsSinceEpoch ~/ 1000,
        'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      },
    );

    // Sign with RSA-256 private key
    late String signedJwt;
    try {
      signedJwt = jwt.sign(
        RSAPrivateKey(privateKey),
        algorithm: JWTAlgorithm.RS256,
      );
    } catch (e) {
      throw Exception('Failed to sign service account JWT: $e');
    }

    // Exchange JWT for access token
    final response = await http.post(
      Uri.parse(_tokenUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': signedJwt,
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Token exchange failed (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _accessToken = data['access_token'] as String?;
    if (_accessToken == null) {
      throw Exception('Token response missing access_token: ${response.body}');
    }

    // Cache for 55 minutes (tokens live 60 min; 5 min buffer)
    _expiresAt = now.add(const Duration(minutes: 55));
    debugPrint('ServiceAccountAuth: new token acquired, expires $_expiresAt');
    return _accessToken!;
  }
}
