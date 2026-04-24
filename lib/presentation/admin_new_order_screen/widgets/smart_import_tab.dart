import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/pricing.dart';
import '../../../core/search_utils.dart';
import '../../../services/auth_service.dart';
import '../../../services/bill_extraction_service.dart';
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
  /// Gates the "Revoke & re-import" action in the duplicate dialog. Admins
  /// see a read-only dup dialog; super_admins get the override.
  final bool isSuperAdmin;

  const SmartImportTab({super.key, this.isSuperAdmin = false});

  @override
  State<SmartImportTab> createState() => _SmartImportTabState();
}

enum _Stage { compose, reviewing }

// ─────────────────────────────────────────────────────────────────────────
// Attachment + queue types for the multi-attachment / multi-order flow.
//
// Compose stage piles up [_Attachment]s (1..N pastes/images/PDFs).
// Parse fans out one Gemini call per attachment; each call returns
// 1..M orders which are materialized as a flat [_QueuedDraft] list.
// Review stage walks the queue one draft at a time — the existing
// single-draft UI renders `_queue[_queueIdx]` so we don't fragment the
// line-editing experience into a card-stack.
// ─────────────────────────────────────────────────────────────────────────

enum _AttachmentKind { paste, image, pdf }
enum _AttachmentStatus { pending, parsing, ok, duplicate, error }
enum _ParseOutcome { ok, duplicate, error }

class _Attachment {
  final String id;
  final _AttachmentKind kind;
  final Uint8List? bytes;
  final String? text;
  final String? fileName;
  final String mime;
  String inputType; // may flip between image_screenshot / image_handwritten
  final String hash;
  _AttachmentStatus status;
  String? parseError;
  Map<String, dynamic>? dupInfo;
  /// Indices into the flat [_queue] this attachment contributed.
  /// Filled after a successful parse; used when writing the audit row so
  /// every order from this file/paste is linked back to one input_hash.
  List<int> queueIndices = const [];

  _Attachment({
    required this.id,
    required this.kind,
    required this.bytes,
    required this.text,
    required this.fileName,
    required this.mime,
    required this.inputType,
    required this.hash,
  }) : status = _AttachmentStatus.pending;

  String get displayLabel {
    switch (kind) {
      case _AttachmentKind.paste:
        final t = (text ?? '').trim();
        return t.length > 40 ? '${t.substring(0, 40)}…' : (t.isEmpty ? 'Paste' : t);
      case _AttachmentKind.image:
      case _AttachmentKind.pdf:
        return fileName ?? (kind == _AttachmentKind.pdf ? 'PDF' : 'Image');
    }
  }

  int get byteSize {
    if (bytes != null) return bytes!.length;
    return (text ?? '').length;
  }
}

enum _QueueStatus { reviewing, saved, skipped, failed }

class _QueuedDraft {
  final String id;
  /// Index into [_attachments] — lets save/skip route history writes to
  /// the owning attachment.
  final int attachmentIndex;
  SmartImportDraft draft;
  ResolvedCustomer? resolvedCust;
  CustomerModel? chosenCust;
  final List<_ReviewLine> reviewLines;
  DateTime deliveryDate;
  String notes;
  _QueueStatus status;
  String? savedOrderId;
  String? saveError;

  _QueuedDraft({
    required this.id,
    required this.attachmentIndex,
    required this.draft,
    required this.resolvedCust,
    required this.chosenCust,
    required this.reviewLines,
    required this.deliveryDate,
    required this.notes,
  }) : status = _QueueStatus.reviewing;
}

class _SmartImportTabState extends State<SmartImportTab> {
  // ── Stage + entry UI state ──────────────────────────────────────────────
  _Stage _stage = _Stage.compose;
  String _team = 'JA';
  List<AppUserModel> _reps = [];
  AppUserModel? _selectedRep;

  /// Attachments piled up during compose. Each is one paste / image / PDF
  /// that will be parsed independently. Gemini may return 1..N orders per
  /// attachment; the flat [_queue] list interleaves all resulting drafts.
  final List<_Attachment> _attachments = [];
  int _attachmentIdCounter = 0;

  /// Parsed-draft queue. Each entry = one order to review + save. When a
  /// single attachment yields multiple orders they land as adjacent entries
  /// here. Review UI walks `_queue[_queueIdx]` one at a time.
  final List<_QueuedDraft> _queue = [];
  int _queueIdx = 0;
  int _draftIdCounter = 0;

  /// Progress during the bulk parse ("Parsing 3 of 5…"). Null when idle.
  String? _parseProgress;

  bool _loading = true;
  bool _parsing = false;
  /// Per-attachment busy flag for the "Treat as bill" single-bill check.
  /// Keyed by [_Attachment.id] so removing other attachments mid-flight
  /// doesn't shift the busy state onto the wrong card.
  final Set<String> _billChecking = {};

  // ── Current-draft review state ──────────────────────────────────────────
  // These are a VIEW onto `_queue[_queueIdx]` that the existing review UI
  // reads from. On save/skip they are flushed back into the queue entry
  // and the next entry is hydrated.
  SmartImportDraft? _draft;
  ResolvedCustomer? _resolvedCustomer;
  CustomerModel? _chosenCustomer;
  final List<_ReviewLine> _reviewLines = [];
  DateTime _deliveryDate = DateTime.now().add(const Duration(days: 1));
  final TextEditingController _notesCtl = TextEditingController();
  bool _submitting = false;

  /// Paste composer controller (bottom-sheet "Add Paste" modal). Lives on
  /// the State so the modal text survives rebuilds while open.
  final TextEditingController _pasteCtl = TextEditingController();
  /// Admin-picked text-input classification (null = auto) — used only
  /// inside the paste composer modal.
  String? _textInputType;

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

