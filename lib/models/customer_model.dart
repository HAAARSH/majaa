// CHANGED: Unified profile schema — one row per customer with both team columns.
class CustomerTeamProfile {
  final String id;
  final String customerId;
  final bool teamJa;
  final bool teamMa;
  final String? beatIdJa;
  final String beatNameJa;
  final double outstandingJa;
  final String? beatIdMa;
  final String beatNameMa;
  final double outstandingMa;

  const CustomerTeamProfile({
    required this.id,
    required this.customerId,
    this.teamJa = false,
    this.teamMa = false,
    this.beatIdJa,
    this.beatNameJa = '',
    this.outstandingJa = 0.0,
    this.beatIdMa,
    this.beatNameMa = '',
    this.outstandingMa = 0.0,
  });

  factory CustomerTeamProfile.fromJson(Map<String, dynamic> json) =>
      CustomerTeamProfile(
        id: json['id']?.toString() ?? '',
        customerId: json['customer_id'] as String? ?? '',
        teamJa: json['team_ja'] as bool? ?? false,
        teamMa: json['team_ma'] as bool? ?? false,
        beatIdJa: json['beat_id_ja'] as String?,
        beatNameJa: json['beat_name_ja'] as String? ?? '',
        outstandingJa: (json['outstanding_ja'] as num?)?.toDouble() ?? 0.0,
        beatIdMa: json['beat_id_ma'] as String?,
        beatNameMa: json['beat_name_ma'] as String? ?? '',
        outstandingMa: (json['outstanding_ma'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
        'customer_id': customerId,
        'team_ja': teamJa,
        'team_ma': teamMa,
        'beat_id_ja': beatIdJa,
        'beat_name_ja': beatNameJa,
        'outstanding_ja': outstandingJa,
        'beat_id_ma': beatIdMa,
        'beat_name_ma': beatNameMa,
        'outstanding_ma': outstandingMa,
      };

  /// Helper: does this customer belong to a given team?
  bool belongsToTeam(String team) => team == 'JA' ? teamJa : teamMa;

  /// Helper: beat ID for a given team
  String? beatIdFor(String team) => team == 'JA' ? beatIdJa : beatIdMa;

  /// Helper: beat name for a given team
  String beatNameFor(String team) => team == 'JA' ? beatNameJa : beatNameMa;

  /// Helper: outstanding for a given team
  double outstandingFor(String team) => team == 'JA' ? outstandingJa : outstandingMa;
}

class CustomerModel {
  final String id;
  final String name;
  final String address;
  final String phone;
  final String type;
  final double lastOrderValue;
  final DateTime? lastOrderDate;
  final String deliveryRoute;

  /// Unified profile — one row per customer with both team data.
  /// List kept for backward compatibility but will have at most 1 element.
  final List<CustomerTeamProfile> teamProfiles;

  const CustomerModel({
    required this.id,
    required this.name,
    required this.address,
    required this.phone,
    required this.type,
    required this.lastOrderValue,
    this.lastOrderDate,
    this.deliveryRoute = 'Unassigned',
    this.teamProfiles = const [],
  });

  factory CustomerModel.fromJson(Map<String, dynamic> json) {
    final rawProfiles = json['customer_team_profiles'];
    final List<CustomerTeamProfile> profiles;
    if (rawProfiles is List) {
      profiles = rawProfiles
          .map((p) => CustomerTeamProfile.fromJson(
              Map<String, dynamic>.from(p as Map)))
          .toList();
    } else if (rawProfiles is Map) {
      profiles = [CustomerTeamProfile.fromJson(
          Map<String, dynamic>.from(rawProfiles))];
    } else {
      profiles = [];
    }
    return CustomerModel(
      id: json['id'] as String,
      name: json['name'] as String,
      address: json['address'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      type: json['type'] as String? ?? 'General Trade',
      lastOrderValue: (json['last_order_value'] as num?)?.toDouble() ?? 0.0,
      lastOrderDate: json['last_order_date'] != null
          ? DateTime.tryParse(json['last_order_date'] as String)
          : null,
      deliveryRoute: json['delivery_route'] as String? ?? 'Unassigned',
      teamProfiles: profiles,
    );
  }

  // CHANGED: unified profile helpers — read from single profile row
  CustomerTeamProfile? get _profile => teamProfiles.isNotEmpty ? teamProfiles.first : null;

  /// Outstanding balance for [team].
  double outstandingForTeam(String team) => _profile?.outstandingFor(team) ?? 0.0;

  /// Beat ID for [team].
  String? beatIdForTeam(String team) => _profile?.beatIdFor(team);

  /// Beat display name for [team].
  String beatNameForTeam(String team) => _profile?.beatNameFor(team) ?? '';

  /// Does this customer belong to [team]?
  bool belongsToTeam(String team) => _profile?.belongsToTeam(team) ?? false;

  CustomerModel copyWith({String? phone}) {
    return CustomerModel(
      id: id,
      name: name,
      address: address,
      phone: phone ?? this.phone,
      type: type,
      lastOrderValue: lastOrderValue,
      lastOrderDate: lastOrderDate,
      deliveryRoute: deliveryRoute,
      teamProfiles: teamProfiles,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'phone': phone,
        'type': type,
        'last_order_value': lastOrderValue,
        'last_order_date': lastOrderDate?.toIso8601String(),
        'delivery_route': deliveryRoute,
      };
}
