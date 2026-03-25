import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─── Models ──────────────────────────────────────────────────────────────────

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
  final String unit; // NEW: Unit of measurement (e.g., kg, pcs, box)
  final int stepSize;

  const ProductModel({
    required this.id,
    required this.name,
    required this.sku,
    required this.category,
    required this.brand,
    required this.unitPrice,
    required this.packSize,
    required this.status,
    required this.stockQty,
    required this.imageUrl,
    required this.semanticLabel,
    this.gstRate = 0.18,
    this.unit = 'pcs', // Default to pieces
    this.stepSize = 1,
  });

  factory ProductModel.fromJson(Map<String, dynamic> json) => ProductModel(
        id: json['id'] as String,
        name: json['name'] as String,
        sku: json['sku'] as String,
        category: json['category'] as String,
        brand: json['brand'] as String? ?? '',
        unitPrice: (json['unit_price'] as num).toDouble(),
        packSize: json['pack_size'] as String? ?? '',
        status: json['status'] as String? ?? 'available',
        stockQty: json['stock_qty'] as int? ?? 0,
        imageUrl: json['image_url'] as String? ?? '',
        semanticLabel: json['semantic_label'] as String? ?? '',
        gstRate: (json['gst_rate'] as num?)?.toDouble() ?? 0.18,
        unit: json['unit'] as String? ?? 'pcs',
        stepSize: (json['step_size'] as int? ?? 1).clamp(1, 999999),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sku': sku,
        'category': category,
        'brand': brand,
        'unit_price': unitPrice,
        'pack_size': packSize,
        'status': status,
        'stock_qty': stockQty,
        'image_url': imageUrl,
        'semantic_label': semanticLabel,
        'gst_rate': gstRate,
        'unit': unit,
        'step_size': stepSize,
      };
}

class ProductUnitModel {
  final String id;
  final String name;
  final String abbreviation;

  const ProductUnitModel({
    required this.id,
    required this.name,
    required this.abbreviation,
  });

  factory ProductUnitModel.fromJson(Map<String, dynamic> json) =>
      ProductUnitModel(
        id: json['id'] as String,
        name: json['name'] as String,
        abbreviation: json['abbreviation'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'abbreviation': abbreviation,
      };
}

class BeatModel {
  final String id;
  final String beatName;
  final String beatCode;
  final List<String> weekdays;
  final String area;
  final String route;

  const BeatModel({
    required this.id,
    required this.beatName,
    required this.beatCode,
    required this.weekdays,
    this.area = '',
    this.route = '',
  });

  factory BeatModel.fromJson(Map<String, dynamic> json) => BeatModel(
        id: json['id'] as String,
        beatName: json['beat_name'] as String,
        beatCode: json['beat_code'] as String,
        weekdays: List<String>.from(json['weekdays'] as List? ?? []),
        area: json['area'] as String? ?? '',
        route: json['route'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'beat_name': beatName,
        'beat_code': beatCode,
        'weekdays': weekdays,
        'area': area,
        'route': route,
      };
}

class CustomerModel {
  final String id;
  final String name;
  final String address;
  final String phone;
  final String type;
  final String? beatId;
  final String beat;
  final double lastOrderValue;
  final DateTime? lastOrderDate;

  const CustomerModel({
    required this.id,
    required this.name,
    required this.address,
    required this.phone,
    required this.type,
    this.beatId,
    required this.beat,
    required this.lastOrderValue,
    this.lastOrderDate,
  });

  factory CustomerModel.fromJson(Map<String, dynamic> json) => CustomerModel(
        id: json['id'] as String,
        name: json['name'] as String,
        address: json['address'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        type: json['type'] as String? ?? 'General Trade',
        beatId: json['beat_id'] as String?,
        beat: json['beat'] as String? ?? '',
        lastOrderValue: (json['last_order_value'] as num?)?.toDouble() ?? 0.0,
        lastOrderDate: json['last_order_date'] != null
            ? DateTime.tryParse(json['last_order_date'] as String)
            : null,
      );
}

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

  const OrderModel({
    required this.id,
    this.customerId,
    required this.customerName,
    required this.beat,
    required this.orderDate,
    this.deliveryDate,
    required this.subtotal,
    required this.vat,
    required this.grandTotal,
    required this.itemCount,
    required this.totalUnits,
    required this.status,
    this.notes,
    this.lineItems = const [],
  });

