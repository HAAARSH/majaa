/// Converts gst_rate from DB (integer like 18, 5) to decimal (0.18, 0.05).
/// If already decimal (< 1), keeps as-is.
double _parseGstRate(dynamic raw) {
  if (raw == null) return 0.18;
  final val = (raw as num).toDouble();
  // DB stores as integer percent (5, 12, 18, 28). Convert to decimal.
  return val > 1 ? val / 100.0 : val;
}

class ProductModel {
  final String id;
  final String name;
  final String sku;
  final String category;
  final String brand;
  final double unitPrice;  // Selling rate (RATE from billing software)
  final double mrp;        // Maximum Retail Price (MRP from billing software)
  final String packSize;
  final String status;
  final int stockQty;
  final String imageUrl;
  final String semanticLabel;
  final double gstRate;
  final String unit;
  final int stepSize;
  final String teamId;
  final String? billingName;  // Local software item name (admin sees this)
  final String? printName;    // Print name on bills/reports

  String get categoryName => category;

  final String? subcategoryId;

  // ITEM master enrichment (synced from ITEM07/11.csv).
  // Needed for CsdsPricing.priceFor() item-group rule match + per-item tax.
  final String? company;       // e.g. "GOYAL", "MAHAWAR"
  final String? itemGroup;     // e.g. "LAFZ", "COLOR" — empty string = company-wide
  final String? hsn;
  final int? packqty;
  final double? vatPer;
  final double? satPer;
  final double? cstPer;
  final double? cessPer;
  final String? taxOnMrp;      // 'Y' / 'N'

  /// Timestamp when stock_qty transitioned from >0 to <=0. Populated +
  /// cleared automatically by a BEFORE UPDATE trigger on products (see
  /// `20260423000007_products_stock_zeroed_at.sql`). NULL when the
  /// product is currently stocked OR was NEVER-stocked since the
  /// trigger was installed. Drives the 2-day billable grace window in
  /// the rep product list — see [isInStockGrace] / [isBillable].
  final DateTime? stockZeroedAt;

  const ProductModel({
    required this.id, required this.name, required this.sku, required this.category,
    required this.brand, required this.unitPrice, this.mrp = 0, required this.packSize,
    required this.status, required this.stockQty, required this.imageUrl,
    required this.semanticLabel, this.gstRate = 0.18, this.unit = 'pcs',
    this.stepSize = 1, required this.teamId, this.subcategoryId,
    this.billingName, this.printName,
    this.company, this.itemGroup, this.hsn, this.packqty,
    this.vatPer, this.satPer, this.cstPer, this.cessPer, this.taxOnMrp,
    this.stockZeroedAt,
  });

  factory ProductModel.fromJson(Map<String, dynamic> json) => ProductModel(
    id: json['id'] as String,
    name: json['name'] as String,
    sku: json['sku'] as String? ?? '',
    category: json['category'] as String,
    brand: json['brand'] as String? ?? '',
    unitPrice: (json['unit_price'] as num).toDouble(),
    mrp: (json['mrp'] as num?)?.toDouble() ?? 0,
    packSize: json['pack_size'] as String? ?? '',
    status: json['status'] as String? ?? 'available',
    stockQty: json['stock_qty'] as int? ?? 0,
    imageUrl: json['image_url'] as String? ?? '',
    semanticLabel: json['semantic_label'] as String? ?? '',
    gstRate: _parseGstRate(json['gst_rate']),
    unit: json['unit'] as String? ?? 'pcs',
    stepSize: (json['step_size'] as int? ?? 1).clamp(1, 999999),
    teamId: json['team_id'] as String? ?? 'JA',
    subcategoryId: json['subcategory_id'] as String?,
    billingName: json['billing_name'] as String?,
    printName: json['print_name'] as String?,
    company: json['company'] as String?,
    itemGroup: json['item_group'] as String?,
    hsn: json['hsn'] as String?,
    packqty: json['packqty'] as int?,
    vatPer: (json['vat_per'] as num?)?.toDouble(),
    satPer: (json['sat_per'] as num?)?.toDouble(),
    cstPer: (json['cst_per'] as num?)?.toDouble(),
    cessPer: (json['cess_per'] as num?)?.toDouble(),
    taxOnMrp: json['tax_on_mrp'] as String?,
    stockZeroedAt: json['stock_zeroed_at'] == null
        ? null
        : DateTime.tryParse(json['stock_zeroed_at'].toString()),
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'sku': sku, 'category': category, 'brand': brand,
    'unit_price': unitPrice, 'mrp': mrp, 'pack_size': packSize, 'status': status,
    'stock_qty': stockQty, 'image_url': imageUrl, 'semantic_label': semanticLabel,
    'gst_rate': (gstRate * 100).round(), 'unit': unit, 'step_size': stepSize, 'team_id': teamId,
    'subcategory_id': subcategoryId,
    'billing_name': billingName,
    'print_name': printName,
    'company': company,
    'item_group': itemGroup,
    'hsn': hsn,
    'packqty': packqty,
    'vat_per': vatPer,
    'sat_per': satPer,
    'cst_per': cstPer,
    'cess_per': cessPer,
    'tax_on_mrp': taxOnMrp,
    if (stockZeroedAt != null) 'stock_zeroed_at': stockZeroedAt!.toIso8601String(),
  };

