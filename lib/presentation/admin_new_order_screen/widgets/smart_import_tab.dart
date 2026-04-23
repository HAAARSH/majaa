import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

/// Phase 2+ placeholder. The real Smart Import UI (paste text / upload image /
/// upload PDF → Gemini parse → review screen → save) lands in a later phase.
/// See NEW_ORDER_TAB_PLAN.md → Smart Import sub-tab for the full spec.
class SmartImportTab extends StatelessWidget {
  const SmartImportTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_rounded, size: 64, color: AppTheme.primary.withValues(alpha: 0.35)),
            const SizedBox(height: 16),
            Text('Smart Import',
              style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.primary),
            ),
            const SizedBox(height: 8),
            Text(
              'Paste brand-software text, upload a PDF, or drop a WhatsApp screenshot — '
              'Gemini will extract the order lines for you to review and save.',
              textAlign: TextAlign.center,
              style: GoogleFonts.manrope(fontSize: 13, color: Colors.black54, height: 1.4),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.shade300),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.construction_rounded, size: 16, color: Colors.amber.shade900),
                  const SizedBox(width: 8),
                  Text('Arriving in Phase 2',
                    style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.amber.shade900),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('Use the Manual tab for now — every feature except the parsing is already wired there.',
              textAlign: TextAlign.center,
              style: GoogleFonts.manrope(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }
}
