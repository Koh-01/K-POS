import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/user.dart';
import '../models/order.dart';

class LocalDb {
  static Database? _db;

  static Future<Database> get instance async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      join(dbPath, 'pos_local.db'),
      version: 14,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE local_products (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        category_id INTEGER,
        category_name TEXT,
        price REAL NOT NULL,
        image_url TEXT,
        is_available INTEGER NOT NULL DEFAULT 1,
        sort_order INTEGER NOT NULL DEFAULT 0,
        sold_by_weight INTEGER NOT NULL DEFAULT 0,
        synced_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE local_categories (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE local_tables (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'available',
        current_order_id INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_orders (
        offline_ref TEXT PRIMARY KEY,
        table_id INTEGER,
        table_name TEXT,
        order_type TEXT NOT NULL,
        notes TEXT,
        items_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0,
        paid INTEGER NOT NULL DEFAULT 0,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_payments (
        offline_ref TEXT PRIMARY KEY,
        order_offline_ref TEXT NOT NULL,
        order_id INTEGER,
        payment_method TEXT NOT NULL,
        promotion_id INTEGER,
        subtotal REAL NOT NULL,
        discount_percent REAL NOT NULL DEFAULT 0,
        discount_amount REAL NOT NULL DEFAULT 0,
        service_charge_rate REAL NOT NULL DEFAULT 0,
        service_charge_amount REAL NOT NULL DEFAULT 0,
        sst_rate REAL NOT NULL DEFAULT 0,
        sst_amount REAL NOT NULL DEFAULT 0,
        grand_total REAL NOT NULL,
        cash_tendered REAL,
        change_amount REAL,
        items_json TEXT NOT NULL,
        table_name TEXT,
        order_type TEXT,
        created_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE cached_user (
        id INTEGER PRIMARY KEY,
        username TEXT NOT NULL,
        full_name TEXT NOT NULL,
        role TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        restaurant_id INTEGER NOT NULL DEFAULT 1,
        restaurant_name TEXT NOT NULL DEFAULT '',
        email TEXT,
        permissions_json TEXT NOT NULL DEFAULT '{}'
      )
    ''');

    await db.execute('''
      CREATE TABLE local_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_order_updates (
        order_id INTEGER PRIMARY KEY,
        table_id INTEGER,
        table_name TEXT,
        order_type TEXT NOT NULL,
        notes TEXT,
        items_json TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_cash_records (
        offline_ref TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        amount REAL NOT NULL,
        description TEXT,
        category TEXT,
        receipt_local_path TEXT,
        created_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE local_open_orders (
        id INTEGER PRIMARY KEY,
        table_id INTEGER,
        table_name TEXT,
        order_type TEXT NOT NULL,
        notes TEXT,
        items_json TEXT NOT NULL,
        created_at TEXT
      )
    ''');
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_payments (
          offline_ref TEXT PRIMARY KEY,
          order_offline_ref TEXT NOT NULL,
          payment_method TEXT NOT NULL,
          subtotal REAL NOT NULL,
          discount_amount REAL NOT NULL DEFAULT 0,
          service_charge_amount REAL NOT NULL DEFAULT 0,
          sst_amount REAL NOT NULL DEFAULT 0,
          grand_total REAL NOT NULL,
          cash_tendered REAL,
          change_amount REAL,
          items_json TEXT NOT NULL,
          table_name TEXT,
          order_type TEXT,
          created_at TEXT NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS cached_user (
          id INTEGER PRIMARY KEY,
          username TEXT NOT NULL,
          full_name TEXT NOT NULL,
          role TEXT NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 1,
          permissions_json TEXT NOT NULL DEFAULT '{}'
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS local_open_orders (
          id INTEGER PRIMARY KEY,
          table_id INTEGER,
          table_name TEXT,
          order_type TEXT NOT NULL,
          notes TEXT,
          items_json TEXT NOT NULL,
          created_at TEXT
        )
      ''');
    }
    if (oldVersion < 4) {
      try {
        await db.execute(
          'ALTER TABLE local_products ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE local_categories ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 5) {
      try {
        await db.execute(
          "ALTER TABLE cached_user ADD COLUMN permissions_json TEXT NOT NULL DEFAULT '{}'",
        );
      } catch (_) {}
    }
    if (oldVersion < 6) {
      try {
        await db.execute(
          'ALTER TABLE pending_payments ADD COLUMN order_id INTEGER',
        );
      } catch (_) {}
    }
    if (oldVersion < 7) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_cash_records (
          offline_ref TEXT PRIMARY KEY,
          type TEXT NOT NULL,
          amount REAL NOT NULL,
          description TEXT,
          category TEXT,
          receipt_local_path TEXT,
          created_at TEXT NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 8) {
      try {
        await db.execute(
          'ALTER TABLE pending_orders ADD COLUMN paid INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 9) {
      try {
        await db.execute(
          'ALTER TABLE local_products ADD COLUMN sold_by_weight INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 10) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_order_updates (
          order_id INTEGER PRIMARY KEY,
          table_id INTEGER,
          order_type TEXT NOT NULL,
          notes TEXT,
          items_json TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 11) {
      for (final sql in [
        'ALTER TABLE pending_orders ADD COLUMN table_name TEXT',
        'ALTER TABLE pending_orders ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE pending_orders ADD COLUMN last_error TEXT',
        'ALTER TABLE pending_order_updates ADD COLUMN table_name TEXT',
        'ALTER TABLE pending_payments ADD COLUMN discount_percent REAL NOT NULL DEFAULT 0',
        'ALTER TABLE pending_payments ADD COLUMN service_charge_rate REAL NOT NULL DEFAULT 0',
        'ALTER TABLE pending_payments ADD COLUMN sst_rate REAL NOT NULL DEFAULT 0',
        'ALTER TABLE pending_payments ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE pending_payments ADD COLUMN last_error TEXT',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // A partially upgraded installation may already have this column.
        }
      }
    }
    if (oldVersion < 12) {
      try {
        await db.execute(
          'ALTER TABLE pending_payments ADD COLUMN promotion_id INTEGER',
        );
      } catch (_) {
        // A partially upgraded installation may already have this column.
      }
    }
    if (oldVersion < 13) {
      for (final sql in [
        'ALTER TABLE pending_order_updates ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE pending_order_updates ADD COLUMN last_error TEXT',
        'ALTER TABLE pending_cash_records ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE pending_cash_records ADD COLUMN last_error TEXT',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // A partially upgraded installation may already have this column.
        }
      }
    }
    if (oldVersion < 14) {
      for (final sql in [
        'ALTER TABLE cached_user ADD COLUMN restaurant_id INTEGER NOT NULL DEFAULT 1',
        "ALTER TABLE cached_user ADD COLUMN restaurant_name TEXT NOT NULL DEFAULT ''",
        'ALTER TABLE cached_user ADD COLUMN email TEXT',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {}
      }
      await db.execute('''
        CREATE TABLE IF NOT EXISTS local_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    }
  }

  // ── Products ──────────────────────────────────────────────────────────────

  static Future<void> upsertProducts(List<Map<String, dynamic>> rows) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete('local_products');
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          'local_products',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<List<Map<String, dynamic>>> getProducts() async {
    final db = await instance;
    return db.query(
      'local_products',
      where: 'is_available = 1',
      orderBy: 'sort_order ASC, id ASC',
    );
  }

  // ── Categories ────────────────────────────────────────────────────────────

  static Future<void> upsertCategories(List<Map<String, dynamic>> rows) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete('local_categories');
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          'local_categories',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<List<Map<String, dynamic>>> getCategories() async {
    final db = await instance;
    return db.query('local_categories', orderBy: 'sort_order ASC, id ASC');
  }

  // ── Tables ────────────────────────────────────────────────────────────────

  static Future<void> upsertTables(List<Map<String, dynamic>> rows) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete('local_tables');
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          'local_tables',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<List<Map<String, dynamic>>> getTables() async {
    final db = await instance;
    return db.query('local_tables');
  }

  // ── Pending orders (offline) ───────────────────────────────────────────────

  static Future<void> savePendingOrder(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert(
      'pending_orders',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Creates a queued offline order on first call, or updates just the
  // editable fields on later calls for the same offlineRef — unlike
  // savePendingOrder's INSERT OR REPLACE, this never clobbers created_at/
  // synced/paid, and (critically) is only ever called with the *same*
  // offlineRef for a given order-editing session, so repeated auto-saves
  // update one row instead of piling up a new pending order every time.
  static Future<void> upsertPendingOrder({
    required String offlineRef,
    required int? tableId,
    required String? tableName,
    required String orderType,
    required String? notes,
    required String itemsJson,
  }) async {
    final db = await instance;
    final existing = await db.query(
      'pending_orders',
      where: 'offline_ref = ?',
      whereArgs: [offlineRef],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('pending_orders', {
        'offline_ref': offlineRef,
        'table_id': tableId,
        'table_name': tableName,
        'order_type': orderType,
        'notes': notes,
        'items_json': itemsJson,
        'created_at': DateTime.now().toIso8601String(),
        'synced': 0,
        'paid': 0,
        'retry_count': 0,
      });
    } else {
      await db.update(
        'pending_orders',
        {
          'table_id': tableId,
          'table_name': tableName,
          'order_type': orderType,
          'notes': notes,
          'items_json': itemsJson,
          'retry_count': 0,
          'last_error': null,
        },
        where: 'offline_ref = ?',
        whereArgs: [offlineRef],
      );
    }
  }

  static Future<List<Map<String, dynamic>>> getPendingOrders() async {
    final db = await instance;
    return db.query('pending_orders', where: 'synced = 0');
  }

  static Future<void> markOrderSyncError(
    String offlineRef,
    String message,
  ) async {
    final db = await instance;
    await db.rawUpdate(
      'UPDATE pending_orders '
      'SET retry_count = retry_count + 1, last_error = ? '
      'WHERE offline_ref = ?',
      [message, offlineRef],
    );
  }

  // Looks up a single queued offline order (never synced) for reopening it
  // in the order screen — the counterpart to getCachedOrderById, but keyed
  // by offline_ref since it has no server id yet.
  static Future<Order?> getPendingOrderByRef(String offlineRef) async {
    final db = await instance;
    final rows = await db.query(
      'pending_orders',
      where: 'offline_ref = ?',
      whereArgs: [offlineRef],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final rawItems = jsonDecode(row['items_json'] as String) as List;
    final productRows = await db.query('local_products');
    final productNames = {
      for (final p in productRows) p['id'] as int: p['name'] as String,
    };
    final items = rawItems.map((item) {
      final m = item as Map<String, dynamic>;
      return {
        'product_id': m['product_id'],
        'product_name':
            m['product_name'] as String? ??
            productNames[m['product_id'] as int] ??
            '',
        'quantity': m['quantity'],
        'unit_price': m['unit_price'],
        if (m['weight_kg'] != null) 'weight_kg': m['weight_kg'],
      };
    }).toList();
    return Order.fromJson({
      'table_id': row['table_id'],
      'table_name': row['table_name'],
      'order_type': row['order_type'],
      'notes': row['notes'],
      'items': items,
      'status': 'open',
      'offline_ref': row['offline_ref'],
      'created_at': row['created_at'],
    });
  }

  static Future<void> deletePendingOrder(String offlineRef) async {
    final db = await instance;
    await db.delete(
      'pending_orders',
      where: 'offline_ref = ?',
      whereArgs: [offlineRef],
    );
  }

  static Future<void> markOrderSynced(
    String offlineRef,
    int serverOrderId,
  ) async {
    final db = await instance;
    await db.transaction((txn) async {
      // Save the mapping before removing the order from the retry queue.
      // This lets a failed payment upload retry independently later.
      await txn.update(
        'pending_payments',
        {'order_id': serverOrderId},
        where: 'order_offline_ref = ? AND order_id IS NULL',
        whereArgs: [offlineRef],
      );
      await txn.update(
        'pending_orders',
        {'synced': 1, 'last_error': null},
        where: 'offline_ref = ?',
        whereArgs: [offlineRef],
      );
    });
  }

  // Marks an offline order as paid *locally*, independent of whether the
  // order itself has synced to the server yet. Needed so a checked-out
  // order stops showing up as "open" immediately, instead of lingering
  // until the next successful sync.
  static Future<void> markOrderPaidLocally(String offlineRef) async {
    final db = await instance;
    await db.update(
      'pending_orders',
      {'paid': 1},
      where: 'offline_ref = ?',
      whereArgs: [offlineRef],
    );
  }

  // ── Pending payments (offline) ─────────────────────────────────────────────

  static Future<void> savePendingPayment(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert(
      'pending_payments',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<Map<String, dynamic>>> getPendingPaymentsForOrder(
    String orderOfflineRef,
  ) async {
    final db = await instance;
    return db.query(
      'pending_payments',
      where: 'order_offline_ref = ? AND synced = 0',
      whereArgs: [orderOfflineRef],
    );
  }

  static Future<void> markPaymentSynced(String offlineRef) async {
    final db = await instance;
    await db.update(
      'pending_payments',
      {'synced': 1, 'last_error': null},
      where: 'offline_ref = ?',
      whereArgs: [offlineRef],
    );
  }

  static Future<bool> isPaymentPending(String offlineRef) async {
    final db = await instance;
    final rows = await db.query(
      'pending_payments',
      columns: ['offline_ref'],
      where: 'offline_ref = ? AND synced = 0',
      whereArgs: [offlineRef],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // Server data can briefly remain stale while a locally completed payment is
  // uploading. These IDs let the UI treat the local payment queue as the
  // source of truth so paid orders do not reappear as open during that window.
  static Future<Set<int>> getPendingPaidServerOrderIds() async {
    final db = await instance;
    final rows = await db.query(
      'pending_payments',
      distinct: true,
      columns: ['order_id'],
      where: 'synced = 0 AND order_id IS NOT NULL',
    );
    return rows.map((row) => (row['order_id'] as num).toInt()).toSet();
  }

  static Future<void> markPaymentSyncError(
    String offlineRef,
    String message,
  ) async {
    final db = await instance;
    await db.rawUpdate(
      'UPDATE pending_payments '
      'SET retry_count = retry_count + 1, last_error = ? '
      'WHERE offline_ref = ?',
      [message, offlineRef],
    );
  }

  // Payments taken offline for an order that already had a real server ID
  // (i.e. the order itself was never queued in pending_orders — only the
  // payment needs to be replayed once connectivity returns).
  static Future<List<Map<String, dynamic>>>
  getPendingPaymentsForRealOrders() async {
    final db = await instance;
    return db.query(
      'pending_payments',
      where: 'synced = 0 AND order_id IS NOT NULL',
    );
  }

  // ── Pending cash records (offline) ─────────────────────────────────────────

  static Future<void> savePendingCashRecord(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert(
      'pending_cash_records',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<Map<String, dynamic>>> getPendingCashRecords() async {
    final db = await instance;
    return db.query(
      'pending_cash_records',
      where: 'synced = 0',
      orderBy: 'created_at DESC',
    );
  }

  static Future<void> markCashRecordSynced(String offlineRef) async {
    final db = await instance;
    await db.update(
      'pending_cash_records',
      {'synced': 1, 'last_error': null},
      where: 'offline_ref = ?',
      whereArgs: [offlineRef],
    );
  }

  static Future<void> markCashRecordSyncError(
    String offlineRef,
    String message,
  ) async {
    final db = await instance;
    await db.rawUpdate(
      'UPDATE pending_cash_records '
      'SET retry_count = retry_count + 1, last_error = ? '
      'WHERE offline_ref = ?',
      [message, offlineRef],
    );
  }

  // ── Cached user (offline auth) ─────────────────────────────────────────────

  static Future<void> saveUser(User user) async {
    final db = await instance;
    await db.delete('cached_user');
    await db.insert('cached_user', {
      'id': user.id,
      'username': user.username,
      'full_name': user.fullName,
      'role': user.role,
      'is_active': user.isActive ? 1 : 0,
      'restaurant_id': user.restaurantId,
      'restaurant_name': user.restaurantName,
      'email': user.email,
      'permissions_json': jsonEncode(user.permissions),
    });
  }

  static Future<User?> getCachedUser() async {
    final db = await instance;
    final rows = await db.query('cached_user', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    Map<String, dynamic> perms = {};
    try {
      perms =
          jsonDecode(r['permissions_json'] as String? ?? '{}')
              as Map<String, dynamic>;
    } catch (_) {}
    return User(
      id: r['id'] as int,
      username: r['username'] as String,
      fullName: r['full_name'] as String,
      role: r['role'] as String,
      isActive: (r['is_active'] as int) == 1,
      restaurantId: r['restaurant_id'] as int? ?? 1,
      restaurantName: r['restaurant_name'] as String? ?? '',
      email: r['email'] as String?,
      permissions: perms,
    );
  }

  static Future<void> clearUser() async {
    final db = await instance;
    await db.delete('cached_user');
  }

  /// Bind all offline queues and caches to one restaurant. A restaurant
  /// switch is refused while unsynced business data still exists, preventing
  /// it from ever being uploaded under another tenant.
  static Future<bool> prepareForRestaurant(int restaurantId) async {
    final db = await instance;
    final ownerRows = await db.query(
      'local_metadata',
      where: 'key = ?',
      whereArgs: ['restaurant_id'],
      limit: 1,
    );
    final currentOwner = ownerRows.isEmpty
        ? null
        : int.tryParse(ownerRows.first['value'] as String);
    if (currentOwner == null) {
      final pending = await getPendingSyncCount();
      final cachedUsers = await db.query('cached_user', limit: 1);
      final legacyOwner = cachedUsers.isNotEmpty
          ? cachedUsers.first['restaurant_id'] as int? ?? 1
          : (pending > 0 ? 1 : null);
      if (legacyOwner != null && legacyOwner != restaurantId) {
        if (pending > 0) {
          throw StateError(
            'This tablet has $pending unsynced record(s) from the original restaurant. '
            'Sign in to that restaurant and finish syncing before switching.',
          );
        }
        await db.insert('local_metadata', {
          'key': 'restaurant_id',
          'value': legacyOwner.toString(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        // Continue into the safe cache-clearing restaurant switch below.
      } else {
        await db.insert('local_metadata', {
          'key': 'restaurant_id',
          'value': restaurantId.toString(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return false;
      }
    }
    if (currentOwner == restaurantId) return false;

    final pending = await getPendingSyncCount();
    if (pending > 0) {
      throw StateError(
        'This tablet has $pending unsynced record(s) from another restaurant. '
        'Sign in to that restaurant and finish syncing before switching.',
      );
    }

    await db.transaction((txn) async {
      for (final table in [
        'local_products',
        'local_categories',
        'local_tables',
        'pending_orders',
        'pending_payments',
        'pending_cash_records',
        'pending_order_updates',
        'local_open_orders',
        'cached_user',
      ]) {
        await txn.delete(table);
      }
      await txn.insert('local_metadata', {
        'key': 'restaurant_id',
        'value': restaurantId.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return true;
  }

  static Future<int> getPendingSyncCount() async {
    final db = await instance;
    final tables = <(String, String)>[
      ('pending_orders', 'synced = 0'),
      ('pending_payments', 'synced = 0'),
      ('pending_cash_records', 'synced = 0'),
      ('pending_order_updates', '1 = 1'),
    ];
    var total = 0;
    for (final entry in tables) {
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM ${entry.$1} WHERE ${entry.$2}',
      );
      total += Sqflite.firstIntValue(result) ?? 0;
    }
    return total;
  }

  // ── Open orders cache ──────────────────────────────────────────────────────

  static Future<void> cacheOpenOrders(List<Order> orders) async {
    final db = await instance;
    await db.delete('local_open_orders');
    final batch = db.batch();
    for (final order in orders) {
      if (order.id == null) continue;
      batch.insert('local_open_orders', {
        'id': order.id,
        'table_id': order.tableId,
        'table_name': order.tableName,
        'order_type': order.orderType,
        'notes': order.notes,
        'items_json': jsonEncode(
          order.items
              .map(
                (i) => {
                  'product_id': i.productId,
                  'product_name': i.productName,
                  'quantity': i.quantity,
                  'unit_price': i.unitPrice,
                  if (i.weight != null) 'weight_kg': i.weight,
                },
              )
              .toList(),
        ),
        'created_at': order.createdAt?.toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  // Removes a single order from the open-orders cache — used when a
  // real, already-synced order gets paid while offline, so it stops
  // showing as "open" immediately instead of waiting for the next
  // successful server fetch to overwrite the whole cache.
  static Future<void> removeCachedOpenOrder(int id) async {
    final db = await instance;
    await db.delete('local_open_orders', where: 'id = ?', whereArgs: [id]);
  }

  // Looks up a single previously-synced order from the open-orders cache —
  // used when a server order can't be re-fetched (e.g. paying it while the
  // connection that placed it has since dropped). Prefers a queued local
  // edit over the last-known-from-server snapshot, since the edit is newer.
  static Future<Order?> getCachedOrderById(int id) async {
    final pendingUpdate = await getPendingOrderUpdate(id);
    if (pendingUpdate != null) {
      final items = jsonDecode(pendingUpdate['items_json'] as String) as List;
      return Order.fromJson({
        'id': id,
        'table_id': pendingUpdate['table_id'],
        'table_name': pendingUpdate['table_name'],
        'order_type': pendingUpdate['order_type'],
        'notes': pendingUpdate['notes'],
        'items': items,
        'status': 'open',
      });
    }

    final db = await instance;
    final rows = await db.query(
      'local_open_orders',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final items = jsonDecode(row['items_json'] as String) as List;
    return Order.fromJson({
      'id': row['id'],
      'table_id': row['table_id'],
      'table_name': row['table_name'],
      'order_type': row['order_type'],
      'notes': row['notes'],
      'items': items,
      'status': 'open',
      'created_at': row['created_at'],
    });
  }

  // ── Pending updates to already-synced orders (offline) ─────────────────────
  // Distinct from pending_orders (brand-new orders never sent to the
  // server): this is for edits to an order that already has a real ID,
  // made while the PUT to save them failed. Keyed by order_id — later
  // edits simply replace the queued snapshot.

  static Future<void> upsertPendingOrderUpdate({
    required int orderId,
    required int? tableId,
    required String? tableName,
    required String orderType,
    required String? notes,
    required String itemsJson,
  }) async {
    final db = await instance;
    await db.insert('pending_order_updates', {
      'order_id': orderId,
      'table_id': tableId,
      'table_name': tableName,
      'order_type': orderType,
      'notes': notes,
      'items_json': itemsJson,
      'updated_at': DateTime.now().toIso8601String(),
      'retry_count': 0,
      'last_error': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, dynamic>?> getPendingOrderUpdate(
    int orderId,
  ) async {
    final db = await instance;
    final rows = await db.query(
      'pending_order_updates',
      where: 'order_id = ?',
      whereArgs: [orderId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<List<Map<String, dynamic>>> getAllPendingOrderUpdates() async {
    final db = await instance;
    return db.query('pending_order_updates');
  }

  static Future<void> deletePendingOrderUpdate(int orderId) async {
    final db = await instance;
    await db.delete(
      'pending_order_updates',
      where: 'order_id = ?',
      whereArgs: [orderId],
    );
  }

  static Future<void> markOrderUpdateSyncError(
    int orderId,
    String message,
  ) async {
    final db = await instance;
    await db.rawUpdate(
      'UPDATE pending_order_updates '
      'SET retry_count = retry_count + 1, last_error = ? '
      'WHERE order_id = ?',
      [message, orderId],
    );
  }

  static Future<List<Map<String, dynamic>>> getPendingSyncIssues() async {
    final db = await instance;
    return db.rawQuery('''
      SELECT 'Order' AS kind, offline_ref AS reference,
             retry_count, last_error
      FROM pending_orders
      WHERE synced = 0 AND last_error IS NOT NULL
      UNION ALL
      SELECT 'Payment' AS kind, offline_ref AS reference,
             retry_count, last_error
      FROM pending_payments
      WHERE synced = 0 AND last_error IS NOT NULL
      UNION ALL
      SELECT 'Cash record' AS kind, offline_ref AS reference,
             retry_count, last_error
      FROM pending_cash_records
      WHERE synced = 0 AND last_error IS NOT NULL
      UNION ALL
      SELECT 'Order edit' AS kind, CAST(order_id AS TEXT) AS reference,
             retry_count, last_error
      FROM pending_order_updates
      WHERE last_error IS NOT NULL
      ORDER BY retry_count DESC
    ''');
  }

  // Returns cached server orders + unsynced offline orders
  static Future<List<Order>> getLocalOrders() async {
    final db = await instance;

    // Cached server orders
    final cachedRows = await db.query('local_open_orders');
    final cachedOrders = cachedRows.map((row) {
      final items = jsonDecode(row['items_json'] as String) as List;
      return Order.fromJson({
        'id': row['id'],
        'table_id': row['table_id'],
        'table_name': row['table_name'],
        'order_type': row['order_type'],
        'notes': row['notes'],
        'items': items,
        'status': 'open',
        'created_at': row['created_at'],
      });
    }).toList();

    // Pending offline orders (not yet synced to server, and not already
    // paid — a paid order isn't "open" anymore even before it syncs)
    final pendingRows = await db.query(
      'pending_orders',
      where: 'synced = 0 AND paid = 0',
    );

    // Build product name lookup from local cache
    final productRows = await db.query('local_products');
    final productNames = {
      for (final p in productRows) p['id'] as int: p['name'] as String,
    };

    final pendingOrders = pendingRows.map((row) {
      final rawItems = jsonDecode(row['items_json'] as String) as List;
      final items = rawItems.map((item) {
        final m = item as Map<String, dynamic>;
        return {
          'product_id': m['product_id'],
          'product_name':
              m['product_name'] as String? ??
              productNames[m['product_id'] as int] ??
              '',
          'quantity': m['quantity'],
          'unit_price': m['unit_price'],
          if (m['weight_kg'] != null) 'weight_kg': m['weight_kg'],
        };
      }).toList();
      return Order.fromJson({
        'table_id': row['table_id'],
        'table_name': row['table_name'],
        'order_type': row['order_type'],
        'notes': row['notes'],
        'items': items,
        'status': 'open',
        'offline_ref': row['offline_ref'],
        'created_at': row['created_at'],
      });
    }).toList();

    return [...cachedOrders, ...pendingOrders];
  }
}
