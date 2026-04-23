import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/pricing.dart';
import '../../../services/auth_service.dart';
import '../../../services/offline_service.dart';
import '../../../services/smart_import_service.dart';
import '../../../services/smart_import_share_service.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

/// Smart Import sub-tab — covers Phases 2/3/4/5 of NEW_ORDER_TAB_PLAN.md.
///
/// Input paths:
///   * Paste text (brand_software_text or whatsapp_text — auto-classified,
///     admin can override).
///   * Upload PDF (structured purchase order, EAN-first matching).
///   * Upload image (screenshot OR handwritten photo — admin toggle).
///   * Android share-intent (Phase 5) delivers content here via a
///     top-level listener — content arrives in [_pasteCtl] or [_pickedBytes].
///
/// Flow:
///   1. Admin picks team + rep attribution + input (paste or upload).
///   2. SHA-256 hash (normalized for text, raw for bytes) checks
///      smart_import_history.UNIQUE(input_hash, team_id) for dedup.
///   3. Gemini parses with the per-type prompt → SmartImportDraft.
///   4. Local resolvers map customer + each product. Lines are rendered
///      with confidence chips. Handwritten inputs force confirmed=false
///      on every line so Save is gated on admin review.
///   5. CSDS breakdown computed per line (respects kForcedOff flag).
///   6. Stock validation per line (soft LOW STOCK chip).
///   7. Save → createOrder (source='office', overrideUserId=rep) → alias
///      writes → smart_import_history audit row.
class SmartImportTab extends StatefulWidget {
  const SmartImportTab({super.key});

  @override
  State<SmartImportTab> createState() => _SmartImportTabState();
}

enum _Stage { compose, reviewing }

class _SmartImportTabState extends State<SmartImportTab> {
  // ── Stage + entry UI state ──────────────────────────────────────────────
  _Stage _stage = _Stage.compose;
  String _team = 'JA';
  List<AppUserModel> _reps = [];
  AppUserModel? _selectedRep;
  final TextEditingController _pasteCtl = TextEditingController();

  // File-upload state. When non-null, parse routes to parseFromBytes() and
  // the paste box is ignored. Mime + inputType are detected from extension.
  Uint8List? _pickedBytes;
  String? _pickedFileName;
  String? _pickedMime;       // 'application/pdf' | 'image/jpeg' | 'image/png'
  String? _pickedInputType;  // 'pdf' | 'image_screenshot' | 'image_handwritten'

  /// Text-path classification — null until the paste box has non-empty text.
  /// Admin can override via the dropdown next to the paste box.
  String? _textInputType;

  bool _loading = true;
  bool _parsing = false;

