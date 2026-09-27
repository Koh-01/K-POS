import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'features/auth/providers/auth_provider.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/cashier/screens/cashier_home_screen.dart';
import 'features/cashier/screens/order_screen.dart';
import 'features/cashier/screens/table_selection_screen.dart';
import 'features/cashier/providers/cashier_provider.dart';
import 'features/products/screens/products_screen.dart';
import 'features/products/screens/product_form_screen.dart';
import 'features/payments/screens/payment_screen.dart';
import 'features/payments/screens/payments_list_screen.dart';
import 'features/admin/screens/admin_home_screen.dart';
import 'features/admin/screens/dashboard_screen.dart';
import 'features/admin/screens/categories_screen.dart';
import 'features/admin/screens/tables_screen.dart';
import 'features/admin/screens/users_screen.dart';
import 'features/reports/screens/sales_report_screen.dart';
import 'features/reports/screens/annual_report_screen.dart';
import 'features/reports/screens/top_products_screen.dart';
import 'features/cash/screens/cash_records_screen.dart';
import 'features/promotions/screens/promotions_screen.dart';
import 'features/settings/screens/settings_screen.dart';
import 'features/admin/screens/login_logs_screen.dart';
import 'features/admin/screens/data_retention_screen.dart';
import 'features/admin/screens/admin_tools_screen.dart';
import 'features/salary/screens/salary_screen.dart';
import 'shared/theme/app_theme.dart';

final _themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.light);

final _routerNotifierProvider = ChangeNotifierProvider<_RouterNotifier>((ref) {
  return _RouterNotifier(ref);
});

class PosApp extends ConsumerStatefulWidget {
  const PosApp({super.key});

  @override
  ConsumerState<PosApp> createState() => _PosAppState();
}

class _PosAppState extends ConsumerState<PosApp> {
  late final GoRouter _router;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _wasOffline = false;
  Timer? _syncRetryTimer;
  bool _syncInProgress = false;

