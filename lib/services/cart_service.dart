import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import './auth_service.dart';
import './supabase_service.dart';

enum ProductStatus { available, lowStock, outOfStock, discontinued }

class Product {
  final String id;
  final String name;
  final String sku;
  final String category;
  final double unitPrice;
  final String packSize;
  final ProductStatus status;
  final int stockQty;
  final String imageUrl;
  final String semanticLabel;
  final String brand;
  final double mrp;
  final double gstRate;
  final String unit;
  final int stepSize;
  /// Mirrored from ProductModel.stockZeroedAt. Powers the 2-day grace
  /// window in the rep flow — see [isInStockGrace] / [isBillable].
  final DateTime? stockZeroedAt;

  const Product({
    required this.id,
    required this.name,
    required this.sku,
    required this.category,
    required this.unitPrice,
    required this.packSize,
    required this.status,
    required this.stockQty,
    required this.imageUrl,
    required this.semanticLabel,
    required this.brand,
    this.mrp = 0,
    this.gstRate = 0.18,
    this.unit = 'pcs',
    this.stepSize = 1,
    this.stockZeroedAt,
  });

  /// Within the 2-day billable grace window after stock first zeroed?
  bool isInStockGrace({int graceDays = 2}) {
    if (stockQty > 0) return false;
    if (stockZeroedAt == null) return false;
    return DateTime.now().difference(stockZeroedAt!) < Duration(days: graceDays);
  }

  /// Can the rep add this to cart right now?
  bool get isBillable => stockQty > 0 || isInStockGrace();

  /// Whole days of grace remaining (1 or 2). 0 when not in grace or
  /// already expired.
  int graceDaysLeft({int graceDays = 2}) {
    if (stockQty > 0 || stockZeroedAt == null) return 0;
    final elapsed = DateTime.now().difference(stockZeroedAt!);
    if (elapsed >= Duration(days: graceDays)) return 0;
    final remaining = Duration(days: graceDays) - elapsed;
    final wholeDays = remaining.inHours ~/ 24;
    return (remaining.inHours % 24 == 0) ? wholeDays : wholeDays + 1;
  }

  factory Product.fromModel(ProductModel model) {
    return Product(
      id: model.id,
      name: model.name,
      sku: model.sku,
      category: model.category,
      unitPrice: model.unitPrice,
      packSize: model.packSize,
      status: _statusFromString(model.status),
      stockQty: model.stockQty,
      imageUrl: model.imageUrl,
      semanticLabel: model.semanticLabel,
      brand: model.brand,
      mrp: model.mrp,
      gstRate: model.gstRate,
      unit: model.unit,
      stepSize: model.stepSize,
      stockZeroedAt: model.stockZeroedAt,
    );
  }

  static ProductStatus _statusFromString(String v) {
    switch (v) {
      case 'available':
        return ProductStatus.available;
      case 'lowStock':
        return ProductStatus.lowStock;
      case 'outOfStock':
        return ProductStatus.outOfStock;
      case 'discontinued':
        return ProductStatus.discontinued;
      default:
        return ProductStatus.available;
    }
  }
}

class CartItem {
  final Product product;
  int quantity;
  CartItem({required this.product, this.quantity = 1});
}

class CartService {
  // Singleton instance
  static final CartService instance = CartService._internal();
  CartService._internal();

  // Hive box is namespaced per team so a cart built in team JA never leaks
  // into team MA when the rep switches team mid-session.
  String get _boxName => 'cart_draft_${AuthService.currentTeam}';
  static const _cartKey = 'items';
  static const _customerKey = 'customer';
  static const _beatKey = 'beat';
  // Persist OOB flag alongside cart — without this, a force-close mid-order
  // silently downgrades an out-of-beat draft to a regular order on restart.
  static const _oobKey = 'is_out_of_beat';

  // ─── PERSISTENCE ───
  Future<Box> get _box async {
    final name = _boxName;
    return Hive.isBoxOpen(name) ? Hive.box(name) : await Hive.openBox(name);
  }