  // ── Review state ────────────────────────────────────────────────────────
  SmartImportDraft? _draft;
  String? _inputHash;
  ResolvedCustomer? _resolvedCustomer;
  CustomerModel? _chosenCustomer;
  final List<_ReviewLine> _reviewLines = [];
  DateTime _deliveryDate = DateTime.now().add(const Duration(days: 1));
  final TextEditingController _notesCtl = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadForTeam(_team);
    // Phase 5: listen for Android share-intent arrivals. The listener fires
    // both for cold-start shares (app launched from share sheet) and for
    // shares received while the tab is already alive. If a share is pending
    // NOW (populated during main()'s init before this widget mounted), the
    // WidgetsBinding.postFrameCallback drains it on first frame.
    SmartImportShareService.pendingShare.addListener(_onSharePayload);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSharePayload());
  }

  @override
  void dispose() {
    SmartImportShareService.pendingShare.removeListener(_onSharePayload);
    _pasteCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  /// Drains the shared payload from the system share sheet into this tab's
  /// input fields. Called from an initial post-frame callback AND whenever
  /// a new share arrives via the notifier.
  void _onSharePayload() {
    final payload = SmartImportShareService.pendingShare.value;
    if (payload == null || !payload.hasPayload) return;
    // Only auto-apply while compose stage is visible. If the admin is deep
    // in a review, don't stomp their draft — the notifier keeps the payload
    // so they can go back and apply after.
    if (_stage != _Stage.compose) return;

    setState(() {
      if (payload.text != null && payload.text!.trim().isNotEmpty) {
        _pasteCtl.text = payload.text!;
        _textInputType = null; // let classifier re-run on this fresh text
      } else if (payload.fileBytes != null) {
        _pickedBytes = payload.fileBytes;
        _pickedFileName = payload.fileName;
        _pickedMime = payload.fileMime;
        _pickedInputType = (payload.fileMime == 'application/pdf')
            ? 'pdf'
            : 'image_screenshot';
        _pasteCtl.clear();
      }
    });
    SmartImportShareService.consume();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload.text != null
                ? 'Text from share loaded — pick team + rep, then Parse.'
                : 'File "${payload.fileName ?? "shared"}" loaded — pick team + rep, then Parse.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _loadForTeam(String team) async {
    setState(() => _loading = true);
    try {
      final reps = await SupabaseService.instance.getSalesRepsForTeam(team);
      if (!mounted) return;
      setState(() {
        _reps = reps;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _onTeamChanged(String t) {
    if (t == _team) return;
    setState(() {
      _team = t;
      _selectedRep = null;
    });
    _loadForTeam(t);
  }

  // ── File pick handlers ──────────────────────────────────────────────────
  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true, // needed for web where .path is null
    );
    await _acceptPicked(result, expectedInputType: 'pdf');
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png'],
      withData: true,
    );
    await _acceptPicked(result, expectedInputType: 'image_screenshot');
  }

  Future<void> _acceptPicked(
      FilePickerResult? result, {required String expectedInputType}) async {
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null && file.path == null) return;
    try {
      Uint8List bytes;
      if (file.bytes != null) {
        bytes = file.bytes!;
      } else {
        bytes = await File(file.path!).readAsBytes();
      }
      final ext = (file.extension ?? '').toLowerCase();
      final mime = switch (ext) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        _ => 'image/jpeg',
      };
      setState(() {
        _pickedBytes = bytes;
        _pickedFileName = file.name;
        _pickedMime = mime;
        _pickedInputType = expectedInputType;
        // File supersedes any pasted text. Clear it so the user isn't
        // confused about which source Parse will use.
        _pasteCtl.clear();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not read file: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _clearPickedFile() {
    setState(() {
      _pickedBytes = null;
      _pickedFileName = null;
      _pickedMime = null;
      _pickedInputType = null;
    });
  }

  // ── Parse pipeline ──────────────────────────────────────────────────────
  Future<void> _parse() async {
    if (_selectedRep == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a rep for this import first')),
      );
      return;
    }

    final hasFile = _pickedBytes != null;
    final raw = _pasteCtl.text;
    if (!hasFile && raw.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paste text or upload a PDF / image first')),
      );
      return;
    }
    setState(() => _parsing = true);

    try {
      // Hash + dedup guard identical for all input types.
      final hash = hasFile
          ? SmartImportService.computeFileHash(_pickedBytes!)
          : SmartImportService.computeInputHash(raw);
      final dup = await SmartImportService.instance.findImportByHash(hash, _team);
      if (dup != null) {
        if (!mounted) return;
        setState(() => _parsing = false);
        _showDupDialog(dup);
        return;
      }

      // Resolve the effective input type for text. Admin may have overridden
      // via the dropdown; otherwise we classify heuristically.
      final effectiveTextType = _textInputType ??
          SmartImportService.classifyTextInput(raw);

      final draft = hasFile
          ? await SmartImportService.instance.parseFromBytes(
              bytes: _pickedBytes!,
              mimeType: _pickedMime!,
              inputType: _pickedInputType!,
            )
          : await SmartImportService.instance.parseText(raw, effectiveTextType);
      if (draft == null) {
        if (!mounted) return;
        setState(() => _parsing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Parse failed. Check your Gemini key or try a smaller paste.'),
            backgroundColor: Colors.red.shade700,
          ),
        );
        return;
      }

      // Resolve customer.
      final svc = SmartImportService.instance;
      final resolvedCust = await svc.resolveCustomer(
        extractedName: draft.customerNameAsWritten,
        extractedPhone: draft.customerPhoneFromInput,
        teamId: _team,
      );

      // Resolve each product line.
      final isHandwritten = _pickedInputType == 'image_handwritten';
      final lines = <_ReviewLine>[];
      for (final dl in draft.lines) {
        final rp = await svc.resolveProduct(
          nameAsWritten: dl.nameAsWritten,
          eanCode: dl.eanCode,
          customerId: resolvedCust.match?.id,
          teamId: _team,
        );
        lines.add(_ReviewLine(
          draft: dl,
          resolved: rp,
          chosen: rp.match,
          qty: dl.quantity,
          // Handwritten: NEVER pre-check. Admin must confirm every line.
          // Other input types: pre-check only on strong matches.
          confirmed: !isHandwritten && rp.match != null && rp.confidence >= 0.85,
        ));
      }

      if (!mounted) return;
      setState(() {
        _inputHash = hash;
        _draft = draft;
        _resolvedCustomer = resolvedCust;
        _chosenCustomer = resolvedCust.match;
        _reviewLines
          ..clear()
          ..addAll(lines);
        _notesCtl.text = draft.notes ?? '';
        _stage = _Stage.reviewing;
        _parsing = false;
      });

      // Kick off CSDS recompute for each line now that we may have a customer.
      _recomputeAllCsds();
    } catch (e) {
      if (!mounted) return;
      setState(() => _parsing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Parse error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _showDupDialog(Map<String, dynamic> dup) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Duplicate import'),
        content: Text(
          'This exact text was already imported${dup['imported_at'] != null ? ' at ${dup['imported_at']}' : ''}. '
          '${dup['resulting_order_id'] != null ? 'Order ${dup['resulting_order_id']} was created from it.' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  // ── CSDS recompute per review line ──────────────────────────────────────
  Future<void> _recomputeCsds(_ReviewLine line) async {
    if (_chosenCustomer == null || line.chosen == null) {
      if (mounted) setState(() => line.breakdown = null);
      return;
    }
    try {
      final brand = line.chosen!.category.isNotEmpty
          ? line.chosen!.category
          : (line.chosen!.company ?? '');
      final b = await CsdsPricing.priceFor(
        baseRate: line.chosen!.unitPrice,
        qty: line.qty,
        taxPercent: line.chosen!.gstRate * 100,
        customerId: _chosenCustomer!.id,
        company: brand,
        itemGroup: line.chosen!.itemGroup ?? '',
        teamId: _team,
      );
      if (!mounted) return;
      setState(() => line.breakdown = b);
    } catch (e) {
      debugPrint('[SmartImport] CSDS recompute failed: $e');
    }
  }

  Future<void> _recomputeAllCsds() async {
    for (final l in _reviewLines) {
      await _recomputeCsds(l);
    }
  }

  // ── Save pipeline ───────────────────────────────────────────────────────
  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _submitting = true);
    final originalTeam = AuthService.currentTeam;
    AuthService.currentTeam = _team;

    final orderId = _generateOrderId();
    final itemsJson = _reviewLines
        .where((l) => l.chosen != null && l.qty > 0 && l.confirmed)
        .map((l) => l.toJson(orderId))
        .toList();

    final subtotal = _reviewLines.fold<double>(0, (a, l) => a + l.subtotal);
    final gst = _reviewLines.fold<double>(0, (a, l) => a + l.gst);
    final grand = subtotal + gst;
    final units = _reviewLines.fold<int>(0, (a, l) => a + l.qty);

    try {
      await SupabaseService.instance.createOrder(
        orderId: orderId,
        customerId: _chosenCustomer!.id,
        customerName: _chosenCustomer!.name,
        beat: '',
        deliveryDate: _deliveryDate,
        subtotal: subtotal,
        vat: gst,
        grandTotal: grand,
        itemCount: itemsJson.length,
        totalUnits: units,
        notes: _notesCtl.text,
        items: itemsJson,
        isOutOfBeat: false,
        overrideUserId: _selectedRep!.id,
        source: 'office',
      );

      // Alias writes — best-effort, do not block save.
      final svc = SmartImportService.instance;
      final adminAuthId = svc.currentAdminUserId ?? '';
      try {
        if (_draft != null &&
            _chosenCustomer != null &&
            _draft!.customerNameAsWritten.isNotEmpty &&
            _draft!.customerNameAsWritten.toLowerCase() !=
                _chosenCustomer!.name.toLowerCase()) {
          await svc.writeCustomerAlias(
            aliasText: _draft!.customerNameAsWritten,
            customerId: _chosenCustomer!.id,
            teamId: _team,
            createdByUserId: adminAuthId,
          );
        }
        for (final l in _reviewLines) {
          if (l.chosen != null && l.draft.nameAsWritten.isNotEmpty) {
            await svc.writeProductAlias(
              customerId: _chosenCustomer?.id,
              aliasText: l.draft.nameAsWritten,
              productId: l.chosen!.id,
              teamId: _team,
              createdByUserId: adminAuthId,
            );
          }
        }
      } catch (e) {
        debugPrint('[SmartImport] alias writes failed: $e');
      }

      // Audit row — record which input path created this order.
      if (_inputHash != null && _draft != null) {
        final historyInputType =
            _pickedInputType ?? 'brand_software_text';
        final historyPreview = _pickedFileName != null
            ? 'file: $_pickedFileName (${_pickedBytes?.length ?? 0} bytes, $_pickedMime)'
            : _pasteCtl.text;
        await svc.writeImportHistory(
          inputType: historyInputType,
          inputPreview: historyPreview,
          inputHash: _inputHash!,
          parsedResult: {
            'customer': {
              'name_as_written': _draft!.customerNameAsWritten,
              'phone_if_present': _draft!.customerPhoneFromInput,
            },
            'lines': _draft!.lines
                .map((l) => {
                      'name_as_written': l.nameAsWritten,
                      'quantity': l.quantity,
                      'unit_hint': l.unitHint,
                      'confidence': l.confidence,
                    })
                .toList(),
            'overall_parse_confidence': _draft!.overallConfidence,
          },
          adminCorrections: {
            'customer_changed': _resolvedCustomer?.match?.id != _chosenCustomer?.id,
            'line_count_saved': itemsJson.length,
            'line_count_parsed': _draft!.lines.length,
          },
          resultingOrderId: orderId,
          teamId: _team,
          attributedRepUserId: _selectedRep!.id,
          importedByUserId: adminAuthId,
        );
      }

      if (!mounted) return;
      _showSuccess(orderId, offline: false);
      _resetAll();
    } catch (e) {
      try {
        await OfflineService.instance.queueOperation('order', {
          'order_id': orderId,
          'customer_id': _chosenCustomer!.id,
          'customer_name': _chosenCustomer!.name,
          'beat': '',
          'is_out_of_beat': false,
          'delivery_date': _deliveryDate.toIso8601String(),
          'subtotal': subtotal,
          'vat': gst,
          'grand_total': grand,
          'item_count': itemsJson.length,
          'total_units': units,
          'notes': _notesCtl.text,
          'items': itemsJson,
          'override_user_id': _selectedRep!.id,
          'source': 'office',
        });
        if (!mounted) return;
        _showSuccess(orderId, offline: true);
        _resetAll();
      } catch (e2) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e2'), backgroundColor: Colors.red),
        );
      }
    } finally {
      AuthService.currentTeam = originalTeam;
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _generateOrderId() {
    final ts = DateTime.now();
    return 'IMP-$_team-'
        '${ts.year.toString().substring(2)}'
        '${ts.month.toString().padLeft(2, '0')}'
        '${ts.day.toString().padLeft(2, '0')}'
        '${ts.hour.toString().padLeft(2, '0')}'
        '${ts.minute.toString().padLeft(2, '0')}'
        '${ts.second.toString().padLeft(2, '0')}';
  }

  bool get _canSave {
    if (_submitting) return false;
    if (_chosenCustomer == null || _selectedRep == null) return false;
    if (_reviewLines.isEmpty) return false;
    // Every line must have a matched product AND be confirmed AND have qty > 0.
    return _reviewLines.every((l) => l.chosen != null && l.confirmed && l.qty > 0);
  }

  void _showSuccess(String orderId, {required bool offline}) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          Icon(offline ? Icons.cloud_off_rounded : Icons.check_circle_rounded,
              color: offline ? Colors.orange : Colors.green),
          const SizedBox(width: 8),
          Text(offline ? 'Queued offline' : 'Order saved'),
        ]),
        content: Text(
          offline
              ? 'Order $orderId queued — will sync when online.'
              : 'Order $orderId saved to $_team. Attributed to ${_selectedRep?.fullName ?? "—"}.',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  void _resetAll() {
    setState(() {
      _stage = _Stage.compose;
      _pasteCtl.clear();
      _notesCtl.clear();
      _draft = null;
      _inputHash = null;
      _pickedBytes = null;
      _pickedFileName = null;
      _pickedMime = null;
      _pickedInputType = null;
      _resolvedCustomer = null;
      _chosenCustomer = null;
      _reviewLines.clear();
      _deliveryDate = DateTime.now().add(const Duration(days: 1));
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_stage == _Stage.compose) return _buildCompose();
    return _buildReview();
  }

  // ── Compose view ───────────────────────────────────────────────────────
  Widget _buildCompose() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel('TEAM'),
          Row(children: [
            for (final t in ['JA', 'MA'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(t == 'JA' ? 'Jagannath' : 'Madhav',
                      style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
                  selected: _team == t,
                  onSelected: (_) => _onTeamChanged(t),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          _sectionLabel('ATTRIBUTE TO REP'),
          DropdownButtonFormField<AppUserModel>(
            initialValue: _selectedRep,
            isExpanded: true,
            decoration: _fieldDecoration(hint: 'Pick a rep (brand_rep highlighted)'),
            items: [
              for (final r in _reps)
                DropdownMenuItem<AppUserModel>(
                  value: r,
                  child: Row(children: [
                    if (r.role == 'brand_rep')
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.purple.shade100,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('BRAND',
                            style: GoogleFonts.manrope(
                                fontSize: 9, fontWeight: FontWeight.w800, color: Colors.purple.shade700)),
                      ),
                    Expanded(child: Text(r.fullName, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
            ],
            onChanged: (r) => setState(() => _selectedRep = r),
          ),
          const SizedBox(height: 16),
          _sectionLabel('INPUT'),
          if (_pickedBytes != null) _buildPickedFileCard() else _buildPasteBox(),
          const SizedBox(height: 10),
          if (_pickedBytes == null) _buildUploadButtons(),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _parsing ? null : _parse,
            icon: _parsing
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(
              _parsing
                  ? 'Parsing…'
                  : (_pickedBytes != null
                      ? 'Parse ${_pickedInputType == "pdf" ? "PDF" : "image"} with Gemini'
                      : 'Parse text with Gemini'),
              style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: AppTheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: Colors.blue.shade800),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Duplicate guard: the same paste (normalized) can only be imported once per team. '
                    'Nothing is saved until you review and confirm every line.',
                    style: GoogleFonts.manrope(fontSize: 11, color: Colors.blue.shade900, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasteBox() {
    final text = _pasteCtl.text;
    final hasText = text.trim().isNotEmpty;
    final detected = hasText
        ? (_textInputType ?? SmartImportService.classifyTextInput(text))
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _pasteCtl,
          maxLines: 10,
          decoration: _fieldDecoration(
            hint: 'Paste brand-software text, WhatsApp message — or use the upload buttons below.',
          ),
          onChanged: (_) => setState(() {/* trigger classifier chip rebuild */}),
        ),
        if (hasText)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_rounded, size: 14, color: Colors.black54),
                const SizedBox(width: 6),
                Text('Type:',
                    style: GoogleFonts.manrope(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  isDense: true,
                  value: detected,
                  items: const [
                    DropdownMenuItem(value: 'brand_software_text', child: Text('Brand software (GUBB/SCO)')),
                    DropdownMenuItem(value: 'whatsapp_text', child: Text('WhatsApp / casual')),
                  ],
                  onChanged: (v) => setState(() => _textInputType = v),
                ),
                const SizedBox(width: 6),
                if (_textInputType == null)
                  Text('(auto)',
                      style: GoogleFonts.manrope(fontSize: 10, color: Colors.black38)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPickedFileCard() {
    final sizeKb = ((_pickedBytes?.length ?? 0) / 1024).toStringAsFixed(1);
    final isPdf = _pickedInputType == 'pdf';
    final isImage = !isPdf;
    final isHandwritten = _pickedInputType == 'image_handwritten';
    final icon = isPdf ? Icons.picture_as_pdf_rounded : Icons.image_rounded;
    final accent = isPdf ? Colors.red.shade700 : Colors.teal.shade700;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_pickedFileName ?? '—',
                        style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
                    Text('$sizeKb KB · $_pickedMime',
                        style: GoogleFonts.manrope(fontSize: 11, color: Colors.black54)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                tooltip: 'Remove file',
                onPressed: _clearPickedFile,
              ),
            ],
          ),
          if (isImage) ...[
            const SizedBox(height: 8),
            // Handwritten toggle — only meaningful for images. When ON, the
            // parser switches to the handwritten prompt AND review pre-checks
            // are disabled so admin must confirm every line.
            Row(
              children: [
                Checkbox(
                  value: isHandwritten,
                  onChanged: (v) => setState(() {
                    _pickedInputType = (v ?? false) ? 'image_handwritten' : 'image_screenshot';
                  }),
                ),
                Text('Handwritten photo',
                    style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Tooltip(
                  message:
                      'Tick when the image is a hand-written order slip (not a spreadsheet screenshot). '
                      'Uses a stricter prompt and requires you to confirm every line on review.',
                  child: Icon(Icons.help_outline_rounded, size: 14, color: Colors.black45),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUploadButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _pickPdf,
            icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
            label: Text('Upload PDF',
                style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.image_rounded, size: 18),
            label: Text('Upload Image',
                style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ),
      ],
    );
  }

  // ── Review view ────────────────────────────────────────────────────────
  Widget _buildReview() {
    final unresolved = _reviewLines.where((l) => l.chosen == null).length;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            IconButton(
              onPressed: _resetAll,
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: 'Back (discard draft)',
            ),
            Text('Review Draft',
                style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          _buildCustomerBlock(),
          const SizedBox(height: 12),
          _buildDateBlock(),
          const SizedBox(height: 12),
          _sectionLabel('NOTES'),
          TextField(
            controller: _notesCtl,
            maxLines: 2,
            decoration: _fieldDecoration(hint: 'Admin notes'),
          ),
          const SizedBox(height: 16),
          if (_pickedInputType == 'image_handwritten')
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade400),
              ),
              child: Row(children: [
                Icon(Icons.edit_note_rounded, size: 20, color: Colors.orange.shade900),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Handwritten input — please verify and tick every line before saving. '
                    'Accuracy on handwriting is typically 50-60%.',
                    style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.orange.shade900, height: 1.3),
                  ),
                ),
              ]),
            ),
          if (unresolved > 0)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade300),
              ),
              child: Row(children: [
                Icon(Icons.priority_high_rounded, size: 18, color: Colors.amber.shade900),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$unresolved line${unresolved == 1 ? '' : 's'} need a product match before you can save.',
                    style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.amber.shade900),
                  ),
                ),
              ]),
            ),
          _sectionLabel('LINE ITEMS (${_reviewLines.length})'),
          for (int i = 0; i < _reviewLines.length; i++)
            _buildReviewLineCard(i, _reviewLines[i]),
          const SizedBox(height: 16),
          _buildTotalsPanel(),
          const SizedBox(height: 12),
          _buildLowStockSummary(),
          const SizedBox(height: 16),
          _buildSaveButton(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildCustomerBlock() {
    final resolved = _resolvedCustomer;
    final hasMatch = _chosenCustomer != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (hasMatch ? AppTheme.primary : Colors.red).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: (hasMatch ? AppTheme.primary : Colors.red).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.person_rounded, size: 18, color: hasMatch ? AppTheme.primary : Colors.red),
            const SizedBox(width: 6),
            Text('Customer  ·  ${_matchLabel(resolved?.matchedBy)}',
                style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.black54)),
          ]),
          const SizedBox(height: 4),
          Text('Detected: "${_draft?.customerNameAsWritten ?? ""}"',
              style: GoogleFonts.manrope(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          DropdownButtonFormField<CustomerModel?>(
            initialValue: _chosenCustomer,
            isExpanded: true,
            decoration: _fieldDecoration(
                hint: hasMatch ? null : 'No match — pick a candidate or change input'),
            items: [
              for (final c in (resolved?.candidates ?? <CustomerModel>[]))
                DropdownMenuItem<CustomerModel?>(
                  value: c,
                  child: Text('${c.name}  ·  ${c.phone.isEmpty ? "—" : c.phone}',
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (c) {
              setState(() => _chosenCustomer = c);
              _recomputeAllCsds();
            },
          ),
        ],
      ),
    );
  }

  String _matchLabel(String? how) {
    switch (how) {
      case 'phone_exact':
        return 'Phone match (100%)';
      case 'alias_exact':
        return 'Alias match (95%)';
      case 'fuzzy':
        final c = _resolvedCustomer?.confidence ?? 0;
        return 'Fuzzy match (${(c * 100).round()}%)';
      case 'none':
      default:
        return 'No match';
    }
  }

  Widget _buildDateBlock() {
    return Row(children: [
      Expanded(
        child: InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _deliveryDate,
              firstDate: DateTime.now().subtract(const Duration(days: 7)),
              lastDate: DateTime.now().add(const Duration(days: 60)),
            );
            if (picked != null) setState(() => _deliveryDate = picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.black26),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Icon(Icons.event_rounded, size: 18, color: Colors.black54),
              const SizedBox(width: 10),
              Text('${_deliveryDate.day}/${_deliveryDate.month}/${_deliveryDate.year}',
                  style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_draft?.deliveryDateHint != null)
                Text('hint: ${_draft!.deliveryDateHint!}',
                    style: GoogleFonts.manrope(fontSize: 10, color: Colors.black45)),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _buildReviewLineCard(int index, _ReviewLine line) {
    final conf = line.resolved.confidence;
    Color confBg;
    Color confFg;
    if (line.chosen == null) {
      confBg = Colors.red.shade100;
      confFg = Colors.red.shade900;
    } else if (conf >= 0.85) {
      confBg = Colors.green.shade100;
      confFg = Colors.green.shade900;
    } else if (conf >= 0.6) {
      confBg = Colors.amber.shade100;
      confFg = Colors.amber.shade900;
    } else {
      confBg = Colors.red.shade100;
      confFg = Colors.red.shade900;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: confBg, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  line.chosen == null ? 'NO MATCH' : '${(conf * 100).round()}%',
                  style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: confFg),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(line.draft.nameAsWritten,
                    style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black87)),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                tooltip: 'Remove line',
                onPressed: () => setState(() => _reviewLines.removeAt(index)),
              ),
            ]),
            const SizedBox(height: 4),
            DropdownButtonFormField<ProductModel?>(
              initialValue: line.chosen,
              isExpanded: true,
              decoration: _fieldDecoration(
                  hint: line.chosen == null ? 'Pick a product…' : null),
              items: [
                if (line.chosen != null &&
                    !line.resolved.candidates.map((p) => p.id).contains(line.chosen!.id))
                  DropdownMenuItem<ProductModel?>(
                    value: line.chosen,
                    child: Text('${line.chosen!.name} (picked)',
                        overflow: TextOverflow.ellipsis),
                  ),
                for (final p in line.resolved.candidates)
                  DropdownMenuItem<ProductModel?>(
                    value: p,
                    child: Text(p.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (p) {
                setState(() {
                  line.chosen = p;
                  if (p != null) line.confirmed = true;
                });
                _recomputeCsds(line);
              },
            ),
            const SizedBox(height: 6),
            // Badge row
            if (line.hasScheme || line.hasRule || line.isLowStock || line.draft.unitHint != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  if (line.isLowStock)
                    _lineBadge(
                        'LOW STOCK (${line.chosen?.stockQty ?? 0})',
                        Colors.red.shade100, Colors.red.shade900),
                  if (line.hasScheme)
                    _lineBadge('+${line.freeQty} FREE',
                        Colors.green.shade100, Colors.green.shade900),
                  if (line.hasRule)
                    _lineBadge('CSDS', Colors.blue.shade100, Colors.blue.shade900),
                  if (line.draft.unitHint != null && line.draft.unitHint!.isNotEmpty)
                    _lineBadge('hint: ${line.draft.unitHint}',
                        Colors.grey.shade200, Colors.black87),
                ]),
              ),
            Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: line.qty.toString(),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _fieldDecoration(label: 'Qty'),
                  onChanged: (v) {
                    setState(() => line.qty = int.tryParse(v) ?? 0);
                    _recomputeCsds(line);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    line.chosen == null ? '—' : '₹${(line.subtotal + line.gst).toStringAsFixed(2)}',
                    textAlign: TextAlign.right,
                    style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Column(children: [
                Checkbox(
                  value: line.confirmed,
                  onChanged: line.chosen == null
                      ? null
                      : (v) => setState(() => line.confirmed = v ?? false),
                ),
                Text('Confirm',
                    style: GoogleFonts.manrope(fontSize: 9, color: Colors.black54)),
              ]),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildTotalsPanel() {
    final subtotal = _reviewLines.fold<double>(0, (a, l) => a + l.subtotal);
    final gst = _reviewLines.fold<double>(0, (a, l) => a + l.gst);
    final grand = subtotal + gst;
    final units = _reviewLines.fold<int>(0, (a, l) => a + l.qty);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
      ),
      child: Column(children: [
        _totalsRow('Subtotal', subtotal),
        _totalsRow('GST', gst),
        const Divider(),
        _totalsRow('Grand Total', grand, bold: true),
        _totalsRow('Units', units.toDouble(), isCount: true),
      ]),
    );
  }

  Widget _totalsRow(String label, double value, {bool bold = false, bool isCount = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: GoogleFonts.manrope(
                fontSize: bold ? 14 : 12,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                color: Colors.black.withValues(alpha: bold ? 1.0 : 0.7),
              )),
          Text(isCount ? value.toInt().toString() : '₹${value.toStringAsFixed(2)}',
              style: GoogleFonts.manrope(
                fontSize: bold ? 14 : 12,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
              )),
        ],
      ),
    );
  }

  Widget _buildLowStockSummary() {
    final lowLines = _reviewLines.where((l) => l.isLowStock).toList();
    if (lowLines.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade300),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: Colors.red.shade800),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${lowLines.length} line${lowLines.length == 1 ? '' : 's'} exceed available stock. '
              'Admin may still proceed — office decides fulfilment.',
              style: GoogleFonts.manrope(fontSize: 11, color: Colors.red.shade900, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return FilledButton.icon(
      onPressed: _canSave ? _save : null,
      icon: _submitting
          ? const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.save_rounded),
      label: Text(_submitting ? 'Saving…' : 'Save Order',
          style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800)),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        backgroundColor: AppTheme.primary,
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────
  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: GoogleFonts.manrope(
              fontSize: 12, fontWeight: FontWeight.w700,
              color: Colors.black54, letterSpacing: 0.4,
            )),
      );

  Widget _lineBadge(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: fg)),
      );

  InputDecoration _fieldDecoration({String? hint, String? label, IconData? prefixIcon}) {
    return InputDecoration(
      hintText: hint,
      labelText: label,
      prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 18) : null,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Review-side cart line. Carries the Gemini draft, the resolver output,
// and the admin's editable state (chosen product, qty, confirm checkbox).
// Mirrors the Manual _CartLine for CSDS + stock + JSON generation so both
// paths land identical payloads server-side.
// ─────────────────────────────────────────────────────────────────────────
class _ReviewLine {
  final SmartImportDraftLine draft;
  final ResolvedProduct resolved;
  ProductModel? chosen;
  int qty;
  bool confirmed;
  CsdsPriceBreakdown? breakdown;

  _ReviewLine({
    required this.draft,
    required this.resolved,
    required this.chosen,
    required this.qty,
    required this.confirmed,
  });

  double get unitPrice {
    if (chosen == null) return 0;
    if (breakdown != null) return breakdown!.netRate;
    return chosen!.unitPrice;
  }

  double get subtotal => unitPrice * qty;
  double get gst {
    if (chosen == null) return 0;
    if (breakdown != null) return breakdown!.tax;
    return subtotal * chosen!.gstRate;
  }

  int get freeQty => breakdown?.freeQty ?? 0;
  bool get hasScheme => freeQty > 0;
  bool get hasRule => breakdown?.rule != null;
  bool get isLowStock => chosen != null && qty > chosen!.stockQty;

  Map<String, dynamic> toJson(String orderId) {
    final p = chosen!;
    final m = <String, dynamic>{
      'order_id': orderId,
      'product_id': p.id,
      'product_name': p.name,
      'sku': p.sku,
      'quantity': qty,
      'unit_price': unitPrice,
      'mrp': p.mrp,
      'line_total': subtotal,
      'gst_rate': p.gstRate,
    };
    if (breakdown?.rule != null) {
      final r = breakdown!.rule!;
      m['csds_disc_per'] = r.discPer;
      m['csds_disc_per_3'] = r.discPer3;
      m['csds_disc_per_5'] = r.discPer5;
    }
    if (freeQty > 0) m['free_qty'] = freeQty;
    return m;
  }
}
