import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

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
  final double gstRate;
  final String unit;
  final int stepSize;

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
    this.gstRate = 0.18,
    this.unit = 'pcs',
    this.stepSize = 1,
  });

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
      gstRate: model.gstRate,
      unit: model.unit,
      stepSize: model.stepSize,
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

  static const _boxName = 'cart_draft';
  static const _cartKey = 'items';
  static const _customerKey = 'customer';
  static const _beatKey = 'beat';

  // ─── PERSISTENCE ───
  Future<Box> get _box async =>
      Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : await Hive.openBox(_boxName);

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
        'gstRate': ci.product.gstRate,
        'unit': ci.product.unit,
        'stepSize': ci.product.stepSize,
        'quantity': ci.quantity,
      }).toList();
      await box.put(_cartKey, jsonEncode(items));
      if (currentCustomer != null) await box.put(_customerKey, jsonEncode(currentCustomer!.toJson()));
      if (currentBeat != null) await box.put(_beatKey, jsonEncode(currentBeat!.toJson()));
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
          gstRate: (raw['gstRate'] as num?)?.toDouble() ?? 0.18,
          unit: raw['unit'] ?? 'pcs', stepSize: raw['stepSize'] as int? ?? 1,
        );
        return CartItem(product: p, quantity: raw['quantity'] as int);
      }).toList();

      if (customerStr != null) currentCustomer = CustomerModel.fromJson(Map<String, dynamic>.from(jsonDecode(customerStr)));
      if (beatStr != null) currentBeat = BeatModel.fromJson(Map<String, dynamic>.from(jsonDecode(beatStr)));
      cartNotifier.value = items;
    } catch (e) {
      debugPrint('⚠️ CartService.restoreCart failed: $e');
    }
  }

  Future<void> clearPersistedCart() async {
    try {
      final box = await _box;
      await box.deleteAll([_cartKey, _customerKey, _beatKey]);
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

  // ─── SESSION LOGIC ───
  void setCustomerSession(CustomerModel customer, BeatModel? beat) {
    // If a NEW customer is selected, clear the cart.
    // If the SAME customer is selected again, keep the cart intact!
    if (currentCustomer?.id != customer.id) {
      cartNotifier.value = [];
      currentCustomer = customer;
      currentBeat = beat;
      _persistCart();
    }
  }

  Future<void> loadOrderToCart(OrderModel order, CustomerModel customer, BeatModel? beat) async {
    currentCustomer = customer;
    currentBeat = beat;

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
        debugPrint('Product not found for order item: ${orderItem.productName}');
      }
    }

    cartNotifier.value = newCart;
  }

  void clearCart() {
    cartNotifier.value = [];
    clearPersistedCart();
  }

  // ─── CART OPERATIONS ───
  void addOrUpdateItem(Product product, int amount) {
    final items = List<CartItem>.from(cartNotifier.value);
    final index = items.indexWhere((item) => item.product.id == product.id);

    if (index >= 0) {
      items[index].quantity += amount;
    } else {
      items.add(CartItem(product: product, quantity: amount));
    }
    cartNotifier.value = items; // Triggers UI rebuild automatically
    _persistCart();
  }

  void removeItem(Product product) {
    final items = List<CartItem>.from(cartNotifier.value);
    final index = items.indexWhere((item) => item.product.id == product.id);

    if (index >= 0) {
      if (items[index].quantity > product.stepSize) {
        items[index].quantity -= product.stepSize;
      } else {
        items.removeAt(index);
      }
      cartNotifier.value = items;
      _persistCart();
    }
  }

  void setItemQuantity(Product product, int quantity) {
    final items = List<CartItem>.from(cartNotifier.value);
    final index = items.indexWhere((item) => item.product.id == product.id);

    if (index >= 0) {
      if (quantity <= 0) {
        items.removeAt(index);
      } else {
        items[index].quantity = quantity;
      }
      cartNotifier.value = items;
      _persistCart();
    }
  }

  void deleteItemEntirely(Product product) {
    final items = List<CartItem>.from(cartNotifier.value);
    items.removeWhere((item) => item.product.id == product.id);
    cartNotifier.value = items;
    _persistCart();
  }

  int getQuantity(String productId) {
    final index = cartNotifier.value.indexWhere(
          (item) => item.product.id == productId,
    );
    return index < 0 ? 0 : cartNotifier.value[index].quantity;
  }
}
