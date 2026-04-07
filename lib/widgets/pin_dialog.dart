import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/pin_service.dart';
import '../theme/app_theme.dart';

/// Shows a PIN verification dialog with optional warning message.
/// Returns true if PIN verified, false if cancelled.
/// [warningMessage] shows in red before PIN entry.
/// [requireDouble] if true, asks to enter PIN twice for confirmation.
Future<bool> showPinDialog(
  BuildContext context, {
  String title = 'Enter PIN',
  String? warningMessage,
  bool requireDouble = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PinDialogWidget(
      title: title,
      warningMessage: warningMessage,
      requireDouble: requireDouble,
    ),
  );
  return result ?? false;
}

class _PinDialogWidget extends StatefulWidget {
  final String title;
  final String? warningMessage;
  final bool requireDouble;

  const _PinDialogWidget({
    required this.title,
    this.warningMessage,
    this.requireDouble = false,
  });

  @override
  State<_PinDialogWidget> createState() => _PinDialogWidgetState();
}

class _PinDialogWidgetState extends State<_PinDialogWidget> {
  final _ctrl1 = TextEditingController();
  final _ctrl2 = TextEditingController();
  String? _error;
  bool _firstVerified = false;

  @override
  void dispose() {
    _ctrl1.dispose();
    _ctrl2.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final pin = _ctrl1.text.trim();
    if (pin.length != 4) {
      setState(() => _error = 'PIN must be 4 digits');
      return;
    }

    final ok = await PinService.instance.verify(pin);
    if (!ok) {
      setState(() => _error = 'Incorrect PIN');
      _ctrl1.clear();
      return;
    }

    if (widget.requireDouble && !_firstVerified) {
      setState(() {
        _firstVerified = true;
        _error = null;
      });
      _ctrl1.clear();
      return;
    }

    if (widget.requireDouble && _firstVerified) {
      final pin2 = _ctrl1.text.trim();
      final firstOk = await PinService.instance.verify(pin2);
      if (!firstOk) {
        setState(() => _error = 'PIN does not match');
        _ctrl1.clear();
        return;
      }
    }

    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.lock_rounded, size: 22, color: AppTheme.primary),
          const SizedBox(width: 8),
          Text(widget.title, style: GoogleFonts.manrope(fontWeight: FontWeight.w800, fontSize: 17)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.warningMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_rounded, color: Colors.red.shade700, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.warningMessage!,
                      style: GoogleFonts.manrope(fontSize: 12, color: Colors.red.shade800, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            _firstVerified ? 'Enter PIN again to confirm' : 'Enter 4-digit PIN to proceed',
            style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl1,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 4,
            obscureText: true,
            textAlign: TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 12),
            decoration: InputDecoration(
              counterText: '',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.primary, width: 2),
              ),
            ),
            onChanged: (v) {
              if (v.length == 4) _verify();
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: GoogleFonts.manrope(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
        ),
        FilledButton(
          onPressed: _verify,
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
          child: Text('Verify', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
