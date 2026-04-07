class BillExtractionModel {
  final String id;
  final String billNo;
  final DateTime? billDate;
  final String? customerNameOcr;
  final String? customerId;
  final bool customerMatched;
  final double? subtotal;
  final double? cgstTotal;
  final double? sgstTotal;
  final double? grandTotal;
  final String? orderId;
  final bool orderMatched;
  final bool autoVerified;
  final String teamId;
  final DateTime createdAt;
  final List<BilledItemModel> items;

  const BillExtractionModel({
    required this.id,
    required this.billNo,
    this.billDate,
    this.customerNameOcr,
    this.customerId,
    this.customerMatched = false,
    this.subtotal,
    this.cgstTotal,
    this.sgstTotal,
    this.grandTotal,
    this.orderId,
    this.orderMatched = false,
    this.autoVerified = false,
    required this.teamId,
    required this.createdAt,
    this.items = const [],
  });

  factory BillExtractionModel.fromJson(Map<String, dynamic> json) {
    final rawItems = json['order_billed_items'] as List?;
    return BillExtractionModel(
      id: json['id'] as String,
      billNo: json['bill_no'] as String,
      billDate: json['bill_date'] != null ? DateTime.tryParse(json['bill_date'] as String) : null,
      customerNameOcr: json['customer_name_ocr'] as String?,
      customerId: json['customer_id'] as String?,
      customerMatched: json['customer_matched'] as bool? ?? false,
      subtotal: (json['subtotal'] as num?)?.toDouble(),
      cgstTotal: (json['cgst_total'] as num?)?.toDouble(),
      sgstTotal: (json['sgst_total'] as num?)?.toDouble(),
      grandTotal: (json['grand_total'] as num?)?.toDouble(),
      orderId: json['order_id'] as String?,
      orderMatched: json['order_matched'] as bool? ?? false,
      autoVerified: json['auto_verified'] as bool? ?? false,
      teamId: json['team_id'] as String? ?? 'JA',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      items: rawItems != null
          ? rawItems.map((e) => BilledItemModel.fromJson(Map<String, dynamic>.from(e))).toList()
          : [],
    );
  }
}

class BilledItemModel {
  final String id;
  final String? billExtractionId;
  final String? orderId;
  final String? billNo;
  final String? productId;
  final String billedItemName;
  final String? hsnCode;
  final double? mrp;
  final double? gstRate;
  final double? quantity;
  final double? rate;
  final double? discountPercent;
  final double? amount;
  final bool matched;
  final String teamId;

  const BilledItemModel({
    required this.id,
    this.billExtractionId,
    this.orderId,
    this.billNo,
    this.productId,
    required this.billedItemName,
    this.hsnCode,
    this.mrp,
    this.gstRate,
    this.quantity,
    this.rate,
    this.discountPercent,
    this.amount,
    this.matched = false,
    required this.teamId,
  });

  factory BilledItemModel.fromJson(Map<String, dynamic> json) => BilledItemModel(
    id: json['id'] as String? ?? '',
    billExtractionId: json['bill_extraction_id'] as String?,
    orderId: json['order_id'] as String?,
    billNo: json['bill_no'] as String?,
    productId: json['product_id'] as String?,
    billedItemName: json['billed_item_name'] as String? ?? '',
    hsnCode: json['hsn_code'] as String?,
    mrp: (json['mrp'] as num?)?.toDouble(),
    gstRate: (json['gst_rate'] as num?)?.toDouble(),
    quantity: (json['quantity'] as num?)?.toDouble(),
    rate: (json['rate'] as num?)?.toDouble(),
    discountPercent: (json['discount_percent'] as num?)?.toDouble(),
    amount: (json['amount'] as num?)?.toDouble(),
    matched: json['matched'] as bool? ?? false,
    teamId: json['team_id'] as String? ?? 'JA',
  );
}
