import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/hero_cache_service.dart';
import '../theme/app_theme.dart';

/// Widget to display user's hero avatar with gold/yellow border
/// Uses HeroCacheService for efficient image loading and caching
class HeroAvatarWidget extends StatefulWidget {
  final String? imageUrl;
  final double radius;
  final String? initials;

  const HeroAvatarWidget({
    super.key,
    this.imageUrl,
    this.radius = 24.0,
    this.initials,
  });

  @override
  State<HeroAvatarWidget> createState() => _HeroAvatarWidgetState();
}

class _HeroAvatarWidgetState extends State<HeroAvatarWidget> {
  Uint8List? _imageBytes;
  bool _isLoading = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(HeroAvatarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      setState(() {
        _imageBytes = null;
        _isLoading = false;
        _hasError = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final imageBytes = await HeroCacheService.instance.getImage(widget.imageUrl!);
      if (mounted) {
        setState(() {
          _imageBytes = imageBytes;
          _isLoading = false;
          _hasError = imageBytes == null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0xFFFFD700), // Gold color for "Hero" feel
          width: 2.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFFD700).withOpacity(0.3),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: CircleAvatar(
        radius: widget.radius,
        backgroundColor: AppTheme.surface,
        backgroundImage: _imageBytes != null
            ? MemoryImage(_imageBytes!)
            : null,
        child: _buildChild(),
      ),
    );
  }

  Widget _buildChild() {
    if (_isLoading) {
      return SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: const Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primary),
          ),
        ),
      );
    }

    if (_hasError || _imageBytes == null) {
      return _buildInitials();
    }

    return const SizedBox.shrink(); // Image is loaded via backgroundImage
  }

  Widget _buildInitials() {
    String initials = widget.initials ?? 'U';
    if (initials.length > 2) {
      initials = initials.substring(0, 2).toUpperCase();
    }

    return Text(
      initials,
      style: GoogleFonts.manrope(
        fontSize: widget.radius * 0.8,
        fontWeight: FontWeight.w600,
        color: AppTheme.onSurface,
      ),
    );
  }
}
