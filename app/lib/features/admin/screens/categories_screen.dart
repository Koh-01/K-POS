import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/category.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/error_utils.dart';

final categoriesProvider = FutureProvider.autoDispose<List<Category>>((ref) async {
  final res = await ApiClient.instance.get('/categories');
  return (res.data as List)
      .map((e) => Category.fromJson(e as Map<String, dynamic>))
      .toList();
});

class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({super.key});

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen> {
  List<Category>? _localCats;
  bool _reordering = false;
  String _search = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _syncFromProvider(List<Category> cats) {
    if (_localCats == null) _localCats = List.from(cats);
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    final cats = List<Category>.from(_localCats!);
    final moved = cats.removeAt(oldIndex);
    cats.insert(newIndex, moved);
    setState(() {
      _localCats = cats;
      _reordering = true;
    });

    final items = cats
        .asMap()
        .entries
        .map((e) => {'id': e.value.id, 'sort_order': e.key})
        .toList();

    try {
      await ApiClient.instance.post('/categories/reorder', data: items);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _reordering = false);
    }
  }

  Future<void> _showCategoryDialog({Category? category}) async {
    final nameCtrl = TextEditingController(text: category?.name ?? '');
    final sortCtrl =
        TextEditingController(text: (category?.sortOrder ?? 0).toString());

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(category == null ? 'Add Category' : 'Edit Category'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: sortCtrl,
              decoration: const InputDecoration(
                labelText: 'Sort Order',
                helperText: 'Lower number = shown first',
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (confirmed != true || nameCtrl.text.trim().isEmpty) return;
    final sortOrder = int.tryParse(sortCtrl.text.trim()) ?? 0;

    try {
      if (category == null) {
        await ApiClient.instance.post('/categories', data: {
          'name': nameCtrl.text.trim(),
          'sort_order': sortOrder,
        });
      } else {
        await ApiClient.instance.put('/categories/${category.id}', data: {
          'name': nameCtrl.text.trim(),
          'sort_order': sortOrder,
        });
      }
      final fresh = await ref.refresh(categoriesProvider.future);
      if (mounted) setState(() => _localCats = List.from(fresh));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  Future<void> _confirmDelete(Category category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Category?'),
        content: Text(
            'Delete "${category.name}"? Products in this category will become uncategorised.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ApiClient.instance.delete('/categories/${category.id}');
      final fresh = await ref.refresh(categoriesProvider.future);
      if (mounted) setState(() => _localCats = List.from(fresh));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Categories'),
        actions: [
          if (_reordering)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Add Category',
            onPressed: () => _showCategoryDialog(),
          ),
        ],
      ),
      body: categoriesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (cats) {
          _syncFromProvider(cats);
          final display = _search.isEmpty
              ? _localCats!
              : _localCats!
                  .where((c) => c.name
                      .toLowerCase()
                      .contains(_search.toLowerCase()))
                  .toList();

          if (_localCats!.isEmpty) {
            return const Center(
              child: Text('No categories yet. Tap + to add one.'),
            );
          }

          return Column(
            children: [
              // Search bar
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search categories...',
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
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: AppTheme.creamDeep,
                child: Row(
                  children: [
                    const Icon(Icons.drag_indicator_rounded,
                        size: 16, color: AppTheme.textHint),
                    const SizedBox(width: 6),
                    Text(
                      'Drag to reorder  •  Tap edit to set exact number',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textHint,
                      ),
                    ),
                  ],
                ),
              ),
              if (display.isEmpty)
                const Expanded(
                  child: Center(child: Text('No matching categories')),
                )
              else
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: display.length,
                  onReorder: _onReorder,
                  proxyDecorator: (child, index, animation) => Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  ),
                  itemBuilder: (ctx, i) {
                    final cat = display[i];
                    return _CategoryTile(
                      key: ValueKey(cat.id),
                      category: cat,
                      position: i,
                      onEdit: () => _showCategoryDialog(category: cat),
                      onDelete: () => _confirmDelete(cat),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final Category category;
  final int position;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CategoryTile({
    super.key,
    required this.category,
    required this.position,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ReorderableDragStartListener(
        index: position,
        child: const Icon(Icons.drag_indicator_rounded,
            color: AppTheme.textHint, size: 22),
      ),
      title: Text(category.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('Order: ${category.sortOrder}',
          style: const TextStyle(fontSize: 12, color: AppTheme.textHint)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit',
            onPressed: onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
            tooltip: 'Delete',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
