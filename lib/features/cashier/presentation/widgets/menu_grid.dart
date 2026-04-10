part of '../screens/cashier_screen.dart';

extension MenuGridMethods on _ProductListScreenState {
  Widget _buildColumnHeader({required String title, required Widget trailing}) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const Spacer(),
          trailing,
        ],
      ),
    );
  }

  Widget _buildProductCard(Product product) {
    final categoryColor = _categoryColor(product.category);

    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _onProductTap(product),
        child: ColoredBox(
          color: categoryColor,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  product.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onProductTap(Product product) async {
    if (_isHandlingProductTap) return;
    _isHandlingProductTap = true;

    try {
      final modifiers = await _fetchProductModifiers(product);
      if (!mounted) return;

      final config = await _showProductConfigModal(product, modifiers);
      if (!mounted || config == null) {
        return;
      }

      context.read<CartProvider>().addItem(
        product,
        quantity: config.quantity,
        modifiers: config.cartModifiers,
        modifiersData: config.modifiersData,
      );
    } finally {
      _isHandlingProductTap = false;
    }
  }

  Future<List<ProductModifier>> _fetchProductModifiers(Product product) async {
    List<ProductModifier> fromRaw(dynamic raw) {
      List<dynamic> groups;
      if (raw is List) {
        groups = raw;
      } else if (raw is Map<String, dynamic> && raw['groups'] is List) {
        groups = raw['groups'] as List<dynamic>;
      } else {
        return <ProductModifier>[];
      }

      return groups
          .whereType<Map<String, dynamic>>()
          .map((group) {
            final optionsRaw =
                (group['options'] as List<dynamic>?) ??
                (group['modifier_options'] as List<dynamic>?) ??
                <dynamic>[];
            final options = optionsRaw
                .whereType<Map<String, dynamic>>()
                .map(
                  (option) => ModifierOption(
                    id:
                        option['id']?.toString() ??
                        option['name']?.toString() ??
                        '',
                    name: option['name'] as String? ?? '',
                    price: (option['price'] as num?)?.toDouble() ?? 0,
                  ),
                )
                .toList();

            return ProductModifier(
              id:
                  group['id']?.toString() ??
                  group['name']?.toString() ??
                  'modifier',
              name: group['name'] as String? ?? 'Modifier',
              isRequired:
                  (group['is_required'] as bool?) ??
                  (group['isRequired'] as bool?) ??
                  false,
              type: group['type'] as String? ?? 'single',
              options: options,
            );
          })
          .where((modifier) => modifier.options.isNotEmpty)
          .toList();
    }

    final fromProduct = fromRaw(product.productModifiers);
    if (fromProduct.isNotEmpty) {
      return fromProduct;
    }

    try {
      final row = await supabase
          .from('products')
          .select('modifiers')
          .eq('id', product.id)
          .maybeSingle();

      final parsed = fromRaw(row?['modifiers']);
      if (parsed.isNotEmpty) {
        return parsed;
      }
    } catch (_) {
      // fallback below
    }

    return <ProductModifier>[];
  }

  String _optionLabel(ModifierOption option) {
    if (option.price == 0) {
      return option.name;
    }

    return '${option.name} (+${_formatRupiah(option.price)})';
  }
}
