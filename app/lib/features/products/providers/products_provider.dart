import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/db/local_db.dart';
import '../../../core/models/category.dart';
import '../../../core/models/product.dart';

class ProductCatalog {
  final List<Product> products;
  final List<Category> categories;
  const ProductCatalog({required this.products, required this.categories});
}

final productsProvider = FutureProvider.autoDispose<ProductCatalog>((
  ref,
) async {
  try {
    final results = await Future.wait([
      ApiClient.instance.get('/products'),
      ApiClient.instance.get('/categories'),
    ]);
    final products = (results[0].data as List)
        .map((e) => Product.fromJson(e as Map<String, dynamic>))
        .where((p) => p.isAvailable)
        .toList();
    final categories = (results[1].data as List)
        .map((e) => Category.fromJson(e as Map<String, dynamic>))
        .toList();

    // sqflite is the mobile/desktop offline store. Flutter Web has no
    // registered sqflite implementation, so a successful API response must
    // not be turned into a catalogue failure by trying to write that cache.
    if (!kIsWeb) {
      await LocalDb.upsertProducts(products.map((p) => p.toLocalDb()).toList());
      await LocalDb.upsertCategories(
        categories.map((c) => c.toJson()).toList(),
      );
    }

    return ProductCatalog(products: products, categories: categories);
  } catch (e) {
    if (!ApiException.isOfflineFailure(e)) rethrow;
    if (kIsWeb) rethrow;
    // Offline fallback
    final rows = await LocalDb.getProducts();
    final catRows = await LocalDb.getCategories();
    return ProductCatalog(
      products: rows
          .map(
            (r) => Product(
              id: r['id'] as int,
              name: r['name'] as String,
              categoryId: r['category_id'] as int?,
              price: r['price'] as double,
              imageUrl: r['image_url'] as String?,
              isAvailable: (r['is_available'] as int) == 1,
              soldByWeight: ((r['sold_by_weight'] as int?) ?? 0) == 1,
              sortOrder: (r['sort_order'] as int?) ?? 0,
            ),
          )
          .toList(),
      categories: catRows
          .map(
            (r) => Category(
              id: r['id'] as int,
              name: r['name'] as String,
              sortOrder: (r['sort_order'] as int?) ?? 0,
            ),
          )
          .toList(),
    );
  }
});

// Mutable product list for admin CRUD operations
class ProductsNotifier extends StateNotifier<AsyncValue<List<Product>>> {
  ProductsNotifier() : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    await _fetch();
  }

  /// Refetches without an intermediate loading state, so callers already
  /// showing data (e.g. right after a drag-to-reorder) don't flash a spinner.
  Future<void> _fetch() async {
    try {
      final res = await ApiClient.instance.get('/products');
      state = AsyncValue.data(
        (res.data as List)
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> delete(int id) async {
    await ApiClient.instance.delete('/products/$id');
    await load();
  }

  Future<void> toggleAvailability(int id, bool available) async {
    await ApiClient.instance.put(
      '/products/$id',
      data: {'status': available ? 'active' : 'inactive'},
    );
    await load();
  }

  Future<void> updateCategory(Iterable<int> ids, int categoryId) async {
    for (final id in ids) {
      await ApiClient.instance.put(
        '/products/$id',
        data: {'category_id': categoryId},
      );
    }
    await _fetch();
  }

  Future<void> deleteMany(Iterable<int> ids) async {
    for (final id in ids) {
      await ApiClient.instance.delete('/products/$id');
    }
    await _fetch();
  }

  /// Persists a new relative order for [reordered]. This may be the full
  /// product list or just a single category's filtered subset — either way
  /// only the given items' sort_order values are touched, so reordering
  /// within one category never disturbs another category's ordering.
  Future<void> reorder(List<Product> reordered) async {
    final items = reordered
        .asMap()
        .entries
        .map((e) => {'id': e.value.id, 'sort_order': e.key})
        .toList();
    await ApiClient.instance.post('/products/reorder', data: items);
    await _fetch();
  }
}

final productsListProvider =
    StateNotifierProvider.autoDispose<
      ProductsNotifier,
      AsyncValue<List<Product>>
    >((_) => ProductsNotifier());

final categoriesProvider = FutureProvider.autoDispose<List<Category>>((
  ref,
) async {
  final res = await ApiClient.instance.get('/categories');
  return (res.data as List)
      .map((e) => Category.fromJson(e as Map<String, dynamic>))
      .toList();
});