  Future<void> _persistCart() async {
    try {
      final box = await _box;
      final items = cartNotifier.value.map((ci) => {
        'id': ci.product.id,
        'name': ci.product.name,
        'sku': ci.product.sku,
        'category': ci.product.category,
        'unitPrice': ci.product.unitPrice,
        'packSize': ci.product.packSize,
        'status': ci.product.status.name,
        'stockQty': ci.product.stockQty,
        'imageUrl': ci.product.imageUrl,
        'semanticLabel': ci.product.semanticLabel,
        'brand': ci.product.brand,
        'mrp': ci.product.mrp,
        'gstRate': ci.product.gstRate,
        'unit': ci.product.unit,
        'stepSize': ci.product.stepSize,
        'quantity': ci.quantity,
      }).toList();
      await box.put(_cartKey, jsonEncode(items));
      if (currentCustomer != null) await box.put(_customerKey, jsonEncode(currentCustomer!.toJson()));
      if (currentBeat != null) await box.put(_beatKey, jsonEncode(currentBeat!.toJson()));
      await box.put(_oobKey, isOutOfBeat);
    } catch (e) {
      debugPrint('⚠️ CartService._persistCart failed: $e');
    }
  }

  Future<void> restoreCart() async {
    try {
      final box = await _box;
      final itemsStr = box.get(_cartKey) as String?;
      final customerStr = box.get(_customerKey) as String?;
      final beatStr = box.get(_beatKey) as String?;
      if (itemsStr == null) return;

      final rawItems = jsonDecode(itemsStr) as List;
      final items = rawItems.map((raw) {
        final p = Product(
          id: raw['id'], name: raw['name'], sku: raw['sku'], category: raw['category'],
          unitPrice: (raw['unitPrice'] as num).toDouble(), packSize: raw['packSize'],
          status: ProductStatus.values.firstWhere((s) => s.name == raw['status'], orElse: () => ProductStatus.available),
          stockQty: raw['stockQty'] as int, imageUrl: raw['imageUrl'] ?? '',
          semanticLabel: raw['semanticLabel'] ?? '', brand: raw['brand'] ?? '',
          mrp: (raw['mrp'] as num?)?.toDouble() ?? 0,
          gstRate: (raw['gstRate'] as num?)?.toDouble() ?? 0.18,
          unit: raw['unit'] ?? 'pcs', stepSize: raw['stepSize'] as int? ?? 1,
        );
        return CartItem(product: p, quantity: raw['quantity'] as int);
      }).toList();

      if (customerStr != null) currentCustomer = CustomerModel.fromJson(Map<String, dynamic>.from(jsonDecode(customerStr)));
      if (beatStr != null) currentBeat = BeatModel.fromJson(Map<String, dynamic>.from(jsonDecode(beatStr)));
      isOutOfBeat = box.get(_oobKey) as bool? ?? false;
      cartNotifier.value = items;
    } catch (e) {
      debugPrint('⚠️ CartService.restoreCart failed: $e');
    }
  }

  Future<void> clearPersistedCart() async {
    try {
      final box = await _box;
      await box.deleteAll([_cartKey, _customerKey, _beatKey, _oobKey]);
    } catch (_) {}
  }

  double getGrandTotal() {
    return cartNotifier.value.fold(0.0, (total, item) {
      double itemTotal = item.product.unitPrice * item.quantity;
      // ignore: dead_null_aware_expression
      double gstAmount = itemTotal * (item.product.gstRate ?? 0.0);
      return total + itemTotal + gstAmount;
    });
  }

  // Global reactive cart state
  final ValueNotifier<List<CartItem>> cartNotifier = ValueNotifier([]);

  // Current Session Data
  CustomerModel? currentCustomer;
  BeatModel? currentBeat;
  /// True when the current order was initiated from the Out-of-Beat flow.
  /// Surfaced on the order creation header + tagged on the order row so
  /// managers can distinguish route compliance from walk-in orders.
  bool isOutOfBeat = false;

  /// When editing an existing order, this holds the original order ID.
  /// On submit, the old order is deleted and the new one uses this ID.
  /// Null means creating a new order.
  String? editingOrderId;
  /// Beat name captured from the original order when editing — used as a
  /// final fallback on submit so edited orders never write empty beat_name.
  String? editingOriginalBeatName;
  /// Products that were in the original order but no longer exist in the catalog.
  List<String> editingSkippedItems = [];

