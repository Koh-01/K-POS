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
      version: 5,
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
        order_type TEXT NOT NULL,
        notes TEXT,
        items_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_payments (
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

    await db.execute('''
      CREATE TABLE cached_user (
        id INTEGER PRIMARY KEY,
        username TEXT NOT NULL,
        full_name TEXT NOT NULL,
        role TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        permissions_json TEXT NOT NULL DEFAULT '{}'
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
      Database db, int oldVersion, int newVersion) async {
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
            'ALTER TABLE local_products ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE local_categories ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0');
      } catch (_) {}
    }
    if (oldVersion < 5) {
      try {
        await db.execute(
            "ALTER TABLE cached_user ADD COLUMN permissions_json TEXT NOT NULL DEFAULT '{}'");
      } catch (_) {}
    }
  }

  // ── Products ──────────────────────────────────────────────────────────────

  static Future<void> upsertProducts(List<Map<String, dynamic>> rows) async {
    final db = await instance;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert('local_products', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Map<String, dynamic>>> getProducts() async {
    final db = await instance;
    return db.query('local_products',
        where: 'is_available = 1', orderBy: 'sort_order ASC, id ASC');
  }

  // ── Categories ────────────────────────────────────────────────────────────

  static Future<void> upsertCategories(List<Map<String, dynamic>> rows) async {
    final db = await instance;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert('local_categories', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Map<String, dynamic>>> getCategories() async {
    final db = await instance;
    return db.query('local_categories', orderBy: 'sort_order ASC, id ASC');
  }

  // ── Tables ────────────────────────────────────────────────────────────────

  static Future<void> upsertTables(List<Map<String, dynamic>> rows) async {
    final db = await instance;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert('local_tables', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Map<String, dynamic>>> getTables() async {
    final db = await instance;
    return db.query('local_tables');
  }

  // ── Pending orders (offline) ───────────────────────────────────────────────

  static Future<void> savePendingOrder(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert('pending_orders', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getPendingOrders() async {
    final db = await instance;
    return db.query('pending_orders', where: 'synced = 0');
  }

  static Future<void> markOrderSynced(String offlineRef) async {
    final db = await instance;
    await db.update(
      'pending_orders',
      {'synced': 1},
      where: 'offline_ref = ?',
      whereArgs: [offlineRef],
    );
  }

  // ── Pending payments (offline) ─────────────────────────────────────────────

  static Future<void> savePendingPayment(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert('pending_payments', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getPendingPaymentsForOrder(
      String orderOfflineRef) async {
    final db = await instance;
    return db.query('pending_payments',
        where: 'order_offline_ref = ? AND synced = 0',
        whereArgs: [orderOfflineRef]);
  }

  static Future<void> markPaymentSynced(String offlineRef) async {
    final db = await instance;
    await db.update(
      'pending_payments',
      {'synced': 1},
      where: 'offline_ref = ?',
      whereArgs: [offlineRef],
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
      perms = jsonDecode(r['permissions_json'] as String? ?? '{}') as Map<String, dynamic>;
    } catch (_) {}
    return User(
      id: r['id'] as int,
      username: r['username'] as String,
      fullName: r['full_name'] as String,
      role: r['role'] as String,
      isActive: (r['is_active'] as int) == 1,
      permissions: perms,
    );
  }

  static Future<void> clearUser() async {
    final db = await instance;
    await db.delete('cached_user');
  }

  // ── Open orders cache ──────────────────────────────────────────────────────

  static Future<void> cacheOpenOrders(List<Order> orders) async {
    final db = await instance;
    await db.delete('local_open_orders');
    final batch = db.batch();
    for (final order in orders) {
      if (order.id == null) continue;
      batch.insert(
        'local_open_orders',
        {
          'id': order.id,
          'table_id': order.tableId,
          'table_name': order.tableName,
          'order_type': order.orderType,
          'notes': order.notes,
          'items_json': jsonEncode(order.items
              .map((i) => {
                    'product_id': i.productId,
                    'product_name': i.productName,
                    'quantity': i.quantity,
                    'unit_price': i.unitPrice,
                    if (i.weight != null) 'weight_kg': i.weight,
                  })
              .toList()),
          'created_at': order.createdAt?.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
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

    // Pending offline orders (not yet synced to server)
    final pendingRows =
        await db.query('pending_orders', where: 'synced = 0');

    // Build product name lookup from local cache
    final productRows = await db.query('local_products');
    final productNames = {
      for (final p in productRows) p['id'] as int: p['name'] as String,
    };

    final pendingOrders = pendingRows.map((row) {
      final rawItems =
          jsonDecode(row['items_json'] as String) as List;
      final items = rawItems.map((item) {
        final m = item as Map<String, dynamic>;
        return {
          'product_id': m['product_id'],
          'product_name':
              productNames[m['product_id'] as int] ?? '',
          'quantity': m['quantity'],
          'unit_price': m['unit_price'],
          if (m['weight_kg'] != null) 'weight_kg': m['weight_kg'],
        };
      }).toList();
      return Order.fromJson({
        'table_id': row['table_id'],
        'table_name': null,
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
