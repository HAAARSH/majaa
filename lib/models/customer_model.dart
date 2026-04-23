// CHANGED: Unified profile schema — one row per customer with both team columns.
class CustomerTeamProfile {
  final String id;
  final String customerId;
  final bool teamJa;
  final bool teamMa;
  final String? beatIdJa;
  final String beatNameJa;
  final double outstandingJa;
  final double creditNotesJa;
  final double currentYearBilledJa;
  final String? beatIdMa;
  final String beatNameMa;
  final double outstandingMa;
  final double creditNotesMa;
  final double currentYearBilledMa;
  // Manual ordering-beat override. Non-null means admin set a different beat
  // for the rep's ordering route (customer appears on this beat's list for
  // order-taking). Collection / outstanding always use the ACMAST-synced
  // beat above. Null means no override — ordering uses the primary beat too.
  final String? orderBeatIdJa;
  final String orderBeatNameJa;
  final String? orderBeatIdMa;
  final String orderBeatNameMa;

  // Manual order blocks (per-team). See
  // 20260424000001_customer_block_flags.sql.
  final bool orderBlockedJa;
  final bool orderBlockedMa;
  final String? orderBlockReasonJa;
  final String? orderBlockReasonMa;
  final DateTime? orderBlockSetAtJa;
  final DateTime? orderBlockSetAtMa;
  final String? orderBlockSetByJa; // app_users.id
  final String? orderBlockSetByMa;

  const CustomerTeamProfile({
    required this.id,
    required this.customerId,
    this.teamJa = false,
    this.teamMa = false,
    this.beatIdJa,
    this.beatNameJa = '',
    this.outstandingJa = 0.0,
    this.creditNotesJa = 0.0,
    this.currentYearBilledJa = 0.0,
    this.beatIdMa,
    this.beatNameMa = '',
    this.outstandingMa = 0.0,
    this.creditNotesMa = 0.0,
    this.currentYearBilledMa = 0.0,
    this.orderBeatIdJa,
    this.orderBeatNameJa = '',
    this.orderBeatIdMa,
    this.orderBeatNameMa = '',
    this.orderBlockedJa = false,
    this.orderBlockedMa = false,
    this.orderBlockReasonJa,
    this.orderBlockReasonMa,
    this.orderBlockSetAtJa,
    this.orderBlockSetAtMa,
    this.orderBlockSetByJa,
    this.orderBlockSetByMa,
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
        creditNotesJa: (json['credit_notes_ja'] as num?)?.toDouble() ?? 0.0,
        currentYearBilledJa: (json['current_year_billed_ja'] as num?)?.toDouble() ?? 0.0,
        beatIdMa: json['beat_id_ma'] as String?,
        beatNameMa: json['beat_name_ma'] as String? ?? '',
        outstandingMa: (json['outstanding_ma'] as num?)?.toDouble() ?? 0.0,
        creditNotesMa: (json['credit_notes_ma'] as num?)?.toDouble() ?? 0.0,
        currentYearBilledMa: (json['current_year_billed_ma'] as num?)?.toDouble() ?? 0.0,
        orderBeatIdJa: json['order_beat_id_ja'] as String?,
        orderBeatNameJa: json['order_beat_name_ja'] as String? ?? '',
        orderBeatIdMa: json['order_beat_id_ma'] as String?,
        orderBeatNameMa: json['order_beat_name_ma'] as String? ?? '',
        orderBlockedJa: json['order_blocked_ja'] as bool? ?? false,
        orderBlockedMa: json['order_blocked_ma'] as bool? ?? false,
        orderBlockReasonJa: json['order_block_reason_ja'] as String?,
        orderBlockReasonMa: json['order_block_reason_ma'] as String?,
        orderBlockSetAtJa: json['order_block_set_at_ja'] == null
            ? null
            : DateTime.tryParse(json['order_block_set_at_ja'].toString()),
        orderBlockSetAtMa: json['order_block_set_at_ma'] == null
            ? null
            : DateTime.tryParse(json['order_block_set_at_ma'].toString()),
        orderBlockSetByJa: json['order_block_set_by_ja'] as String?,
        orderBlockSetByMa: json['order_block_set_by_ma'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'customer_id': customerId,
        'team_ja': teamJa,
        'team_ma': teamMa,
        'beat_id_ja': beatIdJa,
        'beat_name_ja': beatNameJa,
        'outstanding_ja': outstandingJa,
        'credit_notes_ja': creditNotesJa,
        'current_year_billed_ja': currentYearBilledJa,
        'beat_id_ma': beatIdMa,
        'beat_name_ma': beatNameMa,
        'outstanding_ma': outstandingMa,
        'credit_notes_ma': creditNotesMa,
        'current_year_billed_ma': currentYearBilledMa,
        'order_beat_id_ja': orderBeatIdJa,
        'order_beat_name_ja': orderBeatNameJa,
        'order_beat_id_ma': orderBeatIdMa,
        'order_beat_name_ma': orderBeatNameMa,
        // 2026-04-24 order-block fields. Missing from toJson earlier
        // meant any profile round-trip (fromJson → toJson → upsert)
        // would silently clear the block flags. Covered now.
        'order_blocked_ja': orderBlockedJa,
        'order_blocked_ma': orderBlockedMa,
        'order_block_reason_ja': orderBlockReasonJa,
        'order_block_reason_ma': orderBlockReasonMa,
        'order_block_set_at_ja': orderBlockSetAtJa?.toIso8601String(),
        'order_block_set_at_ma': orderBlockSetAtMa?.toIso8601String(),
        'order_block_set_by_ja': orderBlockSetByJa,
        'order_block_set_by_ma': orderBlockSetByMa,
      };

  /// Helper: does this customer belong to a given team?
  bool belongsToTeam(String team) => team == 'JA' ? teamJa : teamMa;

  /// Helper: beat ID for a given team (the ACMAST/collection beat).
  String? beatIdFor(String team) => team == 'JA' ? beatIdJa : beatIdMa;

  /// Helper: beat name for a given team (the ACMAST/collection beat).
  String beatNameFor(String team) => team == 'JA' ? beatNameJa : beatNameMa;

  /// Manual ordering-beat override for a given team. Null means no override.
  String? orderBeatIdFor(String team) =>
      team == 'JA' ? orderBeatIdJa : orderBeatIdMa;

  /// Manual ordering-beat display name for a given team.
  String orderBeatNameFor(String team) =>
      team == 'JA' ? orderBeatNameJa : orderBeatNameMa;

  /// Helper: outstanding for a given team
  double outstandingFor(String team) => team == 'JA' ? outstandingJa : outstandingMa;

  /// Helper: credit notes for a given team
  double creditNotesFor(String team) => team == 'JA' ? creditNotesJa : creditNotesMa;

  /// Helper: current year billed for a given team
  double currentYearBilledFor(String team) => team == 'JA' ? currentYearBilledJa : currentYearBilledMa;

  /// Admin-set manual block for [team]. When true, reps cannot create
  /// new orders for this customer on [team] regardless of outstanding /
  /// overdue state. Auto-block thresholds are separate (BillingRules).
  bool orderBlockedFor(String team) =>
      team == 'JA' ? orderBlockedJa : orderBlockedMa;

  /// Block reason for [team] when orderBlockedFor(team) is true.
  String? orderBlockReasonFor(String team) =>
      team == 'JA' ? orderBlockReasonJa : orderBlockReasonMa;
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
  final String? accCodeJa; // Billing software account code from JA ACMAST
  final String? accCodeMa; // Billing software account code from MA ACMAST
  final String? gstin;     // GSTIN from ACMAST
  final bool lockBill;     // Whether customer is bill-locked in billing software
  final int creditDays;    // Credit period allowed (days)
  final double creditLimit; // Credit limit from billing software

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
    this.accCodeJa,
    this.accCodeMa,
    this.gstin,
    this.lockBill = false,
    this.creditDays = 0,
    this.creditLimit = 0,
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
      accCodeJa: json['acc_code_ja'] as String?,
      accCodeMa: json['acc_code_ma'] as String?,
      gstin: json['gstin'] as String?,
      lockBill: json['lock_bill'] as bool? ?? false,
      creditDays: json['credit_days'] as int? ?? 0,
      creditLimit: (json['credit_limit'] as num?)?.toDouble() ?? 0,
      teamProfiles: profiles,
    );
  }