  factory OrderModel.fromJson(Map<String, dynamic> json) => OrderModel(
        id: json['id'] as String,
        customerId: json['customer_id'] as String?,
        customerName: json['customer_name'] as String,
        beat: json['beat'] as String? ?? '',
        orderDate: DateTime.parse(json['order_date'] as String),
        deliveryDate: json['delivery_date'] != null
            ? DateTime.tryParse(json['delivery_date'] as String)
            : null,
        subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0.0,
        vat: (json['vat'] as num?)?.toDouble() ?? 0.0,
        grandTotal: (json['grand_total'] as num?)?.toDouble() ?? 0.0,
        itemCount: json['item_count'] as int? ?? 0,
        totalUnits: json['total_units'] as int? ?? 0,
        status: json['status'] as String? ?? 'Pending',
        notes: json['notes'] as String?,
        lineItems: (json['order_items'] as List<dynamic>?)
                ?.map((e) => OrderItemModel.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
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
    this.id,
    required this.orderId,
    this.productId,
    required this.productName,
    required this.sku,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
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
        'order_id': orderId,
        'product_id': productId,
        'product_name': productName,
        'sku': sku,
        'quantity': quantity,
        'unit_price': unitPrice,
        'line_total': lineTotal,
      };
}

class ProductCategoryModel {
  final String id;
  final String name;
  final int sortOrder;
  final bool isActive;

  const ProductCategoryModel({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.isActive,
  });

  factory ProductCategoryModel.fromJson(Map<String, dynamic> json) =>
      ProductCategoryModel(
        id: json['id'] as String,
        name: json['name'] as String,
        sortOrder: json['sort_order'] as int? ?? 0,
        isActive: json['is_active'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'sort_order': sortOrder,
        'is_active': isActive,
      };
}

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);
  @override
  String toString() => message;
}

class BeatsLoadException implements Exception {
  final String message;
  const BeatsLoadException(this.message);
  @override
  String toString() => message;
}

class AppUserModel {
  final String id;
  final String email;
  final String fullName;
  final String role;
  final bool isActive;
  final List<BeatModel> assignedBeats;

  const AppUserModel({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    required this.isActive,
    this.assignedBeats = const [],
  });

  factory AppUserModel.fromJson(Map<String, dynamic> json) => AppUserModel(
        id: json['id'] as String,
        email: json['email'] as String,
        fullName: json['full_name'] as String? ?? '',
        role: json['role'] as String? ?? 'sales_rep',
        isActive: json['is_active'] as bool? ?? true,
      );

  AppUserModel copyWith({List<BeatModel>? assignedBeats}) => AppUserModel(
        id: id,
        email: email,
        fullName: fullName,
        role: role,
        isActive: isActive,
        assignedBeats: assignedBeats ?? this.assignedBeats,
      );
}

// ─── Service ─────────────────────────────────────────────────────────────────

class SupabaseService {
  static SupabaseService? _instance;
  static SupabaseService get instance => _instance ??= SupabaseService._();

  SupabaseService._();

  String? currentUserId;
  bool isOfflineMode = false; // 🔴 FIXED: Banner trigger

  static const String _dartDefineUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const String _dartDefineAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  static bool _initialized = false;

  static Future<Map<String, String>> _readEnvJson() async {
    final assetPaths = ['assets/env.json'];
    for (final path in assetPaths) {
      try {
        final jsonStr = await rootBundle.loadString(path);
        final Map<String, dynamic> data =
            json.decode(jsonStr) as Map<String, dynamic>;
        final url = (data['SUPABASE_URL'] as String? ?? '').trim();
        final key = (data['SUPABASE_ANON_KEY'] as String? ?? '').trim();
        if (url.isNotEmpty && key.isNotEmpty) return {'url': url, 'key': key};
      } catch (e) {
        debugPrint('[SupabaseService] Could not read $path: $e');
      }
    }
    return {'url': '', 'key': ''};
  }

  static Future<void> initialize() async {
    if (_initialized) return;

    String url = _dartDefineUrl.trim();
    String key = _dartDefineAnonKey.trim();

    if (url.isEmpty || key.isEmpty) {
      final envData = await _readEnvJson();
      if (url.isEmpty) url = envData['url'] ?? '';
      if (key.isEmpty) key = envData['key'] ?? '';
    }

    if (url.isEmpty || key.isEmpty) {
      throw Exception('Supabase credentials are missing.');
    }

    try {
      await Supabase.initialize(url: url, anonKey: key, debug: kDebugMode);
      _initialized = true;
    } catch (e) {
      if (e.toString().contains('already initialized')) {
        _initialized = true;
      } else {
        _initialized = false;
        rethrow;
      }
    }
  }

  static bool get isInitialized => _initialized;

  SupabaseClient get client => Supabase.instance.client;

