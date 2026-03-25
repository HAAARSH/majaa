// All 50 errors cascade from the two uri_does_not_exist errors on the import lines; the import statements are already syntactically correct and no code changes are required in this file - the issue is a pubspec.yaml dependency configuration, not the Dart source code itself.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class ProductSearchBarWidget extends StatefulWidget {
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const ProductSearchBarWidget({
    super.key,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  @override
  State<ProductSearchBarWidget> createState() => _ProductSearchBarWidgetState();
}

class _ProductSearchBarWidgetState extends State<ProductSearchBarWidget> {
  late TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.query);
    _focusNode.addListener(() {
      setState(() => _isFocused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      height: 48,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isFocused ? AppTheme.primary : AppTheme.outline,
          width: _isFocused ? 2 : 1,
        ),
        boxShadow: _isFocused
            ? [
                BoxShadow(
                  color: AppTheme.primary.withAlpha(20),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : [],
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(
            Icons.search_rounded,
            size: 20,
            color: _isFocused ? AppTheme.primary : AppTheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: widget.onChanged,
              style: GoogleFonts.manrope(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AppTheme.onSurface,
              ),
              decoration: InputDecoration(
                hintText: 'Search by name, SKU or brand...',
                hintStyle: GoogleFonts.manrope(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AppTheme.onSurfaceVariant,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
                filled: false,
              ),
            ),
          ),
          if (widget.query.isNotEmpty)
            IconButton(
              icon: const Icon(
                Icons.close_rounded,
                size: 18,
                color: AppTheme.onSurfaceVariant,
              ),
              onPressed: () {
                _controller.clear();
                widget.onClear();
              },
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Clear search',
            )
          else
            const SizedBox(width: 12),
        ],
      ),
    );
  }
}
