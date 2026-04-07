import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';
import '../../services/auth_service.dart';

class CustomerListScreen extends StatefulWidget {
  const CustomerListScreen({super.key});

  @override
  State<CustomerListScreen> createState() => _CustomerListScreenState();
}

class _CustomerListScreenState extends State<CustomerListScreen> {
  BeatModel? _beat;
  bool _isOutOfBeat = false;
  List<CustomerModel> _allCustomers = [];
  List<CustomerModel> _filteredCustomers = [];
  bool _isLoading = true;
  String _sortBy = 'Alphabetical';

  // Track which missing-phone dialogs have been shown this session (once per customer)
  final Set<String> _shownPhoneDialogIds = {};

  // TASK 2C — set of customer IDs visited today
  Set<String> _visitedIds = {};

  // Multi-beat merged view
  List<BeatModel> _beats = [];
  bool _isMergedView = false;
  String? _activeBeatFilter; // null = all beats, or beatId to filter

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_beat == null && !_isMergedView) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is BeatModel) {
        _beat = args;
        _isOutOfBeat = false;
      } else if (args is Map) {
        if (args.containsKey('beats')) {
          _beats = List<BeatModel>.from(args['beats'] as List);
          _isMergedView = true;
          _beat = _beats.first; // fallback for compatibility
        } else {
          _beat = args['beat'] as BeatModel?;
          _isOutOfBeat = args['isOutOfBeat'] as bool? ?? false;
        }
      }
      _loadCustomers();
    }
  }

  Future<void> _loadCustomers({bool forceRefresh = false}) async {
    setState(() => _isLoading = true);
    try {
      final customers = await SupabaseService.instance.getCustomers(forceRefresh: forceRefresh);

      // TASK 2C — fetch today's orders to build visitedIds
      final todayStr = DateTime.now().toIso8601String().substring(0, 10);
      final todayOrders = await SupabaseService.instance.getOrdersByDate(todayStr);
      final visitedIds = todayOrders
          .map((o) => o['customer_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      if (!mounted) return;
      setState(() {
        if (_isMergedView) {
          // Merged multi-beat mode: show customers from all today's beats
          // Each beat may be a different team, so check per-beat team
          final seenIds = <String>{};
          final merged = <CustomerModel>[];
          for (final b in _beats) {
            if (_activeBeatFilter != null && b.id != _activeBeatFilter) continue;
            for (final c in customers) {
              if (seenIds.contains(c.id)) continue;
              final bid = c.beatIdForTeam(b.teamId);
              if (bid == b.id) {
                merged.add(c);
                seenIds.add(c.id);
              }
            }
          }
          _allCustomers = merged;
        } else if (_beat == null) {
          // Admin / no-beat context: show all customers.
          _allCustomers = customers;
        } else if (_isOutOfBeat) {
          // Out-of-Beat mode: show only customers assigned to the selected beat.
          _allCustomers = customers
              .where((c) => c.beatIdForTeam(AuthService.currentTeam) == _beat!.id)
              .toList();
        } else {
          // Normal beat mode: strictly filter to this beat.
          _allCustomers = customers
              .where((c) => c.beatIdForTeam(AuthService.currentTeam) == _beat!.id)
              .toList();
        }
        _visitedIds = visitedIds;
        _applyFilters('');
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _applyFilters(String query) {
    List<CustomerModel> temp = _allCustomers.where((c) =>
        c.name.toLowerCase().contains(query.toLowerCase())).toList();

    if (_sortBy == 'Alphabetical') {
      temp.sort((a, b) => a.name.compareTo(b.name));
    } else if (_sortBy == 'High Value') {
      temp.sort((a, b) => b.lastOrderValue.compareTo(a.lastOrderValue));
    } else if (_sortBy == 'Recent Order') {
      temp.sort((a, b) {
        if (a.lastOrderDate == null) return 1;
        if (b.lastOrderDate == null) return -1;
        return b.lastOrderDate!.compareTo(a.lastOrderDate!);
      });
    }

    setState(() => _filteredCustomers = temp);
  }

  Widget _buildBeatChip(String? beatId, String label) {
    final selected = _activeBeatFilter == beatId;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          setState(() => _activeBeatFilter = beatId);
          _loadCustomers();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppTheme.primary : AppTheme.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppTheme.primary : AppTheme.primary.withValues(alpha: 0.2),
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.manrope(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : AppTheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  bool get _isDualTeam => _isMergedView &&
      _beats.map((b) => b.teamId).toSet().length > 1;

  void _onCustomerTap(CustomerModel customer) {
    final phoneIsMissing = customer.phone.isEmpty || customer.phone == 'No Phone';
    final alreadyShown = _shownPhoneDialogIds.contains(customer.id);

    if (phoneIsMissing && !alreadyShown) {
      _shownPhoneDialogIds.add(customer.id);
      _showPhoneMissingDialog(customer);
      return;
    }

    // In merged view, set team context based on customer's beat
    if (_isMergedView) {
      for (final b in _beats) {
        if (customer.beatIdForTeam(b.teamId) == b.id) {
          AuthService.currentTeam = b.teamId;
          break;
        }
      }
    }
    // Navigate — dual-team customers handled inside customer detail screen
    Navigator.pushNamed(context, AppRoutes.customerDetails, arguments: customer);
  }

  void _showTeamPicker(CustomerModel customer) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(8))),
            ),
            const SizedBox(height: 16),
            Text('${customer.name}', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('This customer is in both teams. Which order?',
                style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.1), shape: BoxShape.circle),
                child: const Icon(Icons.storefront_rounded, color: Colors.blue, size: 20),
              ),
              title: Text('Jagannath (JA) Order', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
              subtitle: Text('Outstanding: \u20B9${customer.outstandingForTeam('JA').toStringAsFixed(0)}',
                  style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              onTap: () {
                Navigator.pop(ctx);
                AuthService.currentTeam = 'JA';
                Navigator.pushNamed(context, AppRoutes.customerDetails, arguments: customer);
              },
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.1), shape: BoxShape.circle),
                child: const Icon(Icons.storefront_rounded, color: Colors.orange, size: 20),
              ),
              title: Text('Madhav (MA) Order', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
              subtitle: Text('Outstanding: \u20B9${customer.outstandingForTeam('MA').toStringAsFixed(0)}',
                  style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              onTap: () {
                Navigator.pop(ctx);
                AuthService.currentTeam = 'MA';
                Navigator.pushNamed(context, AppRoutes.customerDetails, arguments: customer);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(
          _isMergedView
              ? (_activeBeatFilter != null
                  ? _beats.firstWhere((b) => b.id == _activeBeatFilter, orElse: () => _beats.first).beatName
                  : "Today's Beats")
              : (_beat?.beatName ?? 'CUSTOMERS'),
          style: GoogleFonts.manrope(fontWeight: FontWeight.w800),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_rounded),
            onSelected: (val) {
              setState(() => _sortBy = val);
              _applyFilters('');
            },
            itemBuilder: (context) => ['Alphabetical', 'High Value', 'Recent Order']
                .map((e) => PopupMenuItem(value: e, child: Text("Sort by $e")))
                .toList(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Note: merged view shows all today's customers directly — no beat filter chips
          if (_isOutOfBeat)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.orange.shade700,
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Out of Beat Mode — orders will be logged outside your assigned route',
                      style: GoogleFonts.manrope(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search store...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: AppTheme.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
              onChanged: _applyFilters,
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _loadCustomers(forceRefresh: true),
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _filteredCustomers.length,
                itemBuilder: (context, index) => _buildCustomerCard(_filteredCustomers[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENTS ---

  Widget _buildCustomerCard(CustomerModel customer) {
    final phoneIsMissing = customer.phone.isEmpty || customer.phone == 'No Phone';

    // TASK 2C — show "Not Visited" only 8am–7pm and when phone is present
    final now = TimeOfDay.now();
    final isWorkingHours =
        (now.hour > 8 || (now.hour == 8 && now.minute >= 0)) &&
            now.hour < 19;
    final isNotVisited =
        isWorkingHours && !phoneIsMissing && !_visitedIds.contains(customer.id);

    // TASK 2D — Dismissible for swipe-left to log no-order reason
    return Dismissible(
      key: ValueKey(customer.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        _showLogVisitSheet(customer);
        return false;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.orange.shade600,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.note_add_outlined, color: Colors.white, size: 22),
            const SizedBox(height: 4),
            Text(
              'Log Visit',
              style: GoogleFonts.manrope(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppTheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: InkWell(
          onTap: () => _onCustomerTap(customer),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                      child: Text(
                        customer.name.isNotEmpty ? customer.name[0].toUpperCase() : '?',
                        style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            customer.name,
                            style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            customer.phone.isEmpty ? 'No Phone' : customer.phone,
                            style: GoogleFonts.manrope(
                              fontSize: 13,
                              color: phoneIsMissing ? Colors.red.shade400 : AppTheme.onSurfaceVariant,
                              fontWeight: phoneIsMissing ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                          // TASK 2A — Outstanding balance
                          _buildBalanceRow(customer.outstandingForTeam(AuthService.currentTeam)),
                          // Phone and WhatsApp buttons (if phone present)
                          if (!phoneIsMissing) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                _buildCallButton(customer.phone),
                                const SizedBox(width: 8),
                                _buildWhatsAppButton(customer.phone),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Badges column
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // Beat name badge in merged view
                        if (_isMergedView)
                          ..._beats
                              .where((b) => customer.beatIdForTeam(b.teamId) == b.id)
                              .map((b) => Container(
                                    margin: const EdgeInsets.only(bottom: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: _isDualTeam
                                          ? (b.teamId == 'JA' ? Colors.blue.withValues(alpha: 0.1) : Colors.orange.withValues(alpha: 0.1))
                                          : AppTheme.primaryContainer,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      _isDualTeam ? '${b.beatName} (${b.teamId})' : b.beatName,
                                      style: GoogleFonts.manrope(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        color: _isDualTeam
                                            ? (b.teamId == 'JA' ? Colors.blue : Colors.orange)
                                            : AppTheme.primary,
                                      ),
                                    ),
                                  )),
                        // Red "Action Required" badge for missing phone
                        if (phoneIsMissing)
                          _buildActionRequiredBadge(),
                        // TASK 2C — Not Visited badge (only if phone present)
                        if (isNotVisited) ...[
                          if (phoneIsMissing) const SizedBox(height: 4),
                          _buildNotVisitedBadge(),
                        ],
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // TASK 2A
  Widget _buildBalanceRow(double balance) {
    if (balance == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          'Cleared',
          style: GoogleFonts.manrope(fontSize: 12, color: Colors.green.shade600, fontWeight: FontWeight.w600),
        ),
      );
    } else if (balance <= 5000) {
      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          '₹${balance.toStringAsFixed(0)} due',
          style: GoogleFonts.manrope(fontSize: 12, color: Colors.orange.shade700, fontWeight: FontWeight.w600),
        ),
      );
    } else {
      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          '₹${balance.toStringAsFixed(0)} due',
          style: GoogleFonts.manrope(fontSize: 12, color: Colors.red.shade700, fontWeight: FontWeight.w800),
        ),
      );
    }
  }

  // TASK 2B — Call button
  Widget _buildCallButton(String phone) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        final uri = Uri(scheme: 'tel', path: phone);
        if (await canLaunchUrl(uri)) await launchUrl(uri);
      },
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.phone_outlined, size: 18, color: Colors.green.shade700),
      ),
    );
  }

  // TASK 2B — WhatsApp button
  Widget _buildWhatsAppButton(String phone) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        // Strip non-digits then take last 10 digits
        final digits = phone.replaceAll(RegExp(r'\D'), '');
        final number = digits.length >= 10 ? digits.substring(digits.length - 10) : digits;
        final uri = Uri.parse('whatsapp://send?phone=91$number');
        if (await canLaunchUrl(uri)) await launchUrl(uri);
      },
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFFE7F5E9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.chat_outlined, size: 18, color: Colors.green.shade800),
      ),
    );
  }

  Widget _buildTypeBadge(String type) {
    final color = type.toLowerCase() == 'wholesale' ? Colors.blue : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        type.toUpperCase(),
        style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: color),
      ),
    );
  }

  Widget _buildActionRequiredBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Action Required',
        style: GoogleFonts.manrope(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }

  // TASK 2C
  Widget _buildNotVisitedBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.orange.shade600,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Not Visited',
        style: GoogleFonts.manrope(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }

  // TASK 2D — Bottom sheet for logging visit reason
  void _showLogVisitSheet(CustomerModel customer) {
    const reasons = [
      'Shop Closed',
      'Stock Full',
      'Owner Not Available',
      'Not Interested',
      'Will Order Later',
      'Other',
    ];

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Log Visit — ${customer.name}',
                style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'Why no order today?',
                style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant),
              ),
            ),
            ...reasons.map((reason) => ListTile(
              leading: const Icon(Icons.radio_button_unchecked, size: 20),
              title: Text(reason, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w500)),
              onTap: () async {
                Navigator.pop(ctx);
                await _logVisit(customer, reason);
              },
            )),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _logVisit(CustomerModel customer, String reason) async {
    try {
      // In merged view, use the customer's actual beat ID
      final beatId = _isMergedView
          ? (customer.beatIdForTeam(AuthService.currentTeam) ?? _beat?.id ?? '')
          : (_beat?.id ?? '');
      await SupabaseService.instance.logVisit(
        customerId: customer.id,
        beatId: beatId,
        reason: reason,
      );
      if (mounted) {
        setState(() => _visitedIds.add(customer.id));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Visit logged for ${customer.name}'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error logging visit: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // --- LOGIC METHODS ---

  /// Shows the "Phone Number Missing" dialog ONCE per session per customer.
  /// "Save & Continue" → saves phone, then navigates to customer detail.
  /// "Skip for Now" → navigates without saving.
  Future<void> _showPhoneMissingDialog(CustomerModel customer) async {
    final phoneController = TextEditingController();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.phone_missed_rounded, color: Colors.red, size: 20),
            const SizedBox(width: 8),
            Text(
              "Phone Number Missing",
              style: GoogleFonts.manrope(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Please collect and enter this customer's phone number.",
              style: GoogleFonts.manrope(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              maxLength: 10,
              autofocus: true,
              decoration: InputDecoration(
                labelText: "Phone Number",
                prefixText: "+91 ",
                prefixIcon: const Icon(Icons.phone_outlined),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Skip for Now: navigate directly without saving
              Navigator.pushNamed(context, AppRoutes.customerDetails, arguments: customer);
            },
            child: Text(
              "Skip for Now",
              style: GoogleFonts.manrope(color: Colors.grey.shade600),
            ),
          ),
          FilledButton(
            onPressed: () async {
              final phone = phoneController.text.trim();
              if (phone.length < 10) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text("Enter a valid 10-digit number")),
                );
                return;
              }
              Navigator.pop(ctx);
              await _savePhoneAndNavigate(customer, phone);
            },
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            child: Text(
              "Save & Continue",
              style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _savePhoneAndNavigate(CustomerModel customer, String phone) async {
    await _savePhoneNumber(customer, phone);
    if (mounted) {
      // Find the updated customer from the list (it may have been updated by _savePhoneNumber)
      final updated = _allCustomers.firstWhere(
            (c) => c.id == customer.id,
        orElse: () => customer,
      );
      Navigator.pushNamed(context, AppRoutes.customerDetails, arguments: updated);
    }
  }

  Future<void> _savePhoneNumber(CustomerModel customer, String newPhone) async {
    try {
      await SupabaseService.instance.client
          .from('customers')
          .update({'phone': '+91$newPhone'})
          .eq('id', customer.id);

      final box = Hive.box('cache_${AuthService.currentTeam}');
      final updatedCustomer = customer.copyWith(phone: '+91$newPhone');

      // Use team-namespaced cache key to match _fetchWithCache pattern
      final cacheKey = 'customers_${AuthService.currentTeam}';
      final cachedStr = box.get(cacheKey) as String?;
      if (cachedStr != null) {
        List<dynamic> cachedList = jsonDecode(cachedStr);
        final index = cachedList.indexWhere((c) => c['id'] == customer.id);
        if (index != -1) {
          cachedList[index] = updatedCustomer.toJson();
          await box.put(cacheKey, jsonEncode(cachedList));
        }
      }

      setState(() {
        final index = _allCustomers.indexWhere((c) => c.id == customer.id);
        if (index != -1) _allCustomers[index] = updatedCustomer;
        _applyFilters('');
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Phone number saved!"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error saving phone: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }
}