  @override
  void initState() {
    super.initState();
    _loadTheme();
    _listenConnectivity();
    // The WiFi interface can stay "connected" the whole time even when the
    // backend itself (reached over the internet via Cloudflare Tunnel, not
    // a local server) is unreachable — e.g. the router's WAN is down. That
    // means the offline→online transition connectivity_plus reports may
    // never fire, so pending orders/payments would sit queued forever.
    // Retry periodically as a backstop regardless of what the OS reports.
    _syncRetryTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _runBackgroundSync(),
    );
    _router = GoRouter(
      initialLocation: '/login',
      refreshListenable: ref.read(_routerNotifierProvider),
      redirect: (context, state) {
        final auth = ref.read(authProvider);
        if (auth.isLoading) return null;
        final isLogin = state.matchedLocation == '/login';
        if (!auth.isAuthenticated) return isLogin ? null : '/login';
        if (isLogin) {
          return auth.user!.isAdmin ? '/admin' : '/cashier';
        }
        if (!auth.user!.isAdmin && state.matchedLocation.startsWith('/admin')) {
          return '/cashier';
        }
        return null;
      },
      errorBuilder: (context, state) => const LoginScreen(),
      routes: [
        GoRoute(path: '/', redirect: (_, _) => '/login'),
        GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
        // Cashier routes
        GoRoute(
          path: '/cashier',
          builder: (_, _) => const CashierHomeScreen(),
          routes: [
            GoRoute(
              path: 'table-select',
              builder: (_, _) => const TableSelectionScreen(),
            ),
            GoRoute(
              path: 'order/:orderId',
              builder: (_, s) => OrderScreen(
                orderId: int.tryParse(s.pathParameters['orderId']!),
              ),
            ),
            // Reopening an order that was created offline and hasn't synced
            // yet (no server id, only a local ref). Kept as a real GoRouter
            // route — not an imperative Navigator.push — so that this
            // screen's own context.go('/cashier') on save/back reliably
            // pops it; mixing imperative pushes under GoRouter's declarative
            // stack leaves them stranded on top when go() rebuilds the
            // stack, which looked like the save/back button "doing nothing".
            GoRoute(
              path: 'order-offline/:ref',
              builder: (_, s) =>
                  OrderScreen(offlineRef: s.pathParameters['ref']),
            ),
            GoRoute(
              path: 'payment/:orderId',
              builder: (_, s) {
                final extra = s.extra as Map<String, dynamic>?;
                return PaymentScreen(
                  orderId: int.parse(s.pathParameters['orderId']!),
                  promotionId: extra?['promotionId'] as int?,
                  promoCode: extra?['promoCode'] as String?,
                );
              },
            ),
            GoRoute(path: 'cash', builder: (_, _) => const CashRecordsScreen()),
          ],
        ),
        // Admin routes
        GoRoute(
          path: '/admin',
          builder: (_, _) => const AdminHomeScreen(),
          routes: [
            GoRoute(
              path: 'dashboard',
              builder: (_, _) => const DashboardScreen(),
            ),
            GoRoute(
              path: 'products',
              builder: (_, _) => const ProductsScreen(),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (_, _) => const ProductFormScreen(),
                ),
                GoRoute(
                  path: 'edit/:id',
                  builder: (_, s) => ProductFormScreen(
                    productId: int.parse(s.pathParameters['id']!),
                  ),
                ),
              ],
            ),
            GoRoute(
              path: 'payments',
              builder: (_, _) => const PaymentsListScreen(),
            ),
            GoRoute(
              path: 'reports',
              builder: (_, _) => const SalesReportScreen(),
              routes: [
                GoRoute(
                  path: 'annual',
                  builder: (_, _) => const AnnualReportScreen(),
                ),
                GoRoute(
                  path: 'top-products',
                  builder: (_, _) => const TopProductsScreen(),
                ),
              ],
            ),
            GoRoute(path: 'cash', builder: (_, _) => const CashRecordsScreen()),
            GoRoute(
              path: 'promotions',
              builder: (_, _) => const PromotionsScreen(),
            ),
            GoRoute(
              path: 'categories',
              builder: (_, _) => const CategoriesScreen(),
            ),
            GoRoute(path: 'tables', builder: (_, _) => const TablesScreen()),
            GoRoute(path: 'users', builder: (_, _) => const UsersScreen()),
            GoRoute(
              path: 'settings',
              builder: (_, _) => const SettingsScreen(),
            ),
            GoRoute(
              path: 'login-logs',
              builder: (_, _) => const LoginLogsScreen(),
            ),
            GoRoute(
              path: 'data-retention',
              builder: (_, _) => const DataRetentionScreen(),
            ),
            GoRoute(path: 'tools', builder: (_, _) => const AdminToolsScreen()),
            GoRoute(path: 'salary', builder: (_, _) => const SalaryScreen()),
          ],
        ),
        // Shared routes accessible from both roles
        GoRoute(
          path: '/products',
          builder: (_, _) => const ProductsScreen(),
          routes: [
            GoRoute(path: 'new', builder: (_, _) => const ProductFormScreen()),
            GoRoute(
              path: 'edit/:id',
              builder: (_, s) => ProductFormScreen(
                productId: int.parse(s.pathParameters['id']!),
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/categories',
          builder: (_, _) => const CategoriesScreen(),
        ),
        GoRoute(
          path: '/payments',
          builder: (_, _) => const PaymentsListScreen(),
        ),
        GoRoute(
          path: '/promotions',
          builder: (_, _) => const PromotionsScreen(),
        ),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      ],
    );
  }

  void _listenConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _wasOffline) {
        _runBackgroundSync();
      }
      _wasOffline = !online;
    });
  }

  // Pushes everything queued locally (orders, payments, cash records) and,
  // if any of it actually went through, refreshes the screens that show
  // that data — otherwise a paid/synced order can keep showing as "open"
  // until something else happens to trigger a refetch.
  Future<void> _runBackgroundSync() async {
    if (_syncInProgress) return;
    _syncInProgress = true;
    try {
      final actions = <Future<void> Function()>[
        OrderService.syncPendingCheckoutQueue,
        CashRecordSync.syncPending,
      ];
      for (final action in actions) {
        try {
          await action();
        } catch (_) {
          // One rejected queue must not prevent the other independent queues
          // from syncing. Its local row remains available for inspection/retry.
        }
      }
    } finally {
      _syncInProgress = false;
      if (mounted) {
        ref.invalidate(openOrdersProvider);
        ref.invalidate(tablesProvider);
        ref.invalidate(pendingSyncCountProvider);
      }
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _syncRetryTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final dark = prefs.getBool('dark_mode') ?? false;
    ref.read(_themeModeProvider.notifier).state = dark
        ? ThemeMode.dark
        : ThemeMode.light;
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(_themeModeProvider);
    return MaterialApp.router(
      title: 'K POS',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}

class _RouterNotifier extends ChangeNotifier {
  _RouterNotifier(Ref ref) {
    ref.listen(authProvider, (_, _) => notifyListeners());
  }
}

final themeModeProvider = _themeModeProvider;
