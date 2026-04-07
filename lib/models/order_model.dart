class OrderModel {
  final String id;
  final String? customerId;
  final String customerName;
  final String beat;
  final DateTime orderDate;
  final DateTime? deliveryDate;
  final double subtotal;
  final double vat;
  final double grandTotal;
  final int itemCount;
  final int totalUnits;
  final String status;
  final String? notes;
  final List<OrderItemModel> lineItems;
  final String teamId;
  final String? finalBillNo;
  final double? actualBilledAmount;
  final String? billPhotoUrl;
  final bool verifiedByDelivery;
  final bool verifiedByOffice;
  final bool billVerified;
  // Stage 1: delivery rep OCR values
  final String? preliminaryBillNo;
  final double? preliminaryAmount;

  const OrderModel({
    required this.id, this.customerId, required this.customerName, required this.beat,
    required this.orderDate, this.deliveryDate, required this.subtotal, required this.vat,
    required this.grandTotal, required this.itemCount, required this.totalUnits,
    required this.status, this.notes, this.lineItems = const [], required this.teamId,
    this.finalBillNo, this.actualBilledAmount,
    this.billPhotoUrl, this.verifiedByDelivery = false, this.verifiedByOffice = false,
    this.billVerified = false, this.preliminaryBillNo, this.preliminaryAmount,
  });

  factory OrderModel.fromJson(Map<String, dynamic> json) => OrderModel(
    id: json['id'] as String,
    customerId: json['customer_id'] as String?,
    customerName: json['customer_name'] as String,
    beat: json['beat_name'] as String? ?? '',
    orderDate: DateTime.parse(json['order_date'] as String),
    deliveryDate: json['delivery_date'] != null ? DateTime.tryParse(json['delivery_date'] as String) : null,
    subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0.0,
    vat: (json['vat'] as num?)?.toDouble() ?? 0.0,
    grandTotal: (json['grand_total'] as num?)?.toDouble() ?? 0.0,
    itemCount: json['item_count'] as int? ?? 0,
    totalUnits: json['total_units'] as int? ?? 0,
    status: json['status'] as String? ?? 'Pending',
    notes: json['notes'] as String?,
    lineItems: (json['order_items'] as List<dynamic>?)?.map((e) => OrderItemModel.fromJson(Map<String, dynamic>.from(e))).toList() ?? [],
    teamId: json['team_id'] as String? ?? 'JA',
    finalBillNo: json['final_bill_no'] as String?,
    actualBilledAmount: (json['actual_billed_amount'] as num?)?.toDouble(),
    billPhotoUrl: json['bill_photo_url'] as String?,
    verifiedByDelivery: json['verified_by_delivery'] as bool? ?? false,
    verifiedByOffice: json['verified_by_office'] as bool? ?? false,
    billVerified: json['bill_verified'] as bool? ?? false,
    preliminaryBillNo: json['preliminary_bill_no'] as String?,
    preliminaryAmount: (json['preliminary_amount'] as num?)?.toDouble(),
  );

  OrderModel copyWithStatus(String newStatus) => OrderModel(
    id: id, customerId: customerId, customerName: customerName, beat: beat,
    orderDate: orderDate, deliveryDate: deliveryDate, subtotal: subtotal, vat: vat,
    grandTotal: grandTotal, itemCount: itemCount, totalUnits: totalUnits,
    status: newStatus, notes: notes, lineItems: lineItems, teamId: teamId,
    finalBillNo: finalBillNo, actualBilledAmount: actualBilledAmount,
    billPhotoUrl: billPhotoUrl, verifiedByDelivery: verifiedByDelivery,
    verifiedByOffice: verifiedByOffice, billVerified: billVerified,
    preliminaryBillNo: preliminaryBillNo, preliminaryAmount: preliminaryAmount,
  );
}

class OrderItemModel {
  final String? id;
  final String orderId;
  final String? productId;
  final String productName;
  final String sku;
  final int quantity;
  final double unitPrice;
  final double lineTotal;

  const OrderItemModel({
    this.id, required this.orderId, this.productId, required this.productName,
    required this.sku, required this.quantity, required this.unitPrice, required this.lineTotal,
  });

  factory OrderItemModel.fromJson(Map<String, dynamic> json) => OrderItemModel(
    id: json['id'] as String?,
    orderId: json['order_id'] as String? ?? '',
    productId: json['product_id'] as String?,
    productName: json['product_name'] as String,
    sku: json['sku'] as String? ?? '',
    quantity: json['quantity'] as int? ?? 1,
    unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0.0,
    lineTotal: (json['line_total'] as num?)?.toDouble() ?? 0.0,
  );

  Map<String, dynamic> toJson() => {
    'order_id': orderId, 'product_id': productId, 'product_name': productName,
    'sku': sku, 'quantity': quantity, 'unit_price': unitPrice, 'line_total': lineTotal,
  };
}