  // ─── OFFLINE CACHE ENGINE ───
  Future<List<dynamic>> _fetchWithCache(
      String cacheKey, Future<List<dynamic>> Function() networkFetch) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final data = await networkFetch();
      await prefs.setString(cacheKey, jsonEncode(data));
      return data;
    } catch (e) {
      final cachedStr = prefs.getString(cacheKey);
      if (cachedStr != null) {
        debugPrint('Loaded $cacheKey from OFFLINE CACHE.');
        return jsonDecode(cachedStr) as List<dynamic>;
      }
      rethrow;
    }
  }

  // ─── AUTHENTICATION (ONLINE + OFFLINE) ───────────────────────────────

  Future<AppUserModel?> attemptOfflineLogin(
      String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedUserJson = prefs.getString('cached_user_profile');

    if (cachedUserJson != null) {
      final Map<String, dynamic> userData = jsonDecode(cachedUserJson);

      if (userData['email'] == email.trim().toLowerCase() &&
          userData['password_hash'] == password) {
        final user = AppUserModel.fromJson(userData);

        final cachedBeatsJson = prefs.getString('cache_user_beats_${user.id}');
        List<BeatModel> cachedBeats = [];
        if (cachedBeatsJson != null) {
          final List<dynamic> decodedBeats = jsonDecode(cachedBeatsJson);
          cachedBeats = decodedBeats.map((e) => BeatModel.fromJson(e)).toList();
        }

        currentUserId = user.id; //
        return user.copyWith(assignedBeats: cachedBeats);
      }
    }
    return null;
  }

  Future<AppUserModel?> loginWithCredentials(
      String email, String password) async {
    try {
      final response = await client
          .from('app_users')
          .select()
          .eq('email', email.trim().toLowerCase())
          .eq('password_hash', password)
          .eq('is_active', true)
          .maybeSingle();

      if (response == null) return null;

      final user = AppUserModel.fromJson(response);
      currentUserId = user.id; //
      isOfflineMode = false; //

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cached_user_profile', jsonEncode(response));

      final beats = await getUserBeats(user.id);
      await prefs.setString('cache_user_beats_${user.id}',
          jsonEncode(beats.map((b) => b.toJson()).toList()));

      return user.copyWith(assignedBeats: beats);
    } catch (e) {
      final offlineUser = await attemptOfflineLogin(email, password);
      if (offlineUser != null) {
        isOfflineMode = true; //
      }
      return offlineUser;
    }
  }

  // ─── DATA FETCHING (CACHED) ──────────────────────────────────────────

