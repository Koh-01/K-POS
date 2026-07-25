import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/restaurant_table.dart';
import '../../../shared/utils/error_utils.dart';

final _tablesManageProvider =
    FutureProvider.autoDispose<List<RestaurantTable>>((ref) async {
  final res = await ApiClient.instance.get('/tables');
  return (res.data as List)
      .map((e) => RestaurantTable.fromJson(e as Map<String, dynamic>))
      .toList();
});

class TablesScreen extends ConsumerWidget {
  const TablesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tablesAsync = ref.watch(_tablesManageProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Manage Tables')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context, ref),
        child: const Icon(Icons.add),
      ),
      body: tablesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (tables) => tables.isEmpty
            ? const Center(
                child: Text('No tables yet.\nTap + to add one.',
                    textAlign: TextAlign.center))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemCount: tables.length,
                itemBuilder: (ctx, i) => _TableTile(
                  table: tables[i],
                  onRefresh: () => ref.invalidate(_tablesManageProvider),
                ),
              ),
      ),
    );
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Table'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Table Name (e.g. Table 5)'),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add')),
        ],
      ),
    );
    if (confirmed == true && ctrl.text.trim().isNotEmpty) {
      try {
        await ApiClient.instance
            .post('/tables', data: {'name': ctrl.text.trim()});
        ref.invalidate(_tablesManageProvider);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      }
    }
  }
}

class _TableTile extends StatelessWidget {
  final RestaurantTable table;
  final VoidCallback onRefresh;

  const _TableTile({required this.table, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: table.isOccupied
            ? Colors.red.shade100
            : Colors.green.shade100,
        child: Icon(
          Icons.table_restaurant,
          color: table.isOccupied ? Colors.red : Colors.green,
        ),
      ),
      title: Text(table.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        table.isOccupied ? 'Occupied' : 'Available',
        style: TextStyle(
            color: table.isOccupied ? Colors.red : Colors.green),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Rename',
            onPressed: () => _rename(context),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline,
                color: table.isOccupied ? Colors.grey : Colors.red),
            tooltip: table.isOccupied ? 'Cannot delete occupied table' : 'Delete',
            onPressed: table.isOccupied ? null : () => _delete(context),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: table.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Table'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Table Name'),
          textCapitalization: TextCapitalization.words,
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
    if (confirmed == true && ctrl.text.trim().isNotEmpty && context.mounted) {
      try {
        await ApiClient.instance
            .put('/tables/${table.id}', data: {'name': ctrl.text.trim()});
        onRefresh();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      }
    }
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Table'),
        content: Text('Delete "${table.name}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      try {
        await ApiClient.instance.delete('/tables/${table.id}');
        onRefresh();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      }
    }
  }
}
