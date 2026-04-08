export 'cart_group.dart';
export 'group_item.dart';

class Product {
  final int id;
  final String name;
  final double price;
  final String category;
  final String description;
  final String? imageUrl;
  final bool? isAvailable;
  final bool? isBundle;
  final bool? isRecommended;
  final List<BundleItem>? productBundles;
  final List<dynamic>? productModifiers;

  Product({
    required this.id,
    required this.name,
    required this.price,
    required this.category,
    required this.description,
    this.imageUrl,
    this.isAvailable,
    this.isBundle,
    this.isRecommended,
    this.productBundles,
    this.productModifiers,
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['id'],
      name: json['name'],
      price: (json['price'] as num).toDouble(),
      category: json['category'],
      description: json['description'] ?? '',
      imageUrl: json['image_url'],
      isAvailable: json['is_available'],
      isBundle: json['is_bundle'],
      isRecommended: json['is_recommended'],
      productBundles: json['product_bundles'] != null
          ? (json['product_bundles'] as List)
                .map((i) => BundleItem.fromJson(i))
                .toList()
          : null,
      productModifiers: json['modifiers'] as List<dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'price': price,
      'category': category,
      'description': description,
      'image_url': imageUrl,
      'is_available': isAvailable,
      'is_bundle': isBundle,
      'is_recommended': isRecommended,
      'product_bundles': productBundles?.map((e) => e.toJson()).toList(),
      'modifiers': productModifiers,
    };
  }
}

class BundleItem {
  final int id;
  final int parentProductId;
  final int childProductId;
  final int quantity;
  final Product? product; // The nested 'products' object from Supabase join

  BundleItem({
    required this.id,
    required this.parentProductId,
    required this.childProductId,
    required this.quantity,
    this.product,
  });

