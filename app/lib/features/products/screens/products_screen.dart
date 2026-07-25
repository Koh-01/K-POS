import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/products_provider.dart';
import '../../../core/models/product.dart';
import '../../../core/models/category.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/utils/error_utils.dart';

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  String _search = '';
  int? _filterCategoryId;
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(productsListProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final canManage = ref.watch(authProvider).user?.canManageCatalog ?? false;

    // Build category lookup map
    final categoryMap = <int, String>{};
    categoriesAsync.whenData((cats) {
      for (final c in cats) {
        categoryMap[c.id] = c.name;
      }
    });

    final categories = categoriesAsync.valueOrNull ?? [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Products'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(productsListProvider);
              ref.invalidate(categoriesProvider);
            },
          ),
        ],
      ),
      body: productsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (products) {
          final filtered = products.where((p) {
            final matchSearch = _search.isEmpty ||
                p.name.toLowerCase().contains(_search.toLowerCase());
            final matchCat = _filterCategoryId == null ||
                p.categoryId == _filterCategoryId;
            return matchSearch && matchCat;
          }).toList();

          return Column(
            children: [
              // Search bar
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search products...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _search.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _search = '');
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              // Category filter dropdown
              if (categories.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: DropdownButtonFormField<int?>(
                    value: _filterCategoryId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      prefixIcon:
                          const Icon(Icons.filter_list_rounded, size: 18),
                    ),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('All Categories')),
                      ...categories.map((c) =>
                          DropdownMenuItem(value: c.id, child: Text(c.name))),
                    ],
                    onChanged: (v) => setState(() => _filterCategoryId = v),
                  ),
                ),
              const Divider(height: 1),
              // Reordering isn't well-defined over free-text search results
              // (an arbitrary, possibly non-contiguous subset), but works fine
              // scoped to a single category filter or the full list.
              if (canManage && _search.isEmpty && filtered.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      const Icon(Icons.drag_indicator_rounded, size: 16),
                      const SizedBox(width: 6),
                      Text('Drag to reorder',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              // List
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.inventory_2_outlined,
                                size: 64, color: Colors.grey),
                            const SizedBox(height: 12),
                            Text(_search.isNotEmpty || _filterCategoryId != null
                                ? 'No products match'
                                : canManage
                                    ? 'No products yet. Tap + to add one.'
                                    : 'No products yet'),
                          ],
                        ),
                      )
                    : (canManage && _search.isEmpty)
                        ? ReorderableListView.builder(
                            itemCount: filtered.length,
                            onReorder: (oldIndex, newIndex) {
                              if (newIndex > oldIndex) newIndex--;
                              final reordered = List<Product>.from(filtered);
                              final moved = reordered.removeAt(oldIndex);
                              reordered.insert(newIndex, moved);
                              ref
                                  .read(productsListProvider.notifier)
                                  .reorder(reordered);
                            },
                            proxyDecorator: (child, index, animation) =>
                                Material(
                              elevation: 4,
                              borderRadius: BorderRadius.circular(12),
                              child: child,
                            ),
                            itemBuilder: (ctx, i) => _ProductTile(
                              key: ValueKey(filtered[i].id),
                              product: filtered[i],
                              categoryName: categoryMap[filtered[i].categoryId],
                              isAdmin: canManage,
                              position: i,
                              reorderable: true,
                            ),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (ctx, i) => _ProductTile(
                              product: filtered[i],
                              categoryName: categoryMap[filtered[i].categoryId],
                              isAdmin: canManage,
                            ),
                          ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: canManage
          ? FloatingActionButton(
              onPressed: () => context.push('/products/new'),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}


class _ProductTile extends ConsumerWidget {
  final Product product;
  final String? categoryName;
  final bool isAdmin;
  final int? position;
  final bool reorderable;
  const _ProductTile(
      {super.key,
      required this.product,
      required this.categoryName,
      required this.isAdmin,
      this.position,
      this.reorderable = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catLabel = product.category?.name ?? categoryName ?? 'Uncategorised';

    return ListTile(
      leading: reorderable
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ReorderableDragStartListener(
                  index: position!,
                  child: const Icon(Icons.drag_indicator_rounded,
                      color: Colors.grey),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundImage: product.imageUrl != null
                      ? NetworkImage(product.imageUrl!)
                      : null,
                  child: product.imageUrl == null
                      ? const Icon(Icons.restaurant)
                      : null,
                ),
              ],
            )
          : CircleAvatar(
              backgroundImage: product.imageUrl != null
                  ? NetworkImage(product.imageUrl!)
                  : null,
              child:
                  product.imageUrl == null ? const Icon(Icons.restaurant) : null,
            ),
      title: Text(product.name),
      subtitle: Text(catLabel),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatRM(product.price),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          if (isAdmin) ...[
            const SizedBox(width: 8),
            Switch(
              value: product.isAvailable,
              onChanged: (v) => ref
                  .read(productsListProvider.notifier)
                  .toggleAvailability(product.id, v),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/products/edit/${product.id}'),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _confirmDelete(context, ref),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete product?'),
        content: Text('Delete "${product.name}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(productsListProvider.notifier).delete(product.id);
    }
  }
}
