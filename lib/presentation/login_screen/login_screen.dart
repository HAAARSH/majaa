import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../services/session_service.dart';
import '../../services/update_service.dart';
import '../../theme/app_theme.dart';
import './widgets/login_form_widget.dart';
import '../../services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  bool _isLoading = false;
  final String _loadingMessage = 'Signing in...';
  bool _syncOnLogin = true;
  bool _obscurePassword = true;

  Future<void> _tryAutoResume() async {
    debugPrint('AutoResume: checking session...');
    if (SessionService.instance.isSessionExpired()) {
      debugPrint('AutoResume: session expired, showing login');
      return;
    }
    try {
      final canResume = await AuthService.instance.attemptOfflineResume();
      debugPrint('AutoResume: canResume=$canResume, mounted=$mounted');
      if (!canResume || !mounted) return;

      SessionService.instance.markActive();

      // Determine correct route based on user role
      String route = AppRoutes.beatSelectionScreen;
      try {
        final email = SupabaseService.instance.client.auth.currentUser?.email;
        if (email != null) {
          final userData = await SupabaseService.instance.client
              .from('app_users')
              .select('role')
              .eq('email', email)
              .maybeSingle();
          final role = userData?['role'] as String? ?? 'sales_rep';
          SupabaseService.instance.currentUserRole = role;
          if (role == 'admin' || role == 'super_admin') {
            route = AppRoutes.adminPanelScreen;
          } else if (role == 'delivery_rep') {
            route = AppRoutes.deliveryDashboardScreen;
          }
        }
      } catch (_) {
        // If role fetch fails (offline), default to beat selection
      }

      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Navigator.pushReplacementNamed(context, route);
          }
        });
      }
    } catch (e) {
      debugPrint('AutoResume: error $e');
    }
  }

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tryAutoResume();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UpdateService.checkForUpdates(context);
    });
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _animationController,
          curve: const Interval(0.0, 0.8, curve: Curves.easeOut)),
    );

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(
          CurvedAnimation(
              parent: _animationController,
              curve: const Interval(0.1, 1.0, curve: Curves.easeOutCubic)),
        );

    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleForgotPassword() {
    final email = _emailController.text.trim();
    final emailCtrl = TextEditingController(text: email);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Reset Password', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Enter your email to receive a password reset link.',
                style: GoogleFonts.manrope(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                prefixIcon: const Icon(Icons.email_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final e = emailCtrl.text.trim();
              if (e.isEmpty) return;
              Navigator.pop(ctx);
              try {
                await SupabaseService.instance.sendPasswordResetEmail(e);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Password reset email sent! Check your inbox.'), backgroundColor: Colors.green),
                  );
                }
              } catch (err) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $err'), backgroundColor: Colors.red),
                  );
                }
              }
            },
            child: const Text('Send Reset Link'),
          ),
        ],
      ),
    ).then((_) => emailCtrl.dispose());
  }

  Future<void> _handleLogin() async {
    HapticFeedback.lightImpact();

    if (!(_formKey.currentState?.validate() ?? true)) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final email = _emailController.text.trim().toLowerCase();

      // 1. Check if password is correct (Returns true/false)
      final success = await AuthService.instance
          .loginWithCredentials(
        email,
        _passwordController.text,
      )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (success) {
        HapticFeedback.mediumImpact();
        TextInput.finishAutofillContext(); // Tell OS to save credentials
        SessionService.instance.markActive(); // Start 6-hour session timer

        // 2. Fetch the User Profile & Role for Routing
        final userData = await SupabaseService.instance.client
            .from('app_users')
            .select()
            .eq('email', email)
            .maybeSingle();

        String role = 'sales_rep'; // Default fallback
        AppUserModel? userModel;

        if (userData != null) {
          userModel = AppUserModel.fromJson(userData);
          role = userModel.role;
        }

        // 3. --- ROLE-BASED ROUTING ---
        SupabaseService.instance.currentUserRole = role;
        if (role == 'admin' || role == 'super_admin') {
          Navigator.pushReplacementNamed(context, AppRoutes.adminPanelScreen,
              arguments: {'user': userModel});
        } else if (role == 'delivery_rep') {
          Navigator.pushReplacementNamed(context, AppRoutes.deliveryDashboardScreen,
              arguments: {'user': userModel});
        } else {
          // Default for Sales Reps
          Navigator.pushReplacementNamed(context, AppRoutes.beatSelectionScreen,
              arguments: {'user': userModel});
        }
      } else {
        HapticFeedback.vibrate();
        _passwordController.clear();
        setState(() {
          _errorMessage = 'Invalid credentials';
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('🚨 RAW LOGIN ERROR: $e');

      if (!mounted) return;
      HapticFeedback.vibrate();
      setState(() {
        _errorMessage = 'Login failed. Check internet or credentials.';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 600;
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: isTablet ? _buildTabletLayout() : _buildPhoneLayout(),
    );
  }

  Widget _buildPhoneLayout() {
    final screenHeight = MediaQuery.of(context).size.height;
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: screenHeight * 0.40,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppTheme.primary, AppTheme.primaryLight],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(40),
                bottomRight: Radius.circular(40),
              ),
            ),
          ),
        ),
        SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: _buildBrandingBlock(dark: false),
                  ),
                ),
                const SizedBox(height: 32),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: SlideTransition(
                      position: _slideAnimation,
                      child: _buildFormCard(),
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabletLayout() {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppTheme.primary, AppTheme.primaryLight],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: SafeArea(
              child: Center(
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: _buildBrandingBlock(dark: false),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          flex: 6,
          child: Container(
            color: AppTheme.background,
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: FadeTransition(
                      opacity: _fadeAnimation,
                      child: SlideTransition(
                        position: _slideAnimation,
                        child: _buildFormCard(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBrandingBlock({required bool dark}) {
    final textColor = dark ? AppTheme.onSurface : Colors.white;
    final subtitleColor = dark ? AppTheme.onSurfaceVariant : Colors.white.withAlpha(204);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 100,
          height: 100,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(38),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withAlpha(77), width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: AppTheme.primary.withAlpha(50),
                  blurRadius: 20,
                  offset: const Offset(0, 10)),
            ],
          ),
          child: SvgPicture.asset(
            'assets/images/logo.png.svg',
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Madhav & Jagannath\nAssociates',
          textAlign: TextAlign.center,
          style: GoogleFonts.manrope(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: textColor,
            height: 1.2,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(30),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text(
            'Field Sales & Delivery',
            style: GoogleFonts.manrope(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: subtitleColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFormCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(15),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(32),
      child: AutofillGroup(
        child: LoginFormWidget(
          formKey: _formKey,
          emailController: _emailController,
          passwordController: _passwordController,
          obscurePassword: _obscurePassword,
          syncOnLogin: _syncOnLogin,
          isLoading: _isLoading,
          loadingMessage: _loadingMessage,
          errorMessage: _errorMessage,
          onTogglePasswordVisibility: () {
            HapticFeedback.selectionClick();
            setState(() => _obscurePassword = !_obscurePassword);
          },
          onSyncChanged: (val) {
            HapticFeedback.selectionClick();
            setState(() => _syncOnLogin = val ?? true);
          },
          onLogin: _handleLogin,
          onForgotPassword: _handleForgotPassword,
        ),
      ),
    );
  }
}