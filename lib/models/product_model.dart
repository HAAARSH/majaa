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
  final double unitPrice;
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

  const ProductModel({
    required this.id, required this.name, required this.sku, required this.category,
    required this.brand, required this.unitPrice, required this.packSize,
    required this.status, required this.stockQty, required this.imageUrl,
    required this.semanticLabel, this.gstRate = 0.18, this.unit = 'pcs',
    this.stepSize = 1, required this.teamId, this.subcategoryId,
    this.billingName, this.printName,
  });

  factory ProductModel.fromJson(Map<String, dynamic> json) => ProductModel(
    id: json['id'] as String,
    name: json['name'] as String,
    sku: json['sku'] as String? ?? '',
    category: json['category'] as String,
    brand: json['brand'] as String? ?? '',
    unitPrice: (json['unit_price'] as num).toDouble(),
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
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'sku': sku, 'category': category, 'brand': brand,
    'unit_price': unitPrice, 'pack_size': packSize, 'status': status,
    'stock_qty': stockQty, 'image_url': imageUrl, 'semantic_label': semanticLabel,
    'gst_rate': (gstRate * 100).round(), 'unit': unit, 'step_size': stepSize, 'team_id': teamId,
    'subcategory_id': subcategoryId,
    'billing_name': billingName,
    'print_name': printName,
  };
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
