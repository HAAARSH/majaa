import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import '../services/supabase_service.dart';
import '../services/hero_cache_service.dart';
import '../theme/app_theme.dart';

/// Modal for capturing hero selfie during first login for sales/delivery reps
/// Non-dismissible modal that forces user to take a selfie
class HeroSelfieModal extends StatefulWidget {
  final String userId;
  final String fullName;
  final VoidCallback onSuccess;

  const HeroSelfieModal({
    super.key,
    required this.userId,
    required this.fullName,
    required this.onSuccess,
  });

  @override
  State<HeroSelfieModal> createState() => _HeroSelfieModalState();
}

class _HeroSelfieModalState extends State<HeroSelfieModal> {
  bool _isCapturing = false;
  bool _isUploading = false;
  String? _errorMessage;
  XFile? _capturedImage;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent dismissal
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.all(20),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(),
                const SizedBox(height: 16),
                _buildContent(),
                const SizedBox(height: 16),
                _buildActions(),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  _buildErrorMessage(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Icon(
          Icons.camera_alt_rounded,
          size: 48,
          color: const Color(0xFFFFD700), // Gold color for "Hero" theme
        ),
        const SizedBox(height: 12),
        Text(
          'Hero Selfie Required',
          style: GoogleFonts.manrope(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppTheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildContent() {
    return Column(
      children: [
        Text(
          'Welcome ${widget.fullName}! 👋',
          style: GoogleFonts.manrope(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppTheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'Take a quick selfie for your profile badge.',
          style: GoogleFonts.manrope(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: AppTheme.onSurfaceVariant,
            height: 1.4,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        _buildImagePreview(),
      ],
    );
  }

  Widget _buildImagePreview() {
    if (_capturedImage != null) {
      return Container(
        width: 150,
        height: 150,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFFFFD700),
            width: 3,
          ),
        ),
        child: ClipOval(
          child: FutureBuilder<List<int>>(
            future: _capturedImage!.readAsBytes(),
            builder: (ctx, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              return Image.memory(Uint8List.fromList(snap.data!), fit: BoxFit.cover, width: 144, height: 144);
            },
          ),
        ),
      );
    }

    return Container(
      width: 200,
      height: 200,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.surfaceVariant,
        border: Border.all(
          color: AppTheme.outline,
          width: 2,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.camera_alt_outlined,
            size: 48,
            color: AppTheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            'No photo captured',
            style: GoogleFonts.manrope(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppTheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        if (_capturedImage == null) ...[
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isCapturing ? null : _captureSelfie,
              icon: const Icon(Icons.camera_alt_rounded, size: 18),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              label: _isCapturing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Text(
                      'Camera',
                      style: GoogleFonts.manrope(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isCapturing ? null : _pickFromGallery,
              icon: const Icon(Icons.photo_library_rounded, size: 18),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              label: Text(
                'Gallery',
                style: GoogleFonts.manrope(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ] else ...[
          Expanded(
            child: OutlinedButton(
              onPressed: _isUploading ? null : _retakePhoto,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.onSurface,
                side: BorderSide(color: AppTheme.outline),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                'Retake',
                style: GoogleFonts.manrope(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: _isUploading ? null : _uploadSelfie,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFD700), // Gold color
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _isUploading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                      ),
                    )
                  : Text(
                      'Upload & Continue',
                      style: GoogleFonts.manrope(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.error.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.error.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: AppTheme.error,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: GoogleFonts.manrope(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppTheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFromGallery() async {
    setState(() {
      _isCapturing = true;
      _errorMessage = null;
    });
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 800,
        maxHeight: 800,
      );
      if (photo != null) {
        setState(() {
          _capturedImage = photo;
          _errorMessage = null;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to pick photo. Please try again.';
      });
    } finally {
      setState(() => _isCapturing = false);
    }
  }

  Future<void> _captureSelfie() async {
    setState(() {
      _isCapturing = true;
      _errorMessage = null;
    });

    try {
      final ImagePicker picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.camera, // On web: shows "Take Photo" or "Photo Library" menu on iOS
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 85,
        maxWidth: 800,
        maxHeight: 800,
      );

      if (photo != null) {
        setState(() {
          _capturedImage = photo;
          _errorMessage = null;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to capture photo. Please try again.';
      });
    } finally {
      setState(() {
        _isCapturing = false;
      });
    }
  }

  void _retakePhoto() {
    setState(() {
      _capturedImage = null;
      _errorMessage = null;
    });
  }

  Future<void> _uploadSelfie() async {
    if (_capturedImage == null) return;

    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      // Upload to Supabase Storage (works without Google auth)
      final imageBytes = await _capturedImage!.readAsBytes();
      final imageUrl = await SupabaseService.instance.uploadHeroAvatarToStorage(
        widget.userId,
        imageBytes.toList(),
      );

      if (imageUrl == null) {
        setState(() {
          _isUploading = false;
          _errorMessage = 'Upload failed. Please check your internet connection and try again.';
        });
        return;
      }

      // Cache locally for fast loading
      try {
        await HeroCacheService.instance.cacheImage(imageUrl, imageBytes);
      } catch (_) {}

      setState(() => _isUploading = false);
      widget.onSuccess();
    } catch (e) {
      setState(() {
        _isUploading = false;
        _errorMessage = 'Upload failed: $e';
      });
    }
  }
}