  /// Total tax rate from ITEM master (%). Sum of VATPER + SATPER + CESSPER.
  /// Used by CsdsPricing when applying the cascade. Falls back to 0 when
  /// ITEM sync hasn't populated the columns yet.
  double get totalTaxPercent =>
      (vatPer ?? 0) + (satPer ?? 0) + (cessPer ?? 0);

  /// True when stock is zero (or negative) BUT the grace period after
  /// zeroing is still active. Rep should still be able to add this to
  /// cart — office has [graceDays] to restock before it hard-locks.
  bool isInStockGrace({int graceDays = 2}) {
    if (stockQty > 0) return false;
    if (stockZeroedAt == null) return false;
    return DateTime.now().difference(stockZeroedAt!) < Duration(days: graceDays);
  }

  /// Convenience: true when the rep is allowed to add this to cart
  /// right now. Combines current stock > 0 with the in-grace window.
  /// [graceDays] defaults to 2; pass the value from BillingRulesService
  /// if you have it handy.
  bool isBillable({int graceDays = 2}) =>
      stockQty > 0 || isInStockGrace(graceDays: graceDays);

  /// Whole days of grace remaining before the product hard-locks.
  /// Returns 0 for not-in-grace or already-expired; otherwise 1 or 2.
  int graceDaysLeft({int graceDays = 2}) {
    if (stockQty > 0 || stockZeroedAt == null) return 0;
    final elapsed = DateTime.now().difference(stockZeroedAt!);
    if (elapsed >= Duration(days: graceDays)) return 0;
    // Remaining days rounded UP so "29h left" shows as "2 days" not "1".
    final remaining = Duration(days: graceDays) - elapsed;
    final wholeDays = remaining.inHours ~/ 24;
    return (remaining.inHours % 24 == 0) ? wholeDays : wholeDays + 1;
  }
}

class ProductCategoryModel {
  final String id;
  final String name;
  final int sortOrder;
  final bool isActive;
  final String teamId;

  const ProductCategoryModel({required this.id, required this.name, required this.sortOrder, required this.isActive, this.teamId = 'JA'});

  factory ProductCategoryModel.fromJson(Map<String, dynamic> json) => ProductCategoryModel(
    id: json['id'] as String? ?? '',
    name: json['name'] as String,
    sortOrder: json['sort_order'] as int? ?? 0,
    isActive: json['is_active'] as bool? ?? true,
    teamId: json['team_id'] as String? ?? 'JA',
  );

  Map<String, dynamic> toJson() => {'name': name, 'sort_order': sortOrder, 'is_active': isActive, 'team_id': teamId};
}

class ProductSubcategoryModel {
  final String id;
  final String name;
  final String categoryId;
  final int sortOrder;
  final String teamId;

  const ProductSubcategoryModel({
    required this.id, required this.name, required this.categoryId,
    required this.sortOrder, required this.teamId,
  });

  factory ProductSubcategoryModel.fromJson(Map<String, dynamic> json) => ProductSubcategoryModel(
    id: json['id'] as String,
    name: json['name'] as String,
    categoryId: json['category_id'] as String,
    sortOrder: json['sort_order'] as int? ?? 0,
    teamId: json['team_id'] as String? ?? 'JA',
  );

  Map<String, dynamic> toJson() => {
    'name': name, 'category_id': categoryId,
    'sort_order': sortOrder, 'team_id': teamId,
  };
}