  /// Drains the shared payload from the system share sheet as a new
  /// attachment. Called from an initial post-frame callback AND whenever a
  /// new share arrives via the notifier.
  void _onSharePayload() {
    final payload = SmartImportShareService.pendingShare.value;
    if (payload == null || !payload.hasPayload) return;
    // Only auto-apply while compose stage is visible. If the admin is deep
    // in a review, don't stomp their draft — the notifier keeps the payload
    // so they can go back and apply after.
    if (_stage != _Stage.compose) return;

    final added = <String>[];
    if (payload.text != null && payload.text!.trim().isNotEmpty) {
      final att = _pasteAttachment(
        text: payload.text!,
        inputType: SmartImportService.classifyTextInput(payload.text!),
      );
      setState(() => _attachments.add(att));
      added.add('paste from share');
    } else if (payload.fileBytes != null) {
      final isPdf = payload.fileMime == 'application/pdf';
      final att = _fileAttachment(
        bytes: payload.fileBytes!,
        fileName: payload.fileName ?? (isPdf ? 'shared.pdf' : 'shared.jpg'),
        mime: payload.fileMime ?? (isPdf ? 'application/pdf' : 'image/jpeg'),
        kind: isPdf ? _AttachmentKind.pdf : _AttachmentKind.image,
        inputType: isPdf ? 'pdf' : 'image_screenshot',
      );
      setState(() => _attachments.add(att));
      added.add('file "${att.fileName}"');
    }
    SmartImportShareService.consume();

    if (mounted && added.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added ${added.join(", ")} — pile on more if you want, then Parse.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  // ── Attachment factories ────────────────────────────────────────────────
  _Attachment _pasteAttachment({
    required String text,
    required String inputType,
  }) {
    return _Attachment(
      id: 'a${++_attachmentIdCounter}',
      kind: _AttachmentKind.paste,
      bytes: null,
      text: text,
      fileName: null,
      mime: 'text/plain',
      inputType: inputType,
      hash: SmartImportService.computeInputHash(text),
    );
  }

  _Attachment _fileAttachment({
    required Uint8List bytes,
    required String fileName,
    required String mime,
    required _AttachmentKind kind,
    required String inputType,
  }) {
    return _Attachment(
      id: 'a${++_attachmentIdCounter}',
      kind: kind,
      bytes: bytes,
      text: null,
      fileName: fileName,
      mime: mime,
      inputType: inputType,
      hash: SmartImportService.computeFileHash(bytes),
    );
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
  /// Multi-select PDFs. Each picked file becomes its own attachment.
  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
      allowMultiple: true,
    );
    await _acceptPickedMulti(result, defaultInputType: 'pdf');
  }

  /// Multi-select images. Each picked file becomes its own attachment.
  /// Default input type is screenshot; admin can per-attachment flip to
  /// handwritten in the compose list.
  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png'],
      withData: true,
      allowMultiple: true,
    );
    await _acceptPickedMulti(result, defaultInputType: 'image_screenshot');
  }

  Future<void> _acceptPickedMulti(
      FilePickerResult? result, {required String defaultInputType}) async {
    if (result == null || result.files.isEmpty) return;
    final added = <_Attachment>[];
    final skipped = <String>[];
    for (final file in result.files) {
      if (file.bytes == null && file.path == null) {
        skipped.add(file.name);
        continue;
      }
      try {
        final Uint8List bytes = file.bytes ?? await File(file.path!).readAsBytes();
        final ext = (file.extension ?? '').toLowerCase();
        final isPdf = ext == 'pdf';
        final mime = switch (ext) {
          'pdf' => 'application/pdf',
          'png' => 'image/png',
          _ => 'image/jpeg',
        };
        final inputType = isPdf ? 'pdf' : defaultInputType;
        final kind = isPdf ? _AttachmentKind.pdf : _AttachmentKind.image;
        added.add(_fileAttachment(
          bytes: bytes,
          fileName: file.name,
          mime: mime,
          kind: kind,
          inputType: inputType,
        ));
      } catch (e) {
        skipped.add('${file.name} ($e)');
      }
    }
    if (added.isNotEmpty) {
      setState(() => _attachments.addAll(added));
    }
    if (!mounted) return;
    if (skipped.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not read: ${skipped.join(", ")}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _removeAttachment(int index) {
    if (index < 0 || index >= _attachments.length) return;
    setState(() => _attachments.removeAt(index));
  }

  /// Opens a bottom-sheet composer; on confirm, adds the typed text as a
  /// new paste attachment. Keeps text + file attachments symmetric.
  Future<void> _addPaste() async {
    _pasteCtl.clear();
    _textInputType = null;
    final result = await showModalBottomSheet<_Attachment>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PasteComposerSheet(
        controller: _pasteCtl,
        initialInputType: _textInputType,
        build: (text, inputType) => _pasteAttachment(
          text: text,
          inputType: inputType,
        ),
      ),
    );
    if (result != null) {
      setState(() => _attachments.add(result));
    }
  }

  /// Run the bill-extraction pipeline on a single PDF/image attachment.
  /// This bypasses the order-import flow — Gemini parses it as one or more
  /// invoices (BillExtractionService), saves to bill_extractions, and runs
  /// the same auto-match step the Bill Verification tab uses. On success
  /// the attachment is removed so it isn't double-processed by Parse.
  Future<void> _treatAsBill(int index) async {
    if (index < 0 || index >= _attachments.length) return;
    final a = _attachments[index];
    if (a.kind != _AttachmentKind.pdf && a.kind != _AttachmentKind.image) return;
    if (a.bytes == null || a.bytes!.isEmpty) return;
    if (_billChecking.contains(a.id)) return;

    setState(() => _billChecking.add(a.id));
    final originalTeam = AuthService.currentTeam;
    AuthService.currentTeam = _team;
    try {
      final bills = await BillExtractionService.instance.extractBillsFromImage(
        a.bytes!,
        mimeType: a.mime,
      );
      final saved = bills.isEmpty
          ? 0
          : await BillExtractionService.instance.saveExtractedBills(bills);
      if (!mounted) return;
      if (bills.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No bills found in this attachment.'),
            backgroundColor: Colors.orange,
          ),
        );
      } else {
        final dups = bills.length - saved;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Extracted ${bills.length} bill${bills.length == 1 ? "" : "s"}, '
              'saved $saved${dups > 0 ? " ($dups already on file)" : ""}. '
              'Verify in Admin → Bill Verification.',
            ),
            backgroundColor: Colors.green,
          ),
        );
        setState(() => _attachments.removeWhere((x) => x.id == a.id));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Bill check failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      AuthService.currentTeam = originalTeam;
      if (mounted) setState(() => _billChecking.remove(a.id));
    }
  }

  /// Toggle handwritten↔screenshot for an image attachment. The active
  /// input type picks the Gemini prompt and controls review's auto-confirm.
  void _toggleHandwritten(int index) {
    if (index < 0 || index >= _attachments.length) return;
    final a = _attachments[index];
    if (a.kind != _AttachmentKind.image) return;
    setState(() {
      a.inputType = a.inputType == 'image_handwritten'
          ? 'image_screenshot'
          : 'image_handwritten';
    });
  }

  // ── Parse pipeline ──────────────────────────────────────────────────────
  /// Bulk-parse every compose-stage attachment. Each attachment is
  /// dedup-checked (by hash) and then sent to Gemini. A single attachment
  /// may produce 1..N orders (multi-order prompt); all resulting orders
  /// are flattened into [_queue] and reviewed one at a time.
  Future<void> _parse() async {
    if (_selectedRep == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a rep for this import first')),
      );
      return;
    }
    if (_attachments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one paste, image, or PDF first')),
      );
      return;
    }

    setState(() {
      _parsing = true;
      _parseProgress = 'Preparing…';
      _queue.clear();
      _queueIdx = 0;
    });

    int liveDups = 0;
    int parseErrs = 0;
    String? firstErrReason;
    String? firstErrDetail;

    try {
      for (int i = 0; i < _attachments.length; i++) {
        if (!mounted) return;
        setState(() {
          _parseProgress = 'Parsing ${i + 1} of ${_attachments.length}…';
        });
        final outcome = await _parseOne(i);
        if (outcome == _ParseOutcome.duplicate) liveDups++;
        if (outcome == _ParseOutcome.error) {
          parseErrs++;
          final a = _attachments[i];
          firstErrReason ??= a.parseError;
          // _parseOne doesn't capture Gemini's free-form detail today — the
          // reason code is enough for the error dialog.
        }
      }

      if (!mounted) return;

      if (_queue.isEmpty) {
        setState(() {
          _parsing = false;
          _parseProgress = null;
        });
        if (liveDups > 0 && parseErrs == 0) {
          // All attachments were duplicates. Show the first dup dialog,
          // passing the attachment index so super_admin can revoke + retry.
          final firstDupIdx = _attachments
              .indexWhere((a) => a.status == _AttachmentStatus.duplicate);
          final firstDup = firstDupIdx >= 0
              ? _attachments[firstDupIdx].dupInfo
              : null;
          if (firstDup != null) {
            _showDupDialog(firstDup, attachmentIndex: firstDupIdx);
          }
        } else if (firstErrReason != null) {
          _showParseError(firstErrReason, firstErrDetail);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Gemini returned no orders for any attachment.')),
          );
        }
        return;
      }

      setState(() {
        _stage = _Stage.reviewing;
        _queueIdx = 0;
        _parsing = false;
        _parseProgress = null;
      });
      _hydrateCurrent();

      // Surface per-attachment issues via a single snackbar so admin knows
      // some files were duplicates or failed but they can still review the
      // successful ones.
      if (mounted && (liveDups > 0 || parseErrs > 0)) {
        final parts = <String>[];
        if (liveDups > 0) parts.add('$liveDups duplicate');
        if (parseErrs > 0) parts.add('$parseErrs failed');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${parts.join(" · ")} out of ${_attachments.length} '
              'attachment${_attachments.length == 1 ? "" : "s"} '
              '— ${_queue.length} order${_queue.length == 1 ? "" : "s"} '
              'ready to review.',
            ),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 5),
          ),
        );
      }

      _recomputeAllCsds();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _parsing = false;
        _parseProgress = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Parse error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  /// Parse a single attachment end-to-end: dedup-check, Gemini call,
  /// customer/product resolution. Mutates the attachment's status + any
  /// queued drafts inline. Returns an outcome so [_parse] can tally.
  Future<_ParseOutcome> _parseOne(int index) async {
    if (index < 0 || index >= _attachments.length) {
      return _ParseOutcome.error;
    }
    final a = _attachments[index];
    setState(() => a.status = _AttachmentStatus.parsing);
    final svc = SmartImportService.instance;

    // Dedup — per attachment hash, per team.
    final dup = await svc.findImportByHash(a.hash, _team);
    if (dup != null) {
      a.status = _AttachmentStatus.duplicate;
      a.dupInfo = dup;
      return _ParseOutcome.duplicate;
    }

    // Route to the right Gemini parser.
    ({SmartImportBatch? batch, String reason, String? detail}) result;
    if (a.kind == _AttachmentKind.paste) {
      result = await svc.parseBatchTextDetailed(a.text ?? '', a.inputType);
    } else {
      result = await svc.parseBatchFromBytesDetailed(
        bytes: a.bytes!,
        mimeType: a.mime,
        inputType: a.inputType,
      );
    }

    if (result.batch == null || result.batch!.orders.isEmpty) {
      a.status = _AttachmentStatus.error;
      a.parseError = result.reason;
      return _ParseOutcome.error;
    }

    final isHandwritten = a.inputType == 'image_handwritten';
    final indices = <int>[];
    for (final draft in result.batch!.orders) {
      final resolvedCust = await svc.resolveCustomer(
        extractedName: draft.customerNameAsWritten,
        extractedPhone: draft.customerPhoneFromInput,
        teamId: _team,
      );
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
          confirmed: !isHandwritten && rp.match != null && rp.confidence >= 0.85,
        ));
      }
      _queue.add(_QueuedDraft(
        id: 'd${++_draftIdCounter}',
        attachmentIndex: index,
        draft: draft,
        resolvedCust: resolvedCust,
        chosenCust: resolvedCust.match,
        reviewLines: lines,
        deliveryDate: DateTime.now().add(const Duration(days: 1)),
        notes: draft.notes ?? '',
      ));
      indices.add(_queue.length - 1);
    }
    a.status = _AttachmentStatus.ok;
    a.queueIndices = indices;
    return _ParseOutcome.ok;
  }

  // ── Queue navigation ────────────────────────────────────────────────────
  /// Copy `_queue[_queueIdx]` into the scalar review fields that the
  /// existing review UI reads from. Called on transition to review and
  /// whenever the admin advances to the next draft.
  void _hydrateCurrent() {
    if (_queueIdx < 0 || _queueIdx >= _queue.length) return;
    final q = _queue[_queueIdx];
    _draft = q.draft;
    _resolvedCustomer = q.resolvedCust;
    _chosenCustomer = q.chosenCust;
    _reviewLines
      ..clear()
      ..addAll(q.reviewLines);
    _deliveryDate = q.deliveryDate;
    _notesCtl.text = q.notes;
  }

  /// Flush scalar review-state edits back into the current queue entry.
  /// Called before save / skip / navigation so per-draft edits persist.
  void _flushCurrentToQueue() {
    if (_queueIdx < 0 || _queueIdx >= _queue.length) return;
    final q = _queue[_queueIdx];
    q.chosenCust = _chosenCustomer;
    q.deliveryDate = _deliveryDate;
    q.notes = _notesCtl.text;
    // reviewLines list is shared by reference; edits already mutate it.
  }

  /// Pick the next not-yet-terminal draft. Returns -1 when none remain.
  int _nextReviewIndex() {
    for (int i = _queueIdx + 1; i < _queue.length; i++) {
      if (_queue[i].status == _QueueStatus.reviewing) return i;
    }
    for (int i = 0; i < _queueIdx; i++) {
      if (_queue[i].status == _QueueStatus.reviewing) return i;
    }
    return -1;
  }

  /// Advance to the next reviewing draft OR reset to compose when done.
  /// Writes per-attachment audit rows as their last draft finalizes.
  Future<void> _advanceOrFinish() async {
    await _maybeFinalizeAttachmentAudit(_queue[_queueIdx].attachmentIndex);
    final nxt = _nextReviewIndex();
    if (nxt == -1) {
      if (!mounted) return;
      _showBatchSummary();
      _resetAll();
      return;
    }
    if (!mounted) return;
    setState(() => _queueIdx = nxt);
    _hydrateCurrent();
    _recomputeAllCsds();
  }

  /// When every draft linked to [attIndex] has left the reviewing state,
  /// write one smart_import_history row with all saved order IDs.
  Future<void> _maybeFinalizeAttachmentAudit(int attIndex) async {
    if (attIndex < 0 || attIndex >= _attachments.length) return;
    final a = _attachments[attIndex];
    if (a.status != _AttachmentStatus.ok) return;
    final pending = a.queueIndices
        .any((qi) => _queue[qi].status == _QueueStatus.reviewing);
    if (pending) return;

    final savedIds = a.queueIndices
        .map((qi) => _queue[qi].savedOrderId)
        .whereType<String>()
        .toList();
    final parsed = <String, dynamic>{
      'orders': [
        for (final qi in a.queueIndices)
          {
            'customer': {
              'name_as_written': _queue[qi].draft.customerNameAsWritten,
              'phone_if_present': _queue[qi].draft.customerPhoneFromInput,
            },
            'lines': _queue[qi].draft.lines
                .map((l) => {
                      'name_as_written': l.nameAsWritten,
                      'quantity': l.quantity,
                      'unit_hint': l.unitHint,
                      'confidence': l.confidence,
                    })
                .toList(),
            'overall_parse_confidence': _queue[qi].draft.overallConfidence,
          }
      ],
    };
    final corrections = <String, dynamic>{
      'orders_saved': savedIds.length,
      'orders_skipped': a.queueIndices
          .where((qi) => _queue[qi].status == _QueueStatus.skipped)
          .length,
      'orders_failed': a.queueIndices
          .where((qi) => _queue[qi].status == _QueueStatus.failed)
          .length,
    };
    final svc = SmartImportService.instance;
    final adminAuthId = svc.currentAdminUserId ?? '';
    final preview = a.kind == _AttachmentKind.paste
        ? (a.text ?? '')
        : 'file: ${a.fileName ?? "—"} (${a.byteSize} bytes, ${a.mime})';
    await svc.writeImportHistory(
      inputType: a.inputType,
      inputPreview: preview,
      inputHash: a.hash,
      parsedResult: parsed,
      adminCorrections: corrections,
      resultingOrderIds: savedIds,
      teamId: _team,
      attributedRepUserId: _selectedRep!.id,
      importedByUserId: adminAuthId,
      status: savedIds.isEmpty ? 'discarded' : 'saved',
    );
  }

  void _showBatchSummary() {
    final saved = _queue.where((q) => q.status == _QueueStatus.saved).toList();
    final skipped = _queue.where((q) => q.status == _QueueStatus.skipped).length;
    final failed = _queue.where((q) => q.status == _QueueStatus.failed).length;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Batch complete'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${saved.length} saved · $skipped skipped · $failed failed',
                  style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
              if (saved.isNotEmpty) const SizedBox(height: 10),
              for (final q in saved)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• ${q.savedOrderId}  — ${q.chosenCust?.name ?? "(customer unknown)"}',
                    style: GoogleFonts.manrope(fontSize: 12, color: Colors.black87),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Blocks the UI with a clear message per failure mode so admin doesn't
  /// just sit staring at a spinner after a timeout. Previously a SnackBar
  /// auto-dismissed on mobile before admin noticed.
  void _showParseError(String reason, String? detail) {
    String title;
    String body;
    switch (reason) {
      case 'no_key':
        title = 'Gemini API key missing';
        body = 'GEMINI_API_KEY is not set in env.json. Add it and rebuild '
            'the app. Contact the developer if you do not have one.';
        break;
      case 'timeout':
        title = 'Gemini timed out (${detail ?? "—"})';
        body = 'The model took longer than the allowed window. Common '
            'causes:\n'
            '  • Network is slow or offline — retry on stronger signal.\n'
            '  • Paste is very long — try splitting into two smaller '
            'imports.\n'
            '  • Gemini service itself is throttled — wait a minute and '
            'retry.';
        break;
      case 'network':
        title = 'Network error';
        body = 'Could not reach Gemini. Check your internet connection.\n\n'
            '${detail ?? ""}';
        break;
      case 'empty':
        title = 'Gemini returned nothing';
        body = 'The model responded but produced no text. Usually means '
            'the input had no recognisable order lines. Check the paste '
            'or image and try again.';
        break;
      case 'bad_json':
        title = 'Could not read model output';
        body = 'Gemini returned content that was not valid JSON. This is '
            'rare — try again, and if it keeps happening, simplify the '
            'input (one order at a time).\n\n'
            'Raw output (truncated):\n${detail ?? "—"}';
        break;
      case 'internal':
        title = 'Unexpected parse error';
        body = 'Something went wrong in the client. Share this with the '
            'developer:\n\n${detail ?? "—"}';
        break;
      default:
        // http_NNN
        if (reason.startsWith('http_')) {
          final code = reason.substring(5);
          final codeNum = int.tryParse(code) ?? 0;
          title = 'Gemini API error ($code)';
          final String cause;
          if (codeNum == 400) {
            cause = 'Input rejected — check paste length or image mime type.';
          } else if (codeNum == 401 || codeNum == 403) {
            cause = 'API key invalid or out of quota. Contact the developer.';
          } else if (codeNum == 429) {
            cause = 'Rate-limited. Wait a minute and retry.';
          } else if (codeNum >= 500 && codeNum < 600) {
            cause = 'Gemini service is temporarily down. Try again shortly.';
          } else {
            cause = 'Unexpected status from Gemini. Try again shortly.';
          }
          body = '$cause\n\nResponse (truncated):\n${detail ?? "—"}';
        } else {
          title = 'Parse failed';
          body = 'Reason: $reason\n\n${detail ?? ""}';
        }
    }
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Text(body, style: const TextStyle(fontSize: 13, height: 1.35)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  /// [attachmentIndex] is optional — when provided, super_admin gets a
  /// "Revoke & re-import" button that clears the duplicate state for
  /// that specific attachment and re-parses it. When null (e.g. opened
  /// from a read-only inspector in the future), only the OK action is shown.
  void _showDupDialog(Map<String, dynamic> dup, {int? attachmentIndex}) {
    final rawIds = dup['resulting_order_ids'];
    final ids = <String>[
      if (rawIds is List) ...rawIds.map((e) => e.toString()),
    ];
    final when = dup['imported_at']?.toString();
    final rowId = dup['id']?.toString();
    final canRevoke = widget.isSuperAdmin &&
        rowId != null &&
        rowId.isNotEmpty &&
        attachmentIndex != null;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Duplicate import'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                when != null
                    ? 'This exact input was already imported at $when.'
                    : 'This exact input was already imported.',
                style: GoogleFonts.manrope(fontSize: 13, height: 1.35),
              ),
              if (ids.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Linked order${ids.length == 1 ? "" : "s"}:',
                  style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                for (final id in ids)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('• $id',
                        style: GoogleFonts.manrope(fontSize: 12, color: Colors.black87)),
                  ),
              ],
              if (canRevoke) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.purple.shade200),
                  ),
                  child: Text(
                    'Super_admin: "Revoke & re-import" unlocks this hash so '
                    'the input can be parsed again. The linked order'
                    '${ids.length == 1 ? "" : "s"} above stay${ids.length == 1 ? "s" : ""} — '
                    'delete them separately via the Orders tab if the original was wrong.',
                    style: GoogleFonts.manrope(
                        fontSize: 11, color: Colors.purple.shade900, height: 1.35),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          if (canRevoke)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _revokeAndRetry(attachmentIndex, rowId);
              },
              child: const Text('Revoke & re-import'),
            ),
        ],
      ),
    );
  }

  /// Super_admin action: soft-delete the audit row that's blocking this
  /// attachment's hash, then retry parsing just this one attachment.
  /// Results get appended to any existing queue; transitions to review
  /// if this produced the first queued drafts.
  Future<void> _revokeAndRetry(int attachmentIndex, String historyRowId) async {
    if (attachmentIndex < 0 || attachmentIndex >= _attachments.length) return;
    final svc = SmartImportService.instance;
    final uid = svc.currentAdminUserId ?? '';
    if (uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not resolve your user id — re-login and retry.')),
      );
      return;
    }
    setState(() {
      _parsing = true;
      _parseProgress = 'Revoking audit row…';
    });
    final ok = await svc.revokeImportHistoryRow(
      rowId: historyRowId,
      revokedByUserId: uid,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _parsing = false;
        _parseProgress = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Revoke failed. Check your permissions or connection.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    // Reset attachment to pending so _parseOne treats it as fresh.
    final a = _attachments[attachmentIndex];
    setState(() {
      a.status = _AttachmentStatus.pending;
      a.dupInfo = null;
      a.parseError = null;
      a.queueIndices = const [];
      _parseProgress = 'Re-parsing after revoke…';
    });
    await _parseOne(attachmentIndex);
    if (!mounted) return;
    setState(() {
      _parsing = false;
      _parseProgress = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          a.status == _AttachmentStatus.ok
              ? 'Revoked + re-parsed. ${a.queueIndices.length} order${a.queueIndices.length == 1 ? "" : "s"} queued.'
              : 'Revoked, but re-parse did not produce orders (${a.parseError ?? a.status.name}).',
        ),
        backgroundColor: a.status == _AttachmentStatus.ok
            ? Colors.green.shade700
            : Colors.orange.shade800,
        duration: const Duration(seconds: 4),
      ),
    );
    if (a.status == _AttachmentStatus.ok && _queue.isNotEmpty && _stage == _Stage.compose) {
      setState(() {
        _stage = _Stage.reviewing;
        _queueIdx = _queue
            .indexWhere((q) => q.status == _QueueStatus.reviewing);
        if (_queueIdx < 0) _queueIdx = 0;
      });
      _hydrateCurrent();
      _recomputeAllCsds();
    }
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
  /// Save the CURRENT queue draft. On success, marks the queue entry
  /// saved and advances to the next reviewing draft. When the last draft
  /// finalizes, writes the per-attachment audit row and resets to compose.
  Future<void> _save() async {
    if (!_canSave) return;
    _flushCurrentToQueue();
    setState(() => _submitting = true);
    final originalTeam = AuthService.currentTeam;
    AuthService.currentTeam = _team;

    final q = _queue[_queueIdx];
    final orderId = _generateOrderId();
    final itemsJson = _reviewLines
        .where((l) => l.chosen != null && l.qty > 0 && l.confirmed)
        .map((l) => l.toJson(orderId))
        .toList();

    final subtotal = _reviewLines.fold<double>(0, (a, l) => a + l.subtotal);
    final gst = _reviewLines.fold<double>(0, (a, l) => a + l.gst);
    final grand = subtotal + gst;
    final units = _reviewLines.fold<int>(0, (a, l) => a + l.qty);

    final resolvedBeatName = _chosenCustomer!.resolvedOrderBeatNameForTeam(_team);

    bool savedOffline = false;
    try {
      await SupabaseService.instance.createOrder(
        orderId: orderId,
        customerId: _chosenCustomer!.id,
        customerName: _chosenCustomer!.name,
        beat: resolvedBeatName,
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
    } catch (_) {
      try {
        await OfflineService.instance.queueOperation('order', {
          'order_id': orderId,
          'customer_id': _chosenCustomer!.id,
          'customer_name': _chosenCustomer!.name,
          'beat': resolvedBeatName,
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
        savedOffline = true;
      } catch (e2) {
        // Total save failure — mark the queue entry failed so batch
        // summary can surface it. Do NOT advance; admin may retry.
        q.status = _QueueStatus.failed;
        q.saveError = e2.toString();
        AuthService.currentTeam = originalTeam;
        if (!mounted) return;
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e2'), backgroundColor: Colors.red),
        );
        return;
      }
    }

    // Alias writes — best-effort, per saved order.
    final svc = SmartImportService.instance;
    final adminAuthId = svc.currentAdminUserId ?? '';
    int aliasFailures = 0;
    try {
      if (_draft != null &&
          _chosenCustomer != null &&
          _draft!.customerNameAsWritten.isNotEmpty &&
          _draft!.customerNameAsWritten.toLowerCase() !=
              _chosenCustomer!.name.toLowerCase()) {
        final ok = await svc.writeCustomerAlias(
          aliasText: _draft!.customerNameAsWritten,
          customerId: _chosenCustomer!.id,
          teamId: _team,
          createdByUserId: adminAuthId,
        );
        if (!ok) aliasFailures++;
      }
      for (final l in _reviewLines) {
        if (l.chosen != null && l.draft.nameAsWritten.isNotEmpty) {
          final ok = await svc.writeProductAlias(
            customerId: _chosenCustomer?.id,
            aliasText: l.draft.nameAsWritten,
            productId: l.chosen!.id,
            teamId: _team,
            createdByUserId: adminAuthId,
          );
          if (!ok) aliasFailures++;
        }
      }
    } catch (e) {
      debugPrint('[SmartImport] alias writes failed: $e');
      aliasFailures++;
    }
    if (aliasFailures > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Order saved. $aliasFailures alias write${aliasFailures == 1 ? '' : 's'} '
            "failed — future imports won't benefit from this learning.",
          ),
          backgroundColor: Colors.orange.shade800,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    q.status = _QueueStatus.saved;
    q.savedOrderId = orderId;

    AuthService.currentTeam = originalTeam;
    if (!mounted) return;
    setState(() => _submitting = false);

    final offlineNote = savedOffline ? ' (queued offline)' : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Order $orderId saved$offlineNote. '
            '${_queue.where((x) => x.status == _QueueStatus.reviewing).length} left to review.'),
        backgroundColor: savedOffline ? Colors.orange.shade800 : Colors.green.shade700,
        duration: const Duration(seconds: 3),
      ),
    );

    await _advanceOrFinish();
  }

  /// Discard the current draft without saving and advance. Records the
  /// skip in the attachment audit on finalization.
  Future<void> _skipCurrent() async {
    if (_queueIdx < 0 || _queueIdx >= _queue.length) return;
    final q = _queue[_queueIdx];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Skip this order?'),
        content: Text(
          'The order for "${q.chosenCust?.name ?? q.draft.customerNameAsWritten}" '
          'will be discarded. The attachment stays in the audit log as skipped.',
          style: GoogleFonts.manrope(fontSize: 13, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Skip'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    _flushCurrentToQueue();
    q.status = _QueueStatus.skipped;
    await _advanceOrFinish();
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

  void _resetAll() {
    setState(() {
      _stage = _Stage.compose;
      _pasteCtl.clear();
      _notesCtl.clear();
      _draft = null;
      _resolvedCustomer = null;
      _chosenCustomer = null;
      _reviewLines.clear();
      _deliveryDate = DateTime.now().add(const Duration(days: 1));
      _attachments.clear();
      _queue.clear();
      _queueIdx = 0;
      _parseProgress = null;
      _textInputType = null;
    });
  }

  /// Abandon the whole batch mid-review. Writes "discarded" audit rows
  /// for any attachment whose drafts have all finalized.
  Future<void> _discardBatch() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Discard this batch?'),
        content: Text(
          'All unsaved drafts in this review session will be lost. '
          'Already-saved orders stay saved.',
          style: GoogleFonts.manrope(fontSize: 13, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep reviewing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    // Mark every still-reviewing draft as skipped so audit rows reflect
    // the admin's abandonment choice.
    for (final q in _queue) {
      if (q.status == _QueueStatus.reviewing) {
        q.status = _QueueStatus.skipped;
      }
    }
    for (int i = 0; i < _attachments.length; i++) {
      await _maybeFinalizeAttachmentAudit(i);
    }
    _resetAll();
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
    final parseLabel = _parsing
        ? (_parseProgress ?? 'Parsing…')
        : _attachments.isEmpty
            ? 'Parse with Gemini (add something first)'
            : 'Parse ${_attachments.length} attachment${_attachments.length == 1 ? "" : "s"} with Gemini';
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
                child: _TeamChoice(
                  label: t == 'JA' ? 'Jagannath' : 'Madhav',
                  color: t == 'JA'
                      ? const Color(0xFF1D4ED8)
                      : const Color(0xFFC2410C),
                  selected: _team == t,
                  onTap: () => _onTeamChanged(t),
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
          _sectionLabel('ATTACHMENTS (${_attachments.length})'),
          if (_attachments.isEmpty)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.inbox_rounded, size: 20, color: Colors.grey.shade600),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No attachments yet. Add any mix of pastes, images, or PDFs — '
                      'each is parsed independently, and one attachment may produce '
                      'multiple orders.',
                      style: GoogleFonts.manrope(fontSize: 12, color: Colors.grey.shade800, height: 1.4),
                    ),
                  ),
                ],
              ),
            )
          else
            for (int i = 0; i < _attachments.length; i++)
              _buildAttachmentCard(i, _attachments[i]),
          const SizedBox(height: 10),
          _buildAddButtons(),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: (_parsing || _attachments.isEmpty) ? null : _parse,
            icon: _parsing
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(parseLabel,
                style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800)),
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
                    'Duplicate guard is per-attachment: each paste/file hash can be '
                    'imported once per team. One attachment may contain multiple '
                    'orders — Gemini detects distinct customer headers and emits '
                    'one review card per order. Nothing saves until you review each.',
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

  Widget _buildAttachmentCard(int index, _Attachment a) {
    final (icon, accent) = switch (a.kind) {
      _AttachmentKind.pdf => (Icons.picture_as_pdf_rounded, Colors.red.shade700),
      _AttachmentKind.image => (Icons.image_rounded, Colors.teal.shade700),
      _AttachmentKind.paste => (Icons.notes_rounded, Colors.indigo.shade600),
    };
    final subtitle = switch (a.kind) {
      _AttachmentKind.paste => '${(a.text ?? "").length} chars · ${a.inputType}',
      _ => '${(a.byteSize / 1024).toStringAsFixed(1)} KB · ${a.mime}',
    };
    final isDup = a.status == _AttachmentStatus.duplicate;
    final isErr = a.status == _AttachmentStatus.error;
    final cardAccent = isDup
        ? Colors.orange.shade700
        : isErr
            ? Colors.red.shade700
            : accent;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cardAccent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cardAccent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: cardAccent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
                    Text(subtitle,
                        style: GoogleFonts.manrope(fontSize: 10.5, color: Colors.black54)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Remove',
                onPressed: _parsing ? null : () => _removeAttachment(index),
              ),
            ],
          ),
          if (isDup)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.content_copy_rounded,
                      size: 14, color: Colors.orange.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Duplicate — already imported to this team.',
                      style: GoogleFonts.manrope(
                          fontSize: 11, color: Colors.orange.shade900),
                    ),
                  ),
                  if (widget.isSuperAdmin && a.dupInfo != null)
                    TextButton.icon(
                      onPressed: _parsing
                          ? null
                          : () {
                              final rowId = a.dupInfo!['id']?.toString();
                              if (rowId != null && rowId.isNotEmpty) {
                                _revokeAndRetry(index, rowId);
                              }
                            },
                      icon: const Icon(Icons.lock_open_rounded, size: 14),
                      label: Text('Revoke',
                          style: GoogleFonts.manrope(
                              fontSize: 11, fontWeight: FontWeight.w800)),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.purple.shade800,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                ],
              ),
            ),
          if (isErr)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 14, color: Colors.red.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Parse failed: ${a.parseError ?? "unknown"}',
                      style: GoogleFonts.manrope(
                          fontSize: 11, color: Colors.red.shade900),
                    ),
                  ),
                ],
              ),
            ),
          if (a.kind == _AttachmentKind.image)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 2),
              child: Row(
                children: [
                  Checkbox(
                    value: a.inputType == 'image_handwritten',
                    onChanged: _parsing ? null : (_) => _toggleHandwritten(index),
                    visualDensity: VisualDensity.compact,
                  ),
                  Text('Handwritten photo',
                      style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          if (a.kind == _AttachmentKind.pdf || a.kind == _AttachmentKind.image)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: (_parsing || _billChecking.contains(a.id))
                      ? null
                      : () => _treatAsBill(index),
                  icon: _billChecking.contains(a.id)
                      ? const SizedBox(
                          width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.receipt_long_rounded, size: 14),
                  label: Text(
                    _billChecking.contains(a.id) ? 'Checking…' : 'Treat as bill',
                    style: GoogleFonts.manrope(
                        fontSize: 11, fontWeight: FontWeight.w800),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.deepPurple.shade700,
                    side: BorderSide(color: Colors.deepPurple.shade300),
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAddButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _parsing ? null : _addPaste,
            icon: const Icon(Icons.notes_rounded, size: 18),
            label: Text('Add Paste',
                style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _parsing ? null : _pickPdf,
            icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
            label: Text('Add PDF',
                style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _parsing ? null : _pickImage,
            icon: const Icon(Icons.image_rounded, size: 18),
            label: Text('Add Image',
                style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          ),
        ),
      ],
    );
  }


  // ── Review view ────────────────────────────────────────────────────────
  Widget _buildReview() {
    final unresolved = _reviewLines.where((l) => l.chosen == null).length;
    final currentQ = (_queueIdx >= 0 && _queueIdx < _queue.length)
        ? _queue[_queueIdx]
        : null;
    final currentAtt = (currentQ != null &&
            currentQ.attachmentIndex >= 0 &&
            currentQ.attachmentIndex < _attachments.length)
        ? _attachments[currentQ.attachmentIndex]
        : null;
    final isHandwritten = currentAtt?.inputType == 'image_handwritten';
    final savedCount =
        _queue.where((q) => q.status == _QueueStatus.saved).length;
    final skippedCount =
        _queue.where((q) => q.status == _QueueStatus.skipped).length;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            IconButton(
              onPressed: _discardBatch,
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: 'Discard batch',
            ),
            Expanded(
              child: Text('Review Draft',
                  style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
          ]),
          if (_queue.length > 1) ...[
            const SizedBox(height: 8),
            _buildQueueProgress(savedCount, skippedCount),
          ],
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
          if (isHandwritten)
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
          // Candidates from the resolver. If this list is empty (no fuzzy
          // hits) the dropdown is useless alone — see the "Search all
          // customers" button below which always works.
          if ((resolved?.candidates ?? const []).isNotEmpty)
            DropdownButtonFormField<CustomerModel?>(
              initialValue: _chosenCustomer,
              isExpanded: true,
              decoration: _fieldDecoration(
                  hint: 'Pick a suggested match or search below'),
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
          const SizedBox(height: 8),
          // Always-available full search — covers the case where the
          // resolver produced 0 candidates, or none of the 3 candidates is
          // the right one. Opens a search sheet over every team customer.
          OutlinedButton.icon(
            icon: const Icon(Icons.search_rounded, size: 16),
            label: Text(
              _chosenCustomer == null
                  ? 'Search all customers'
                  : 'Change customer',
              style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            onPressed: _pickCustomerFromCatalog,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustomerFromCatalog() async {
    final all = await SupabaseService.instance.getCustomers();
    final teamCustomers = all.where((c) => c.belongsToTeam(_team)).toList();
    if (!mounted) return;
    final picked = await showModalBottomSheet<CustomerModel>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SearchSheet<CustomerModel>(
        title: 'Search customers · $_team',
        items: teamCustomers,
        displayTitle: (c) => c.name,
        displaySubtitle: (c) => c.phone.isEmpty ? '—' : c.phone,
        searchFields: (c) => [c.name, c.phone, c.address],
      ),
    );
    if (picked == null) return;
    setState(() => _chosenCustomer = picked);
    _recomputeAllCsds();
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
            // Candidates from the resolver. Only rendered when there's
            // something to pick — empty candidate list was the lock-in bug
            // (admin stranded with no UI to choose a product).
            if (line.resolved.candidates.isNotEmpty ||
                (line.chosen != null &&
                    !line.resolved.candidates.map((p) => p.id).contains(line.chosen!.id)))
              DropdownButtonFormField<ProductModel?>(
                initialValue: line.chosen,
                isExpanded: true,
                decoration: _fieldDecoration(
                    hint: line.chosen == null ? 'Pick a suggestion…' : null),
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
            const SizedBox(height: 4),
            // Always-available full catalog search. Critical when the
            // resolver returned 0 candidates OR the right product isn't
            // in the top 3. Previously admin was stuck on "No match".
            OutlinedButton.icon(
              icon: const Icon(Icons.search_rounded, size: 16),
              label: Text(
                line.chosen == null ? 'Search catalog' : 'Change product',
                style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              onPressed: () => _pickProductForLine(line),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(38),
              ),
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

  Future<void> _pickProductForLine(_ReviewLine line) async {
    final products = await SupabaseService.instance.getProducts(teamId: _team);
    if (!mounted) return;
    final picked = await showModalBottomSheet<ProductModel>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SearchSheet<ProductModel>(
        title: 'Search catalog · $_team',
        items: products,
        // Seed the pre-typed query with what was parsed — admin usually
        // wants to refine the parsed text, not start from zero.
        initialQuery: line.draft.nameAsWritten,
        displayTitle: (p) => p.name,
        displaySubtitle: (p) => '${p.sku} · ${p.category} · ₹${p.unitPrice.toStringAsFixed(2)}',
        searchFields: (p) => [p.name, p.sku, p.category, p.company],
      ),
    );
    if (picked == null) return;
    setState(() {
      line.chosen = picked;
      // Picking manually implies the admin has verified this line.
      line.confirmed = true;
    });
    _recomputeCsds(line);
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
    final hasMoreAfter = _queue.length > 1 &&
        _queue.skip(_queueIdx + 1).any((q) => q.status == _QueueStatus.reviewing);
    final saveLabel = _submitting
        ? 'Saving…'
        : hasMoreAfter
            ? 'Save & Next'
            : (_queue.length > 1 ? 'Save & Finish' : 'Save Order');
    return Row(
      children: [
        if (_queue.length > 1)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton.icon(
              onPressed: _submitting ? null : _skipCurrent,
              icon: const Icon(Icons.skip_next_rounded, size: 18),
              label: Text('Skip',
                  style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
            ),
          ),
        Expanded(
          child: FilledButton.icon(
            onPressed: _canSave ? _save : null,
            icon: _submitting
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.save_rounded),
            label: Text(saveLabel,
                style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800)),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: AppTheme.primary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQueueProgress(int saved, int skipped) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.layers_rounded, size: 18, color: AppTheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Order ${_queueIdx + 1} of ${_queue.length}'
              '${saved > 0 || skipped > 0 ? "  ·  $saved saved · $skipped skipped" : ""}',
              style: GoogleFonts.manrope(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.primary,
              ),
            ),
          ),
          if (_queue.length > 1) ...[
            IconButton(
              onPressed: _queueIdx > 0 && !_submitting
                  ? () {
                      _flushCurrentToQueue();
                      setState(() => _queueIdx--);
                      _hydrateCurrent();
                      _recomputeAllCsds();
                    }
                  : null,
              icon: const Icon(Icons.chevron_left_rounded),
              tooltip: 'Previous draft',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: _queueIdx < _queue.length - 1 && !_submitting
                  ? () {
                      _flushCurrentToQueue();
                      setState(() => _queueIdx++);
                      _hydrateCurrent();
                      _recomputeAllCsds();
                    }
                  : null,
              icon: const Icon(Icons.chevron_right_rounded),
              tooltip: 'Next draft',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
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

// ─────────────────────────────────────────────────────────────────────────
// Generic bottom-sheet search over a list. Unblocks the review screen
// when the Gemini resolver produced 0 or wrong candidates: admin can now
// search the full team catalog (customers or products) and pick manually.
// ─────────────────────────────────────────────────────────────────────────
class _SearchSheet<T> extends StatefulWidget {
  final String title;
  final List<T> items;
  final String Function(T) displayTitle;
  final String Function(T) displaySubtitle;
  final List<String?> Function(T) searchFields;
  final String? initialQuery;

  const _SearchSheet({
    required this.title,
    required this.items,
    required this.displayTitle,
    required this.displaySubtitle,
    required this.searchFields,
    this.initialQuery,
  });

  @override
  State<_SearchSheet<T>> createState() => _SearchSheetState<T>();
}

class _SearchSheetState<T> extends State<_SearchSheet<T>> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.initialQuery ?? '');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _ctl.text;
    // Two-pass search for multi-word queries:
    //   1. Strict (every token must hit a field) — highest-quality matches
    //      shown first.
    //   2. Loose (any one token hits) — only used as a fallback when the
    //      query has 2+ words; appended after a divider so the user sees
    //      "you typed 'vishal kumar enterprises' — here's the best fit
    //      [strict], and here's everything that touched any of those words
    //      [loose]."
    // Single-word queries don't differ between strict/loose — skip pass 2.
    final qTrim = q.trim();
    final tokenCount = searchTokens(qTrim).length;
    late final List<T> strictMatches;
    late final List<T> looseOnly;
    if (qTrim.isEmpty) {
      strictMatches = widget.items.take(50).toList();
      looseOnly = const [];
    } else {
      strictMatches = widget.items
          .where((it) => tokenMatch(qTrim, widget.searchFields(it)))
          .take(100)
          .toList();
      if (tokenCount >= 2) {
        final strictSet = strictMatches.toSet();
        looseOnly = widget.items
            .where((it) =>
                !strictSet.contains(it) &&
                tokenMatchAny(qTrim, widget.searchFields(it)))
            .take(100 - strictMatches.length)
            .toList();
      } else {
        looseOnly = const [];
      }
    }
    final matches = [...strictMatches, ...looseOnly];
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (_, scroll) => Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
              child: Row(children: [
                Expanded(
                  child: Text(widget.title,
                      style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _ctl,
                autofocus: true,
                onChanged: (_) => setState(() {/* refilter */}),
                decoration: InputDecoration(
                  hintText: 'Type to filter',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  suffixIcon: _ctl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 16),
                          onPressed: () => setState(() => _ctl.clear()),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(children: [
                Text(
                  looseOnly.isEmpty
                      ? '${matches.length} result${matches.length == 1 ? "" : "s"}'
                      : '${strictMatches.length} exact · ${looseOnly.length} loose',
                  style: GoogleFonts.manrope(fontSize: 11, color: Colors.black54),
                ),
              ]),
            ),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        'No matches. Try fewer or different words.',
                        style: GoogleFonts.manrope(fontSize: 12, color: Colors.black45),
                      ),
                    )
                  : ListView.builder(
                      controller: scroll,
                      // +1 for the loose-section header when any loose hits.
                      itemCount: matches.length +
                          (looseOnly.isNotEmpty ? 1 : 0),
                      itemBuilder: (_, idx) {
                        // Insert a section header between strict and loose.
                        final headerSlot = strictMatches.length;
                        if (looseOnly.isNotEmpty && idx == headerSlot) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            color: Colors.grey.shade100,
                            child: Row(children: [
                              Icon(Icons.search_rounded,
                                  size: 12, color: Colors.grey.shade700),
                              const SizedBox(width: 6),
                              Text(
                                'Looser matches (any word)',
                                style: GoogleFonts.manrope(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ]),
                          );
                        }
                        final i = (looseOnly.isNotEmpty && idx > headerSlot)
                            ? idx - 1
                            : idx;
                        final it = matches[i];
                        return Column(
                          children: [
                            ListTile(
                              dense: true,
                              title: Text(widget.displayTitle(it),
                                  style: GoogleFonts.manrope(
                                      fontSize: 13, fontWeight: FontWeight.w600)),
                              subtitle: Text(widget.displaySubtitle(it),
                                  style: GoogleFonts.manrope(
                                      fontSize: 11, color: Colors.black54)),
                              onTap: () => Navigator.pop(context, it),
                            ),
                            const Divider(height: 1),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom-sheet composer used by the "Add Paste" button. Separated from the
/// main tab so the keyboard + dropdown state is scoped to the modal.
class _PasteComposerSheet extends StatefulWidget {
  final TextEditingController controller;
  final String? initialInputType;
  final _Attachment Function(String text, String inputType) build;

  const _PasteComposerSheet({
    required this.controller,
    required this.initialInputType,
    required this.build,
  });

  @override
  State<_PasteComposerSheet> createState() => _PasteComposerSheetState();
}

class _PasteComposerSheetState extends State<_PasteComposerSheet> {
  String? _override;

  @override
  void initState() {
    super.initState();
    _override = widget.initialInputType;
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final hasText = text.trim().isNotEmpty;
    final effective = _override ??
        (hasText ? SmartImportService.classifyTextInput(text) : 'whatsapp_text');
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text('Add pasted order',
                    style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800)),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
            TextField(
              controller: widget.controller,
              maxLines: 10,
              autofocus: true,
              onChanged: (_) => setState(() {/* reclassify */}),
              decoration: InputDecoration(
                hintText: 'Paste brand-software text, WhatsApp message, etc. '
                    'Multiple orders in one paste are OK — Gemini splits them.',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 10),
            if (hasText)
              Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 14, color: Colors.black54),
                  const SizedBox(width: 6),
                  Text('Type:',
                      style: GoogleFonts.manrope(
                          fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    isDense: true,
                    value: effective,
                    items: const [
                      DropdownMenuItem(
                          value: 'brand_software_text', child: Text('Brand software (GUBB/SCO)')),
                      DropdownMenuItem(
                          value: 'whatsapp_text', child: Text('WhatsApp / casual')),
                    ],
                    onChanged: (v) => setState(() => _override = v),
                  ),
                  const SizedBox(width: 6),
                  if (_override == null)
                    Text('(auto)',
                        style: GoogleFonts.manrope(fontSize: 10, color: Colors.black38)),
                ],
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: hasText
                  ? () => Navigator.pop(context, widget.build(text, effective))
                  : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
              child: Text('Add to batch',
                  style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeamChoice extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _TeamChoice({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? color : color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? color : color.withValues(alpha: 0.40),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.manrope(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : color,
          ),
        ),
      ),
    );
  }
}
