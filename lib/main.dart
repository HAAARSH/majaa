import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sizer/sizer.dart';
import 'package:workmanager/workmanager.dart';
import 'services/drive_sync_service.dart';
import 'services/google_drive_auth_service.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'services/cart_service.dart';
import 'services/offline_service.dart';
import 'services/supabase_service.dart';
import 'services/session_service.dart';
import 'services/update_service.dart';
import 'routes/app_routes.dart';
import 'theme/app_theme.dart';

/// Global navigator key — allows navigation from outside the widget tree
/// (e.g. session-expiry handler in WidgetsBindingObserver).
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Track last update check to avoid excessive checks
DateTime? _lastUpdateCheck;

// WorkManager callback — only runs on mobile, never on web
@pragma('vm:entry-point')
void _workManagerCallbackDispatcher() {
  if (kIsWeb) return;
  _runWorkManagerTask();
}

void _runWorkManagerTask() {
  // Keep workmanager import at file level — it's tree-shaken on web
  Workmanager().executeTask((taskName, inputData) async {
    try {
      await Hive.initFlutter();
      await SupabaseService.initialize();
      await GoogleDriveAuthService.instance.init();
      if (!GoogleDriveAuthService.instance.isSignedIn) {
        debugPrint('WorkManager: Google Drive not signed in, skipping sync');
        return true;
      }
      await DriveSyncService.instance.syncAll();
    } catch (e) {
      debugPrint('WorkManager sync error: $e');
    }
    return Future.value(true);
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  GoogleFonts.config.allowRuntimeFetching = false;
  await SupabaseService.initialize();
  await GoogleDriveAuthService.instance.init();
  await CartService.instance.restoreCart();
  await SessionService.instance.init(); // load persisted session timestamp
  await OfflineService.instance.init(); // open offline_orders Hive box
  if (!kIsWeb) {
    OfflineService.instance.startMonitoring(); // connectivity watch + 1-hr cache refresh

    // Initialize WorkManager for background Drive sync (every 24 hours)
    await Workmanager().initialize(_workManagerCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      'majaa-drive-sync',
      'driveSyncTask',
      frequency: const Duration(hours: 24),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Colors.white,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              "UI Error:\n${details.exception}",
              style: const TextStyle(
                  color: Colors.red, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  };

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Check expiry BEFORE updating timestamp
      if (SessionService.instance.isSessionExpired()) {
        SessionService.instance.reset();
        SupabaseService.instance.signOut().then((_) {
          navigatorKey.currentState?.pushNamedAndRemoveUntil(
            AppRoutes.loginScreen,
            (_) => false,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final ctx = navigatorKey.currentContext;
            if (ctx != null && ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                  content: Text('Session expired. Please log in again.'),
                  duration: Duration(seconds: 4),
                ),
              );
            }
          });
        });
      } else {
        // Update timestamp on every resume (app came back to foreground)
        SessionService.instance.markActive();
        
        // Check for updates if not checked in last 24 hours
        final now = DateTime.now();
        if (_lastUpdateCheck == null || 
            now.difference(_lastUpdateCheck!).inHours >= 24) {
          _lastUpdateCheck = now;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final ctx = navigatorKey.currentContext;
            if (ctx != null && ctx.mounted) {
              UpdateService.checkForUpdates(ctx);
            }
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: SessionService.instance.markActive,
      onPanDown: (_) => SessionService.instance.markActive(),
      child: Sizer(
        builder: (context, orientation, deviceType) {
          return MaterialApp(
            navigatorKey: navigatorKey,
            title: 'MAJAA Sales',
            theme: AppTheme.lightTheme,
            debugShowCheckedModeBanner: false,
            routes: AppRoutes.routes,
            initialRoute: AppRoutes.initial,
            builder: (context, child) => SafeArea(
              top: false,
              child: _OfflineWrapper(child: child!),
            ),
          );
        },
      ),
    );
  }
}

class _OfflineWrapper extends StatefulWidget {
  final Widget child;
  const _OfflineWrapper({required this.child});

  @override
  State<_OfflineWrapper> createState() => _OfflineWrapperState();
}

class _OfflineWrapperState extends State<_OfflineWrapper> {
  bool _isOffline = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final offline = results.every((r) => r == ConnectivityResult.none);
      if (mounted && offline != _isOffline) setState(() => _isOffline = offline);
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_isOffline)
          Material(
            color: Colors.orange.shade700,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 14),
                      const SizedBox(width: 8),
                      Text(
                        'Working Offline — orders will sync when connected',
                        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