  Future<List<ProductModel>> getProducts() async {
    final response = await _fetchWithCache('cache_products', () async {
      return await client
          .from('products')
          .select()
          .order('category')
          .order('name');
    });
    return response
        .map((e) => ProductModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<BeatModel>> getBeats() async {
    final response = await _fetchWithCache('cache_beats', () async {
      return await client.from('beats').select().order('beat_code');
    });
    return response
        .map((e) => BeatModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<BeatModel>> getUserBeats(String userId) async {
    try {
      final response =
          await _fetchWithCache('cache_user_beats_$userId', () async {
        return await client
            .from('user_beats')
            .select('beats(id, beat_name, beat_code, weekdays, area, route)')
            .eq('user_id', userId);
      });
      final beats = (response)
          .where((e) => e['beats'] != null)
          .map((e) => BeatModel.fromJson(e['beats'] as Map<String, dynamic>))
          .toList();
      return beats;
    } catch (e) {
      return [];
    }
  }

  Future<List<CustomerModel>> getCustomers() async {
    final response = await _fetchWithCache('cache_customers', () async {
      return await client
          .from('customers')
          .select()
          .order('beat')
          .order('name');
    });
    return response
        .map((e) => CustomerModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ProductCategoryModel>> getProductCategories() async {
    final response = await _fetchWithCache('cache_categories', () async {
      return await client
          .from('product_categories')
          .select()
          .eq('is_active', true)
          .order('sort_order')
          .order('name');
    });
    return response
        .map((e) => ProductCategoryModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ProductCategoryModel>> getAllProductCategories() async {
    final response = await _fetchWithCache('cache_all_categories', () async {
      return await client
          .from('product_categories')
          .select()
          .order('sort_order')
          .order('name');
    });
    return response
        .map((e) => ProductCategoryModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<OrderModel>> getContextualOrders({String? beatName}) async {
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1).toIso8601String();
    final endOfMonth =
        DateTime(now.year, now.month + 1, 0, 23, 59, 59).toIso8601String();

    var query = client
        .from('orders')
        .select('*, order_items(*)')
        .gte('order_date', startOfMonth)
        .lte('order_date', endOfMonth);

    if (currentUserId != null) {
      query = query.eq('user_id', currentUserId!);
    }

    if (beatName != null && beatName.isNotEmpty) {
      query = query.eq('beat', beatName);
    }

    final response = await query.order('order_date', ascending: false);
    return (response as List<dynamic>)
        .map((e) => OrderModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ─── MUTATIONS ───────────────────────────────────────────────────────

  Future<String> createOrder({
    required String orderId,
    required String? customerId,
    required String customerName,
    required String beat,
    required DateTime deliveryDate,
    required double subtotal,
    required double vat,
    required double grandTotal,
    required int itemCount,
    required int totalUnits,
    required String notes,
    required List<Map<String, dynamic>> items,
  }) async {
    final userId = currentUserId; //

    await client.from('orders').upsert({
      'id': orderId,
      'user_id': userId,
      'customer_id': customerId,
      'customer_name': customerName,
      'beat': beat,
      'order_date': DateTime.now().toIso8601String(),
      'delivery_date': deliveryDate.toIso8601String().substring(0, 10),
      'subtotal': subtotal,
      'vat': vat,
      'grand_total': grandTotal,
      'item_count': itemCount,
      'total_units': totalUnits,
      'status': 'Pending',
      'notes': notes.isEmpty ? null : notes,
    });

    if (items.isNotEmpty) {
      final itemsWithUserId = items.map((item) {
        final modifiedItem = Map<String, dynamic>.from(item);
        modifiedItem['user_id'] = userId;
        return modifiedItem;
      }).toList();

      // For items, we also use upsert if they have IDs, but since they don't, 
      // we might still get duplicates if we retry. 
      // A better way is to delete existing items for this order first.
      await client.from('order_items').delete().eq('order_id', orderId);
      await client.from('order_items').insert(itemsWithUserId);
    }

    if (customerId != null && customerId.isNotEmpty) {
      await updateCustomerLastOrder(customerId, grandTotal);
    }
    return orderId;
  }

  Future<void> upsertProduct(ProductModel product) async {
    await client.from('products').upsert(product.toJson());
  }

  Future<void> updateCustomerLastOrder(
      String customerId, double orderValue) async {
    await client.from('customers').update({
      'last_order_value': orderValue,
      'last_order_date': DateTime.now().toIso8601String().substring(0, 10)
    }).eq('id', customerId);
  }

  Future<List<OrderModel>> getOrders() async {
    final response = await client
        .from('orders')
        .select('*, order_items(*)')
        .order('order_date', ascending: false);
    return (response as List<dynamic>)
        .map((e) => OrderModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> updateOrderStatus(String orderId, String status) async {
    await client.from('orders').update({'status': status}).eq('id', orderId);
  }

  Future<List<OrderModel>> getOrdersByDateRange(
      {DateTime? startDate, DateTime? endDate}) async {
    var query = client.from('orders').select('*, order_items(*)');
    if (startDate != null) {
      query = query.gte('order_date', startDate.toIso8601String());
    }
    if (endDate != null) {
      final nextDay = endDate.add(const Duration(days: 1));
      query = query.lt('order_date', nextDay.toIso8601String());
    }
    final response = await query.order('order_date', ascending: false);
    return (response as List<dynamic>)
        .map((e) => OrderModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createProductCategory(String name, int sortOrder) async {
    await client
        .from('product_categories')
        .insert({'name': name, 'sort_order': sortOrder, 'is_active': true});
  }

  Future<void> updateProductCategory(
      String id, String name, int sortOrder, bool isActive) async {
    await client.from('product_categories').update({
      'name': name,
      'sort_order': sortOrder,
      'is_active': isActive,
      'updated_at': DateTime.now().toIso8601String()
    }).eq('id', id);
  }

  Future<void> deleteProductCategory(String id) async {
    await client.from('product_categories').delete().eq('id', id);
  }

  Future<List<AppUserModel>> getAppUsers() async {
    final response = await client
        .from('app_users')
        .select('id, email, full_name, role, is_active, created_at')
        .order('created_at');
    return (response as List<dynamic>)
        .map((e) => AppUserModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createAppUser(
      {required String email,
      required String password,
      required String fullName,
      String role = 'sales_rep'}) async {
    await client.from('app_users').insert({
      'email': email.trim().toLowerCase(),
      'password_hash': password,
      'full_name': fullName,
      'role': role,
      'is_active': true
    });
  }

  Future<void> updateCustomer(
      {required String id,
      required String name,
      required String phone,
      required String address,
      required String type,
      String? beatId,
      String? beat}) async {
    final data = <String, dynamic>{
      'name': name,
      'phone': phone,
      'address': address,
      'type': type
    };
    if (beatId != null) data['beat_id'] = beatId;
    if (beat != null) data['beat'] = beat;
    await client.from('customers').update(data).eq('id', id);
  }

  Future<void> createCustomer(
      {required String name,
      required String phone,
      required String address,
      required String type,
      String? beatId,
      String? beat}) async {
    await client.from('customers').insert({
      'name': name,
      'phone': phone,
      'address': address,
      'type': type,
      if (beatId != null) 'beat_id': beatId,
      'beat': beat ?? '',
      'last_order_value': 0.0
    });
  }

  Future<void> upsertBeat(
      {String? id,
      required String beatName,
      required String beatCode,
      required String area,
      required String route,
      required List<String> weekdays}) async {
    final data = {
      'beat_name': beatName,
      'beat_code': beatCode,
      'area': area,
      'route': route,
      'weekdays': weekdays
    };
    if (id != null && id.isNotEmpty) {
      await client.from('beats').update(data).eq('id', id);
    } else {
      await client.from('beats').insert(data);
    }
  }

  Future<void> setUserBeats(
      {required String userId, required List<String> beatIds}) async {
    await client.from('user_beats').delete().eq('user_id', userId);
    if (beatIds.isNotEmpty) {
      final rows = beatIds
          .map((beatId) => {'user_id': userId, 'beat_id': beatId})
          .toList();
      await client.from('user_beats').insert(rows);
    }
  }

  Future<void> updateAppUser(
      {required String id,
      String? email,
      String? password,
      String? fullName,
      String? role,
      bool? isActive}) async {
    final data = <String, dynamic>{};
    if (email != null && email.isNotEmpty) {
      data['email'] = email.trim().toLowerCase();
    }
    if (password != null && password.isNotEmpty) {
      data['password_hash'] = password;
    }
    if (fullName != null && fullName.isNotEmpty) data['full_name'] = fullName;
    if (role != null) data['role'] = role;
    if (isActive != null) data['is_active'] = isActive;
    if (data.isNotEmpty) {
      await client.from('app_users').update(data).eq('id', id);
    }
  }

  Future<List<ProductUnitModel>> getProductUnits() async {
    final response = await client.from('product_units').select().order('name');
    return (response as List<dynamic>)
        .map((e) => ProductUnitModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> upsertProductUnit(ProductUnitModel unit) async {
    final data = unit.toJson();
    if (unit.id.isEmpty) {
      data.remove('id');
      await client.from('product_units').insert(data);
    } else {
      await client.from('product_units').update(data).eq('id', unit.id);
    }
  }

  Future<void> deleteProductUnit(String id) async {
    await client.from('product_units').delete().eq('id', id);
  }

  Future<Map<String, dynamic>> getSalesAnalytics() async {
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1).toIso8601String();
    final endOfMonth =
        DateTime(now.year, now.month + 1, 0, 23, 59, 59).toIso8601String();

    final response = await client
        .from('orders')
        .select('grand_total, beat, order_date')
        .gte('order_date', startOfMonth)
        .lte('order_date', endOfMonth)
        .eq('user_id', currentUserId!);

    final List<dynamic> orders = response as List<dynamic>;

    double totalSales = 0;
    Map<String, double> salesByBeat = {};
    int totalOrders = orders.length;

    for (var order in orders) {
      final double amount = (order['grand_total'] as num).toDouble();
      final String beat = order['beat'] as String? ?? 'Unknown';
      totalSales += amount;
      salesByBeat[beat] = (salesByBeat[beat] ?? 0) + amount;
    }

    return {
      'totalSales': totalSales,
      'totalOrders': totalOrders,
      'avgOrderValue': totalOrders > 0 ? totalSales / totalOrders : 0.0,
      'salesByBeat': salesByBeat,
    };
  }

  Future<List<OrderModel>> getCustomerOrders(String customerId) async {
    final response = await client
        .from('orders')
        .select('*, order_items(*)')
        .eq('customer_id', customerId)
        .order('order_date', ascending: false);

    return (response as List<dynamic>)
        .map((e) => OrderModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Stream<List<OrderModel>> getOrdersStream() {
    return client
        .from('orders')
        .stream(primaryKey: ['id'])
        .order('order_date', ascending: false)
        .map((data) => data.map((e) => OrderModel.fromJson(e)).toList());
  }
}
