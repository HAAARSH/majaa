import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// A widget that wraps a ListView and adds an alphabetic scroll bar on the right.
/// When tapping/dragging on a letter, scrolls to the first item starting with that letter.
class AlphabetScrollList extends StatefulWidget {
  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final String Function(int index) labelForIndex;
  final EdgeInsets? padding;
  final Future<void> Function()? onRefresh;

  const AlphabetScrollList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.labelForIndex,
    this.padding,
    this.onRefresh,
  });

  @override
  State<AlphabetScrollList> createState() => _AlphabetScrollListState();
}

class _AlphabetScrollListState extends State<AlphabetScrollList> {
  final ScrollController _scrollController = ScrollController();
  String? _activeLetter;
  // Estimated item height for scroll calculation
  static const double _estimatedItemHeight = 80;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<String> get _availableLetters {
    final letters = <String>{};
    for (int i = 0; i < widget.itemCount; i++) {
      final label = widget.labelForIndex(i);
      if (label.isNotEmpty) {
        final first = label[0].toUpperCase();
        if (RegExp(r'[A-Z]').hasMatch(first)) {
          letters.add(first);
        } else {
          letters.add('#');
        }
      }
    }
    return letters.toList()..sort();
  }

  void _scrollToLetter(String letter) {
    for (int i = 0; i < widget.itemCount; i++) {
      final label = widget.labelForIndex(i);
      if (label.isEmpty) continue;
      final first = label[0].toUpperCase();
      final matches = letter == '#'
          ? !RegExp(r'[A-Z]').hasMatch(first)
          : first == letter;
      if (matches) {
        final offset = (i * _estimatedItemHeight).clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        );
        _scrollController.animateTo(offset,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut);
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount < 40) {
      // Not enough items — just show plain list
      final list = ListView.builder(
        controller: _scrollController,
        padding: widget.padding,
        itemCount: widget.itemCount,
        itemBuilder: widget.itemBuilder,
      );
      return widget.onRefresh != null
          ? RefreshIndicator(onRefresh: widget.onRefresh!, child: list)
          : list;
    }

    final letters = _availableLetters;

    return Stack(
      children: [
        // Main list
        widget.onRefresh != null
            ? RefreshIndicator(
                onRefresh: widget.onRefresh!,
                child: ListView.builder(
                  controller: _scrollController,
                  padding: widget.padding?.copyWith(right: (widget.padding?.right ?? 16) + 20),
                  itemCount: widget.itemCount,
                  itemBuilder: widget.itemBuilder,
                ),
              )
            : ListView.builder(
                controller: _scrollController,
                padding: widget.padding?.copyWith(right: (widget.padding?.right ?? 16) + 20),
                itemCount: widget.itemCount,
                itemBuilder: widget.itemBuilder,
              ),

        // Alphabet bar on right
        Positioned(
          right: 2,
          top: 8,
          bottom: 8,
          child: GestureDetector(
            onVerticalDragUpdate: (details) {
              final box = context.findRenderObject() as RenderBox;
              final localY = details.localPosition.dy - 8;
              final totalHeight = box.size.height - 16;
              final idx = (localY / totalHeight * letters.length).clamp(0, letters.length - 1).toInt();
              final letter = letters[idx];
              if (letter != _activeLetter) {
                setState(() => _activeLetter = letter);
                _scrollToLetter(letter);
              }
            },
            onVerticalDragEnd: (_) => setState(() => _activeLetter = null),
            onTapUp: (details) {
              final box = context.findRenderObject() as RenderBox;
              final localY = details.localPosition.dy - 8;
              final totalHeight = box.size.height - 16;
              final idx = (localY / totalHeight * letters.length).clamp(0, letters.length - 1).toInt();
              _scrollToLetter(letters[idx]);
              setState(() => _activeLetter = letters[idx]);
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted) setState(() => _activeLetter = null);
              });
            },
            child: Container(
              width: 18,
              decoration: BoxDecoration(
                color: Colors.grey.shade100.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: letters.map((letter) {
                  final isActive = _activeLetter == letter;
                  return Text(
                    letter,
                    style: GoogleFonts.manrope(
                      fontSize: letters.length > 20 ? 8 : 10,
                      fontWeight: isActive ? FontWeight.w900 : FontWeight.w600,
                      color: isActive ? AppTheme.primary : AppTheme.onSurfaceVariant,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),

        // Active letter overlay
        if (_activeLetter != null)
          Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(
                _activeLetter!,
                style: GoogleFonts.manrope(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }
}
