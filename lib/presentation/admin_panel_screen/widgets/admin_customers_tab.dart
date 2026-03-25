import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';

// All errors are cascading from package URI resolution errors for 'flutter/material.dart' and 'google_fonts/google_fonts.dart'; the imports are already correctly written in the file and no Dart code changes can resolve missing package dependencies. //

class AdminCustomersTab extends StatefulWidget {
  const AdminCustomersTab({super.key});

  @override
  State<AdminCustomersTab> createState() => _AdminCustomersTabState();
}

class _AdminCustomersTabState extends State<AdminCustomersTab> {
  bool _isLoading = true;
  List<CustomerModel> _customers = [];
  List<BeatModel> _beats = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final customers = await SupabaseService.instance.getCustomers();
      final beats = await SupabaseService.instance.getBeats();
      if (!mounted) return;
      setState(() {
        _customers = customers;
        _beats = beats;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _showCustomerDialog(CustomerModel? customer) {
    final nameCtrl = TextEditingController(text: customer?.name ?? '');
    final phoneCtrl = TextEditingController(text: customer?.phone ?? '');
    final addressCtrl = TextEditingController(text: customer?.address ?? '');

    final types = [
      'General Trade',
      'Modern Trade',
      'Wholesale',
      'HoReCa',
      'Pharmacy',
      'Other',
    ];
    String? selectedType =
        types.contains(customer?.type) ? customer?.type : types.first;
    String? selectedBeatId =
        _beats.any((b) => b.id == customer?.beatId) ? customer?.beatId : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            customer == null ? 'Add Customer' : 'Edit Customer',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                buildAdminTextField('Name', nameCtrl),
                const SizedBox(height: 10),
                buildAdminTextField(
                  'Phone',
                  phoneCtrl,
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 10),
                buildAdminTextField('Address', addressCtrl),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selectedType,
                  decoration: InputDecoration(
                    labelText: 'Customer Type',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  items: types
                      .map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text(
                            t,
                            style: GoogleFonts.manrope(fontSize: 13),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setDialogState(() => selectedType = v),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selectedBeatId,
                  decoration: InputDecoration(
                    labelText: 'Assign Beat',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(
                        'No Beat',
                        style: GoogleFonts.manrope(fontSize: 13),
                      ),
                    ),
                    ..._beats.map(
                      (b) => DropdownMenuItem(
                        value: b.id,
                        child: Text(
                          b.beatName,
                          style: GoogleFonts.manrope(fontSize: 13),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (v) => setDialogState(() => selectedBeatId = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: GoogleFonts.manrope()),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  final beatName = _beats
                      .firstWhere(
                        (b) => b.id == selectedBeatId,
                        orElse: () => const BeatModel(
                          id: '',
                          beatName: '',
                          beatCode: '',
                          weekdays: [],
                        ),
                      )
                      .beatName;
                  if (customer == null) {
                    await SupabaseService.instance.createCustomer(
                      name: nameCtrl.text.trim(),
                      phone: phoneCtrl.text.trim(),
                      address: addressCtrl.text.trim(),
                      type: selectedType ?? 'General Trade',
                      beatId: selectedBeatId,
                      beat: beatName,
                    );
                  } else {
                    await SupabaseService.instance.updateCustomer(
                      id: customer.id,
                      name: nameCtrl.text.trim(),
                      phone: phoneCtrl.text.trim(),
                      address: addressCtrl.text.trim(),
                      type: selectedType ?? customer.type,
                      beatId: selectedBeatId,
                      beat: beatName,
                    );
                  }
                  _load();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          customer == null
                              ? 'Customer added'
                              : 'Customer updated',
                          style: GoogleFonts.manrope(),
                        ),
                        backgroundColor: AppTheme.success,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Error: $e',
                          style: GoogleFonts.manrope(),
                        ),
                        backgroundColor: AppTheme.error,
                      ),
                    );
                  }
                }
              },
              child: Text(
                'Save',
                style: GoogleFonts.manrope(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AdminErrorRetry(message: _error!, onRetry: _load);
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_rounded),
        label: Text('Add Customer', style: GoogleFonts.manrope(fontSize: 13)),
        onPressed: () => _showCustomerDialog(null),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primary,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
          itemCount: _customers.length,
          itemBuilder: (context, index) {
            final c = _customers[index];
            return AdminCard(
              title: c.name,
              subtitle: '${c.type} · ${c.beat}',
              trailing: c.phone,
              onEdit: () => _showCustomerDialog(c),
            );
          },
        ),
      ),
    );
  }
}
