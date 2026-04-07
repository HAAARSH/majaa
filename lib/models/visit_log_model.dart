class VisitLogModel {
  final String id;
  final String customerId;
  final String customerName;
  final String beatId;
  final String beatName;
  final String reason;
  final String repEmail;
  final String? userId;
  final String teamId;
  final DateTime createdAt;
  final DateTime? visitDate;
  final String? visitTime;
  final String? notes;

  const VisitLogModel({
    required this.id, required this.customerId, required this.customerName,
    required this.beatId, required this.beatName, required this.reason,
    required this.repEmail, this.userId, required this.teamId, required this.createdAt,
    this.visitDate, this.visitTime, this.notes,
  });

  factory VisitLogModel.fromJson(Map<String, dynamic> json) {
    final customerMap = json['customers'] as Map<String, dynamic>?;
    final beatMap = json['beats'] as Map<String, dynamic>?;
    return VisitLogModel(
      id: json['id'] as String? ?? '',
      customerId: json['customer_id'] as String? ?? '',
      customerName: customerMap?['name'] as String? ?? 'Unknown Customer',
      beatId: json['beat_id'] as String? ?? '',
      beatName: beatMap?['beat_name'] as String? ?? 'Unknown Beat',
      reason: json['reason'] as String? ?? '',
      repEmail: json['rep_email'] as String? ?? '',
      userId: json['user_id'] as String?,
      teamId: json['team_id'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      visitDate: json['visit_date'] != null ? DateTime.tryParse(json['visit_date'] as String) : null,
      visitTime: json['visit_time'] as String?,
      notes: json['notes'] as String?,
    );
  }
}