  // ─── SESSION LOGIC ───
  void setCustomerSession(CustomerModel customer, BeatModel? beat, {bool isOutOfBeat = false}) {
    // If a NEW customer is selected, clear the cart.
    // If the SAME customer is selected again, keep the cart intact!
    if (currentCustomer?.id != customer.id) {
      cartNotifier.value = [];
      currentCustomer = customer;
      currentBeat = beat;
      this.isOutOfBeat = isOutOfBeat;
      _persistCart();
    } else {
      // Update OOB even for same customer — the rep may re-enter via OOB path
      // after cancelling a previous attempt.
      this.isOutOfBeat = isOutOfBeat;
    }
  }

  Future<void> loadOrderToCart(OrderModel order, CustomerModel customer, BeatModel? beat) async {
    currentCustomer = customer;
    currentBeat = beat;
    editingOrderId = order.id;
    editingOriginalBeatName = order.beat;
    editingSkippedItems = [];
    // Preserve OOB flag across edit — if the original was an out-of-beat order,
    // the edited version stays tagged so manager reports stay consistent.
    isOutOfBeat = order.isOutOfBeat;

    // Fetch all products to match with order items
    final allProducts = await SupabaseService.instance.getProducts();
    final List<CartItem> newCart = [];

    for (var orderItem in order.lineItems) {
      final productIndex = allProducts.indexWhere((p) => p.id == orderItem.productId);
      if (productIndex >= 0) {
        newCart.add(CartItem(
          product: Product.fromModel(allProducts[productIndex]),
          quantity: orderItem.quantity,
        ));
      } else {
        editingSkippedItems.add(orderItem.productName);
        debugPrint('Product not found for order item: ${orderItem.productName}');
      }
    }

    cartNotifier.value = newCart;
  }

  void clearCart() {
    cartNotifier.value = [];
    editingOrderId = null;
    editingOriginalBeatName = null;
    editingSkippedItems = [];
    isOutOfBeat = false;
    clearPersistedCart();
  }

  // ─── CART OPERATIONS ───
  //
  // Each mutator awaits _persistCart so a fast kill (battery, OS) after tapping
  // "+10" doesn't lose the last items. Callers that don't await still work —
  // the UI is updated synchronously via cartNotifier; only durability is
  // shifted from "eventually" to "before the Future completes".
  Future<void> addOrUpdateItem(Product product, int amount) async {
    if (amount <= 0) return;

    final items = List<CartItem>.from(cartNotifier.value);
    final index = items.indexWhere((item) => item.product.id == product.id);

    if (index >= 0) {
      final newQty = items[index].quantity + amount;
      if (newQty <= 0) {
        items.removeAt(index);
      } else {
        items[index].quantity = newQty;
      }
    } else {
      items.add(CartItem(product: product, quantity: amount));
    }
    cartNotifier.value = items; // Triggers UI rebuild automatically
    await _persistCart();
  }

  Future<void> removeItem(Product product) async {
    final items = List<CartItem>.from(cartNotifier.value);
    final index = items.indexWhere((item) => item.product.id == product.id);

    if (index >= 0) {
      if (items[index].quantity > product.stepSize) {
        items[index].quantity -= product.stepSize;
      } else {
        items.removeAt(index);
      }
      cartNotifier.value = items;
      await _persistCart();
    }
  }

  Future<void> setItemQuantity(Product product, int quantity) async {
    final items = List<CartItem>.from(cartNotifier.value);
    final index = items.indexWhere((item) => item.product.id == product.id);

    if (index >= 0) {
      if (quantity <= 0) {
        items.removeAt(index);
      } else {
        items[index].quantity = quantity;
      }
      cartNotifier.value = items;
      await _persistCart();
    }
  }

  Future<void> deleteItemEntirely(Product product) async {
    final items = List<CartItem>.from(cartNotifier.value);
    items.removeWhere((item) => item.product.id == product.id);
    cartNotifier.value = items;
    await _persistCart();
  }

  int getQuantity(String productId) {
    final index = cartNotifier.value.indexWhere(
          (item) => item.product.id == productId,
    );
    return index < 0 ? 0 : cartNotifier.value[index].quantity;
  }
}
