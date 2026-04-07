import 'beat_model.dart';

class AppUserModel {
  final String id;
  final String email;
  final String fullName;
  final String role;
  final bool isActive;
  final List<BeatModel> assignedBeats;
  final String teamId;
  final String upiId;
  final String? heroImageUrl;

  const AppUserModel({
    required this.id, required this.email, required this.fullName,
    required this.role, required this.isActive, this.assignedBeats = const [],
    required this.teamId, required this.upiId, this.heroImageUrl,
  });

  factory AppUserModel.fromJson(Map<String, dynamic> json) => AppUserModel(
    id: json['id'] as String,
    email: json['email'] as String,
    fullName: json['full_name'] as String? ?? '',
    role: json['role'] as String? ?? 'sales_rep',
    isActive: json['is_active'] as bool? ?? true,
    teamId: json['team_id'] as String? ?? 'JA',
    upiId: json['upi_id'] as String? ?? '',
    heroImageUrl: json['hero_image_url'] as String?,
    assignedBeats: (json['assigned_beats'] as List?)?.map((e) => BeatModel.fromJson(e)).toList() ?? [],
  );

  AppUserModel copyWith({List<BeatModel>? assignedBeats, String? heroImageUrl}) => AppUserModel(
    id: id, email: email, fullName: fullName, role: role, isActive: isActive,
    assignedBeats: assignedBeats ?? this.assignedBeats, teamId: teamId, upiId: upiId,
    heroImageUrl: heroImageUrl ?? this.heroImageUrl,
  );
}
