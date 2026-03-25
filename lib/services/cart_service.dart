import 'package:flutter/foundation.dart' show ValueNotifier;

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
    }
  }

  void clearCart() {
    cartNotifier.value = [];
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
    }
  }

  void deleteItemEntirely(Product product) {
    final items = List<CartItem>.from(cartNotifier.value);
    items.removeWhere((item) => item.product.id == product.id);
    cartNotifier.value = items;
  }

  int getQuantity(String productId) {
    final index = cartNotifier.value.indexWhere(
      (item) => item.product.id == productId,
    );
    return index < 0 ? 0 : cartNotifier.value[index].quantity;
  }
}
