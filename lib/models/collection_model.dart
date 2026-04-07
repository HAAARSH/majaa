class CollectionModel {
  final String id;
  final String? billNo;
  final String customerId;
  final String customerName;
  final double amountCollected;
  final double balanceRemaining;
  final double outstandingBefore;
  final double outstandingAfter;
  final String paymentMode; // Cash / UPI / Cheque / Bank Transfer
  final String? chequeNumber;
  final String? upiTransactionId;
  final String repEmail;
  final String? collectedBy; // auth.users UUID
  final String? billPhotoUrl;
  final String? driveFileId;
  final String notes;
  final String teamId;
  final DateTime createdAt;
  final DateTime? collectionDate;

  const CollectionModel({
    required this.id,
    this.billNo,
    required this.customerId,
    required this.customerName,
    required this.amountCollected,
    required this.balanceRemaining,
    this.outstandingBefore = 0.0,
    this.outstandingAfter = 0.0,
    this.paymentMode = 'Cash',
    this.chequeNumber,
    this.upiTransactionId,
    required this.repEmail,
    this.collectedBy,
    this.billPhotoUrl,
    this.driveFileId,
    this.notes = '',
    required this.teamId,
    required this.createdAt,
    this.collectionDate,
  });

  factory CollectionModel.fromJson(Map<String, dynamic> json) => CollectionModel(
    id: json['id'] as String,
    billNo: json['bill_no'] as String?,
    customerId: json['customer_id'] as String? ?? '',
    customerName: json['customer_name'] as String? ?? '',
    // Support both old column (amount_paid) and new column (amount_collected)
    amountCollected: (json['amount_collected'] as num?)?.toDouble()
        ?? (json['amount_paid'] as num?)?.toDouble() ?? 0.0,
    balanceRemaining: (json['balance_remaining'] as num?)?.toDouble() ?? 0.0,
    outstandingBefore: (json['outstanding_before'] as num?)?.toDouble() ?? 0.0,
    outstandingAfter: (json['outstanding_after'] as num?)?.toDouble() ?? 0.0,
    // Support both old column (payment_method) and new column (payment_mode)
    paymentMode: json['payment_mode'] as String?
        ?? json['payment_method'] as String? ?? 'Cash',
    chequeNumber: json['cheque_number'] as String?,
    upiTransactionId: json['upi_transaction_id'] as String?,
    repEmail: json['rep_email'] as String? ?? '',
    collectedBy: json['collected_by'] as String?,
    billPhotoUrl: json['bill_photo_url'] as String?,
    driveFileId: json['drive_file_id'] as String?,
    notes: json['notes'] as String? ?? '',
    teamId: json['team_id'] as String? ?? 'JA',
    createdAt: json['created_at'] != null
        ? DateTime.parse(json['created_at'] as String)
        : DateTime.now(),
    collectionDate: json['collection_date'] != null
        ? DateTime.tryParse(json['collection_date'] as String)
        : null,
  );

  Map<String, dynamic> toJson() => {
    'bill_no': billNo,
    'customer_id': customerId,
    'customer_name': customerName,
    'amount_collected': amountCollected,
    'amount_paid': amountCollected, // backward compat
    'balance_remaining': balanceRemaining,
    'outstanding_before': outstandingBefore,
    'outstanding_after': outstandingAfter,
    'payment_mode': paymentMode,
    'payment_method': paymentMode, // backward compat
    if (chequeNumber != null) 'cheque_number': chequeNumber,
    if (upiTransactionId != null) 'upi_transaction_id': upiTransactionId,
    'rep_email': repEmail,
    if (collectedBy != null) 'collected_by': collectedBy,
    if (billPhotoUrl != null) 'bill_photo_url': billPhotoUrl,
    if (driveFileId != null) 'drive_file_id': driveFileId,
    'notes': notes,
    'team_id': teamId,
    'collection_date': collectionDate?.toIso8601String().substring(0, 10),
  };
}
