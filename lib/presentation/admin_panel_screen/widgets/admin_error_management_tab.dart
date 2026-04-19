import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/search_utils.dart';
import '../../../services/supabase_service.dart';
import '../../../services/auth_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';

class AdminErrorManagementTab extends StatefulWidget {
  const AdminErrorManagementTab({super.key});

  @override
  State<AdminErrorManagementTab> createState() => _AdminErrorManagementTabState();
}

class _AdminErrorManagementTabState extends State<AdminErrorManagementTab> {
  bool _isLoading = true;
  bool _isLoadingAction = false;
  String? _error;
  List<Map<String, dynamic>> _allErrors = [];
  List<Map<String, dynamic>> _filteredErrors = [];
  String _selectedStatus = 'unresolved'; // 'all', 'unresolved', 'resolved'
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadErrors();
  }

  Future<void> _loadErrors() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // CHANGED: unified — show errors from all teams
      final response = await SupabaseService.instance.client
          .from('app_error_logs')
          .select('id, error_message, order_id, error_type, created_at, resolved, team_id')
          .order('created_at', ascending: false);
      
      if (!mounted) return;
      setState(() {
        _allErrors = List<Map<String, dynamic>>.from(response);
        _filteredErrors = _filterErrors(_allErrors);
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

  List<Map<String, dynamic>> _filterErrors(List<Map<String, dynamic>> errors) {
    var filtered = errors.where((error) {
      // Filter by status
      if (_selectedStatus == 'unresolved') {
        return error['resolved'] == false;
      } else if (_selectedStatus == 'resolved') {
        return error['resolved'] == true;
      }
      return true; // 'all'
    }).toList();

    // Tokenized search filter
    if (_searchQuery.trim().isNotEmpty) {
      filtered = filtered.where((error) {
        return tokenMatch(_searchQuery, [
          error['error_message'] as String?,
          error['order_id'] as String?,
          error['error_type'] as String?,
        ]);
      }).toList();
    }

    return filtered;
  }

  void _onFilterChanged(String status) {
    setState(() {
      _selectedStatus = status;
      _filteredErrors = _filterErrors(_allErrors);
    });
  }

  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query;
      _filteredErrors = _filterErrors(_allErrors);
    });
  }

  Future<void> _markErrorResolved(String errorId) async {
    setState(() => _isLoadingAction = true);
    try {
      await SupabaseService.instance.client
          .from('app_error_logs')
          .update({'resolved': true})
          .eq('id', errorId)
          .eq('team_id', AuthService.currentTeam); // Security filter: only resolve own team's errors
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error marked as resolved'), backgroundColor: Colors.green),
        );
        _loadErrors();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error resolving alert: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isLoadingAction = false);
    }
  }

  Future<void> _markAllResolved() async {
    setState(() => _isLoadingAction = true);
    try {
      await SupabaseService.instance.client
          .from('app_error_logs')
          .update({'resolved': true})
          .eq('team_id', AuthService.currentTeam)
          .eq('resolved', false);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All errors marked as resolved'), backgroundColor: Colors.green),
        );
        _loadErrors();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error resolving alerts: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isLoadingAction = false);
    }
  }

  String _getTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }

  Color _getErrorTypeColor(String? errorType) {
    switch (errorType) {
      case 'background_processing':
        return Colors.red.shade600;
      case 'drive_upload':
        return Colors.orange.shade600;
      case 'ocr_processing':
        return Colors.purple.shade600;
      case 'balance_update_rpc':
        return Colors.blue.shade600;
      case 'sync_unfinished_eod':
        return Colors.deepOrange.shade700;
      default:
        return Colors.grey.shade600;
    }
  }

  String _getErrorTypeDisplay(String? errorType) {
    switch (errorType) {
      case 'background_processing':
        return 'Background Processing';
      case 'drive_upload':
        return 'Drive Upload';
      case 'ocr_processing':
        return 'OCR Processing';
      case 'balance_update_rpc':
        return 'Balance Update RPC';
      case 'sync_unfinished_eod':
        return 'Unsynced Orders at End of Day';
      default:
        return errorType?.replaceAll('_', ' ').toUpperCase() ?? 'UNKNOWN';
    }
  }

  @override
  Widget build(BuildContext context) {
    final unresolvedCount = _allErrors.where((e) => e['resolved'] == false).length;
    final resolvedCount = _allErrors.where((e) => e['resolved'] == true).length;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: RefreshIndicator(
        onRefresh: _loadErrors,
        child: CustomScrollView(
          slivers: [
            // Header with stats
            SliverToBoxAdapter(child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.red.shade600, Colors.red.shade700],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Colors.white, size: 28),
                      const SizedBox(width: 12),
                      Text('Error Management', style: GoogleFonts.manrope(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      )),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _StatCard(
                        label: 'Unresolved',
                        value: unresolvedCount.toString(),
                        color: Colors.white,
                        bgColor: Colors.white.withOpacity(0.2),
                      ),
                      const SizedBox(width: 12),
                      _StatCard(
                        label: 'Resolved',
                        value: resolvedCount.toString(),
                        color: Colors.white.withOpacity(0.8),
                        bgColor: Colors.white.withOpacity(0.1),
                      ),
                      const SizedBox(width: 12),
                      _StatCard(
                        label: 'Total',
                        value: _allErrors.length.toString(),
                        color: Colors.white,
                        bgColor: Colors.white.withOpacity(0.15),
                      ),
                    ],
                  ),
                ],
              ),
            )),

            // Filters and search
            SliverToBoxAdapter(child: Container(
              padding: const EdgeInsets.all(16),
              color: Colors.white,
              child: Column(
                children: [
                  // Status filter tabs
                  Row(
                    children: [
                      _FilterTab(
                        label: 'Unresolved',
                        count: unresolvedCount,
                        isActive: _selectedStatus == 'unresolved',
                        onTap: () => _onFilterChanged('unresolved'),
                        color: Colors.red,
                      ),
                      const SizedBox(width: 8),
                      _FilterTab(
                        label: 'Resolved',
                        count: resolvedCount,
                        isActive: _selectedStatus == 'resolved',
                        onTap: () => _onFilterChanged('resolved'),
                        color: Colors.green,
                      ),
                      const SizedBox(width: 8),
                      _FilterTab(
                        label: 'All',
                        count: _allErrors.length,
                        isActive: _selectedStatus == 'all',
                        onTap: () => _onFilterChanged('all'),
                        color: Colors.grey,
                      ),
                      const Spacer(),
                      if (unresolvedCount > 0)
                        TextButton.icon(
                          onPressed: _isLoadingAction ? null : _markAllResolved,
                          icon: _isLoadingAction
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.green),
                                )
                              : const Icon(Icons.check_circle_rounded, size: 16),
                          label: Text(_isLoadingAction ? 'Resolving...' : 'Mark All Resolved'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.green,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  
                  // Search bar
                  TextField(
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search by error message, order ID, or error type...',
                      prefixIcon: const Icon(Icons.search_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppTheme.primary),
                      ),
                    ),
                  ),
                ],
              ),
            )),

            // Error list
            if (_isLoading)
              const SliverFillRemaining(child: Center(child: CircularProgressIndicator())),
            if (!_isLoading && _error != null)
              SliverFillRemaining(child: AdminErrorRetry(message: _error!, onRetry: _loadErrors)),
            if (!_isLoading && _error == null && _filteredErrors.isEmpty)
              SliverFillRemaining(child: _buildEmptyState()),
            if (!_isLoading && _error == null && _filteredErrors.isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final error = _filteredErrors[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _ErrorCard(
                        error: error,
                        onMarkResolved: () => _markErrorResolved(error['id'] as String),
                        getTimeAgo: _getTimeAgo,
                        getErrorTypeColor: _getErrorTypeColor,
                        getErrorTypeDisplay: _getErrorTypeDisplay,
                      ),
                    );
                  },
                  childCount: _filteredErrors.length,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _selectedStatus == 'unresolved' ? Icons.check_circle_rounded : Icons.search_off_rounded,
            size: 64,
            color: Colors.grey.shade300,
          ),
          const SizedBox(height: 16),
          Text(
            _selectedStatus == 'unresolved' ? 'No unresolved errors!' : 'No errors found',
            style: GoogleFonts.manrope(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _selectedStatus == 'unresolved' 
                ? 'All background processing is working smoothly'
                : 'Try adjusting your filters or search terms',
            style: GoogleFonts.manrope(
              fontSize: 14,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final Color bgColor;

  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: GoogleFonts.manrope(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            Text(
              label,
              style: GoogleFonts.manrope(
                fontSize: 11,
                color: color.withOpacity(0.8),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterTab extends StatelessWidget {
  final String label;
  final int count;
  final bool isActive;
  final VoidCallback onTap;
  final Color color;

  const _FilterTab({
    required this.label,
    required this.count,
    required this.isActive,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? color : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: GoogleFonts.manrope(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isActive ? Colors.white : Colors.grey.shade700,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isActive ? Colors.white.withOpacity(0.3) : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count.toString(),
                style: GoogleFonts.manrope(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: isActive ? Colors.white : Colors.grey.shade600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final Map<String, dynamic> error;
  final VoidCallback onMarkResolved;
  final String Function(DateTime) getTimeAgo;
  final Color Function(String?) getErrorTypeColor;
  final String Function(String?) getErrorTypeDisplay;

  const _ErrorCard({
    required this.error,
    required this.onMarkResolved,
    required this.getTimeAgo,
    required this.getErrorTypeColor,
    required this.getErrorTypeDisplay,
  });

  @override
  Widget build(BuildContext context) {
    final createdAt = DateTime.parse(error['created_at'] as String);
    final isResolved = error['resolved'] as bool? ?? false;
    final orderId = error['order_id'] as String?;
    final errorType = error['error_type'] as String?;
    final errorMessage = error['error_message'] as String? ?? 'Unknown error';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isResolved ? Colors.green.shade200 : Colors.red.shade200,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                // Status indicator
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isResolved ? Colors.green : Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                
                // Error type badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: getErrorTypeColor(errorType).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    getErrorTypeDisplay(errorType),
                    style: GoogleFonts.manrope(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: getErrorTypeColor(errorType),
                    ),
                  ),
                ),
                
                const Spacer(),
                
                // Timestamp
                Text(
                  getTimeAgo(createdAt),
                  style: GoogleFonts.manrope(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 12),
            
            // Error message
            Text(
              errorMessage,
              style: GoogleFonts.manrope(
                fontSize: 13,
                color: Colors.black87,
                fontWeight: FontWeight.w500,
              ),
            ),
            
            // Order ID if available
            if (orderId != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.receipt_long_rounded, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    'Order: ${orderId.split('-').first.toUpperCase()}',
                    style: GoogleFonts.manrope(
                      fontSize: 11,
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
            
            // Action button for unresolved errors
            if (!isResolved) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: onMarkResolved,
                    icon: const Icon(Icons.check_circle_rounded, size: 16),
                    label: const Text('Mark Resolved'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