  // CHANGED: unified profile helpers — read from single profile row
  CustomerTeamProfile? get _profile => teamProfiles.isNotEmpty ? teamProfiles.first : null;

  /// Outstanding balance for [team].
  double outstandingForTeam(String team) => _profile?.outstandingFor(team) ?? 0.0;

  /// Credit notes for [team].
  double creditNotesForTeam(String team) => _profile?.creditNotesFor(team) ?? 0.0;

  /// Current year billed for [team].
  double currentYearBilledForTeam(String team) => _profile?.currentYearBilledFor(team) ?? 0.0;

  /// Primary beat ID for [team] — the ACMAST-synced collection/billing beat.
  /// Use this for outstanding reports, collection flows, and Next-Day-Due.
  String? beatIdForTeam(String team) => _profile?.beatIdFor(team);

  /// Primary beat display name for [team].
  String beatNameForTeam(String team) => _profile?.beatNameFor(team) ?? '';

  /// Manual ordering-beat override for [team]. Null if no override (ordering
  /// uses primary). Use this to decide which beat's customer list a customer
  /// should appear on for order-taking.
  String? orderBeatIdOverrideForTeam(String team) =>
      _profile?.orderBeatIdFor(team);

  /// Effective beat ID used when deciding whether a customer appears on a
  /// beat's customer list for ORDERING. Falls back to primary when override
  /// is null — i.e. same as today's behavior for customers without a split.
  String? effectiveOrderBeatIdForTeam(String team) =>
      _profile?.orderBeatIdFor(team) ?? _profile?.beatIdFor(team);

  /// True if admin has explicitly set a different ordering beat for this
  /// team. Used by the customer list + beat counters to know the customer
  /// should appear under two different beats (primary for collection,
  /// override for ordering).
  bool hasOrderBeatOverrideForTeam(String team) {
    final override = _profile?.orderBeatIdFor(team);
    return override != null && override.isNotEmpty;
  }

  /// Does this customer belong to [team]?
  bool belongsToTeam(String team) => _profile?.belongsToTeam(team) ?? false;

  /// True when admin has manually blocked this customer's orders on [team].
  bool isOrderBlockedFor(String team) =>
      _profile?.orderBlockedFor(team) ?? false;

  /// Reason admin gave for the block on [team], if any.
  String? orderBlockReasonFor(String team) =>
      _profile?.orderBlockReasonFor(team);

  CustomerModel copyWith({String? phone}) {
    return CustomerModel(
      id: id,
      name: name,
      address: address,
      phone: phone ?? this.phone,
      accCodeJa: accCodeJa,
      accCodeMa: accCodeMa,
      gstin: gstin,
      lockBill: lockBill,
      creditDays: creditDays,
      creditLimit: creditLimit,
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
        if (accCodeJa != null) 'acc_code_ja': accCodeJa,
        if (accCodeMa != null) 'acc_code_ma': accCodeMa,
        if (gstin != null) 'gstin': gstin,
        'lock_bill': lockBill,
        'credit_days': creditDays,
        'credit_limit': creditLimit,
      };
}
