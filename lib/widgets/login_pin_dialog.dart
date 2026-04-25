import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/login_pin_service.dart';
import '../theme/app_theme.dart';

enum LoginPinDialogMode { setup, verify }

class LoginPinDialogResult {
  /// Setup mode: the PIN the user just chose (4 digits).
  /// Verify mode: unused.
  final String? pin;

  /// Verify mode: true if the entered PIN matched the server-side hash.
  /// Setup mode: always true when the dialog returns a non-null result.
  final bool verified;

  /// Verify mode: true if the user tapped "Forgot PIN — use password instead".
  final bool forgotPressed;

  const LoginPinDialogResult({
    this.pin,
    this.verified = false,
    this.forgotPressed = false,
  });
}

/// Per-user login PIN dialog. Strictly separate from the admin
/// [showPinDialog] in widgets/pin_dialog.dart — different service, different
/// keys, different flow.
///
/// In [LoginPinDialogMode.setup]: collects a 4-digit PIN twice, non-
/// dismissible, returns it for the caller to save via
/// [LoginPinService.setPin].
///
/// In [LoginPinDialogMode.verify]: requires [email]; calls
/// [LoginPinService.verify] internally; shows error inline on wrong PIN;
/// honors local lockout. Pops on success or when the user taps "Forgot PIN".
Future<LoginPinDialogResult?> showLoginPinDialog(
  BuildContext context, {
  required LoginPinDialogMode mode,
  String? email,
}) {
  assert(
    mode == LoginPinDialogMode.setup || (email != null && email.isNotEmpty),
    'verify mode requires email',
  );
  return showDialog<LoginPinDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LoginPinDialogWidget(mode: mode, email: email),
  );
}

class _LoginPinDialogWidget extends StatefulWidget {
  final LoginPinDialogMode mode;
  final String? email;

  const _LoginPinDialogWidget({required this.mode, this.email});

  @override
  State<_LoginPinDialogWidget> createState() => _LoginPinDialogWidgetState();
}

class _LoginPinDialogWidgetState extends State<_LoginPinDialogWidget> {
  final _ctrl = TextEditingController();
  String? _firstPin; // setup mode only — first entry
  String? _error;
  bool _busy = false;

  bool get _isSetup => widget.mode == LoginPinDialogMode.setup;
  bool get _setupConfirmStep => _isSetup && _firstPin != null;

  @override
  void initState() {
    super.initState();
    _maybeShowLockoutOnOpen();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _maybeShowLockoutOnOpen() async {
    if (_isSetup) return;
    final locked = await LoginPinService.instance.isLockedOut;
    if (!locked || !mounted) return;
    final remaining = await LoginPinService.instance.remainingLockout;
    if (!mounted) return;
    setState(() {
      _error = 'Too many wrong attempts. Try again in '
          '${remaining.inMinutes}m ${remaining.inSeconds % 60}s.';
    });
  }

  Future<void> _onComplete(String value) async {
    if (_busy) return;
    final pin = value.trim();
    if (pin.length != 4) {
      setState(() => _error = 'PIN must be 4 digits');
      return;
    }

    if (_isSetup) {
      if (_firstPin == null) {
        setState(() {
          _firstPin = pin;
          _error = null;
        });
        _ctrl.clear();
        return;
      }
      if (pin != _firstPin) {
        setState(() {
          _error = 'PINs do not match. Try again.';
          _firstPin = null;
        });
        _ctrl.clear();
        return;
      }
      Navigator.pop(
        context,
        LoginPinDialogResult(pin: pin, verified: true),
      );
      return;
    }

    // verify mode
    setState(() => _busy = true);
    final ok =
        await LoginPinService.instance.verify(widget.email!, pin);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, const LoginPinDialogResult(verified: true));
      return;
    }
    final locked = await LoginPinService.instance.isLockedOut;
    if (!mounted) return;
    if (locked) {
      final remaining = await LoginPinService.instance.remainingLockout;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Too many wrong attempts. Try again in '
            '${remaining.inMinutes}m ${remaining.inSeconds % 60}s.';
      });
    } else {
      setState(() {
        _busy = false;
        _error = 'Incorrect PIN. Try again.';
      });
    }
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final title = _isSetup
        ? (_setupConfirmStep ? 'Confirm your PIN' : 'Set your login PIN')
        : 'Enter your login PIN';
    final subtitle = _isSetup
        ? (_setupConfirmStep
            ? 'Re-enter the same 4 digits to confirm.'
            : 'Pick a 4-digit PIN. You\'ll use it to sign back in if your '
                'session expires — no need to re-enter your password.')
        : 'Enter the 4-digit PIN you set on this device.';

    return PopScope(
      canPop: false,
      child: AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.lock_rounded,
                size: 22, color: AppTheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: GoogleFonts.manrope(
                      fontWeight: FontWeight.w800, fontSize: 17)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(subtitle,
                style: GoogleFonts.manrope(
                    fontSize: 13, color: AppTheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: GoogleFonts.manrope(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 12),
              decoration: InputDecoration(
                counterText: '',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: AppTheme.primary, width: 2),
                ),
              ),
              onChanged: (v) {
                if (v.length == 4) _onComplete(v);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.manrope(
                      fontSize: 12,
                      color: Colors.red,
                      fontWeight: FontWeight.w600)),
            ],
            if (!_isSetup) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.pop(
                        context,
                        const LoginPinDialogResult(forgotPressed: true),
                      ),
                child: Text(
                  'Forgot PIN — use password instead',
                  style: GoogleFonts.manrope(
                      fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