  factory BundleItem.fromJson(Map<String, dynamic> json) {
    return BundleItem(
      id: json['id'],
      parentProductId: json['parent_product_id'],
      childProductId: json['child_product_id'],
      quantity: json['quantity'],
      // Note: Supabase often returns nested relations as the table name (e.g., 'products')
      product: json['products'] != null
          ? Product.fromJson(json['products'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'parent_product_id': parentProductId,
      'child_product_id': childProductId,
      'quantity': quantity,
      'products': product?.toJson(),
    };
  }
}

class Promotion {
  final String id;
  final String code;
  final String description;
  final String type; // 'percentage' | 'fixed_amount'
  final double value;
  final String scope; // 'order' | 'category' | 'product'
  final double? minOrderValue;
  final int? minQuantity;
  final DateTime startsAt;
  final DateTime endsAt;
  final bool isActive;
  final List<PromotionTarget>? promotionTargets;

  Promotion({
    required this.id,
    required this.code,
    required this.description,
    required this.type,
    required this.value,
    required this.scope,
    this.minOrderValue,
    this.minQuantity,
    required this.startsAt,
    required this.endsAt,
    required this.isActive,
    this.promotionTargets,
  });

  factory Promotion.fromJson(Map<String, dynamic> json) {
    return Promotion(
      id: json['id'],
      code: json['code'],
      description: json['description'],
      type: json['type'],
      value: (json['value'] as num).toDouble(),
      scope: json['scope'],
      minOrderValue: json['min_order_value'] != null
          ? (json['min_order_value'] as num).toDouble()
          : null,
      minQuantity: json['min_quantity'],
      startsAt: DateTime.parse(json['starts_at']),
      endsAt: DateTime.parse(json['ends_at']),
      isActive: json['is_active'],
      promotionTargets: json['promotion_targets'] != null
          ? (json['promotion_targets'] as List)
                .map((i) => PromotionTarget.fromJson(i))
                .toList()
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'code': code,
      'description': description,
      'type': type,
      'value': value,
      'scope': scope,
      'min_order_value': minOrderValue,
      'min_quantity': minQuantity,
      'starts_at': startsAt.toIso8601String(),
      'ends_at': endsAt.toIso8601String(),
      'is_active': isActive,
      'promotion_targets': promotionTargets?.map((e) => e.toJson()).toList(),
    };
  }
}

class PromotionTarget {
  final String id;
  final String promotionId;
  final int? targetProductId;
  final String? targetCategory;

  PromotionTarget({
    required this.id,
    required this.promotionId,
    this.targetProductId,
    this.targetCategory,
  });

  factory PromotionTarget.fromJson(Map<String, dynamic> json) {
    return PromotionTarget(
      id: json['id'],
      promotionId: json['promotion_id'],
      targetProductId: json['target_product_id'],
      targetCategory: json['target_category'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'promotion_id': promotionId,
      'target_product_id': targetProductId,
      'target_category': targetCategory,
    };
  }
}

class CartItem extends Product {
  final String cartId;
  final int quantity;
  // Modifiers: mapped as simple Map/JSON since structure can vary
  final CartModifiers? modifiers;
  final List<dynamic>? modifiersData;

  CartItem({
    required super.id,
    required super.name,
    required super.price,
    required super.category,
    required super.description,
    super.imageUrl,
    super.isAvailable,
    super.isBundle,
    super.isRecommended,
    super.productBundles,
    super.productModifiers,
    required this.cartId,
    required this.quantity,
    this.modifiers,
    this.modifiersData,
  });

  factory CartItem.fromJson(Map<String, dynamic> json) {
    // Deserialize the base Product part first
    final product = Product.fromJson(json);

    return CartItem(
      id: product.id,
      name: product.name,
      price: product.price,
      category: product.category,
      description: product.description,
      imageUrl: product.imageUrl,
      isAvailable: product.isAvailable,
      isBundle: product.isBundle,
      isRecommended: product.isRecommended,
      productBundles: product.productBundles,
      productModifiers: product.productModifiers,
      cartId: json['cartId'] ?? '', // Handle client-side ID generation
      quantity: json['quantity'] ?? 1,
      modifiers: json['modifiers'] != null
          ? CartModifiers.fromJson(json['modifiers'])
          : null,
      modifiersData: json['modifiersData'],
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = super.toJson();
    data['cartId'] = cartId;
    data['quantity'] = quantity;
    if (modifiers != null) {
      data['modifiers'] = modifiers!.toJson();
    }
    data['modifiersData'] = modifiersData;
    return data;
  }
}

class CartModifiers {
  final Map<String, List<String>> selections;
  final String notes;

  CartModifiers({required this.selections, required this.notes});

  factory CartModifiers.fromJson(Map<String, dynamic> json) {
    return CartModifiers(
      selections: (json['selections'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(
          key,
          (value as List<dynamic>).map((e) => e.toString()).toList(),
        ),
      ),
      notes: json['notes'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'selections': selections, 'notes': notes};
  }
}

class ModifierOption {
  final String id;
  final String name;
  final double price;

  ModifierOption({required this.id, required this.name, required this.price});

  factory ModifierOption.fromJson(Map<String, dynamic> json) {
    return ModifierOption(
      id: json['id'],
      name: json['name'],
      price: (json['price'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'name': name, 'price': price};
  }
}

class ProductModifier {
  final String id;
  final String name;
  final bool isRequired;
  final String type; // 'single' | 'multi'
  final List<ModifierOption> options;

  ProductModifier({
    required this.id,
    required this.name,
    required this.isRequired,
    required this.type,
    required this.options,
  });

  factory ProductModifier.fromJson(Map<String, dynamic> json) {
    return ProductModifier(
      id: json['id'],
      name: json['name'],
      isRequired: json['isRequired'],
      type: json['type'],
      options: (json['options'] as List)
          .map((i) => ModifierOption.fromJson(i))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'isRequired': isRequired,
      'type': type,
      'options': options.map((e) => e.toJson()).toList(),
    };
  }
}
