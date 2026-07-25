import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/kts_logo.dart';

class AdminHomeScreen extends ConsumerWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final sections = [
      _Section('Overview', [
        _Tile('Dashboard', Icons.bar_chart_rounded, '/admin/dashboard',
            const Color(0xFF4A90D9)),
      ]),
      _Section('Operations', [
        _Tile('Orders', Icons.receipt_long_rounded, '/cashier',
            const Color(0xFF3D9E6E)),
        _Tile('Tables', Icons.table_restaurant_rounded, '/admin/tables',
            const Color(0xFF4A90D9)),
        _Tile('Products', Icons.inventory_2_rounded, '/admin/products',
            const Color(0xFFC9953A)),
        _Tile('Categories', Icons.label_rounded, '/admin/categories',
            const Color(0xFF5B6AD9)),
        _Tile('Promotions', Icons.local_offer_rounded, '/admin/promotions',
            const Color(0xFFD94F8A)),
      ]),
      _Section('Finance', [
        _Tile('Payments', Icons.payments_rounded, '/admin/payments',
            const Color(0xFF7C6FD9)),
        _Tile('Cash Records', Icons.account_balance_wallet_rounded,
            '/admin/cash', const Color(0xFF38A89D)),
        _Tile('Salary', Icons.payments_outlined, '/admin/salary',
            const Color(0xFF3D9E6E)),
      ]),
      _Section('Reports', [
        _Tile('Sales Report', Icons.analytics_rounded, '/admin/reports',
            const Color(0xFFE07A3A)),
        _Tile('Annual Report', Icons.calendar_month_rounded,
            '/admin/reports/annual', const Color(0xFF38A89D)),
        _Tile('Top Products', Icons.leaderboard_rounded,
            '/admin/reports/top-products', const Color(0xFFE07A3A)),
      ]),
      _Section('System', [
        _Tile('Users', Icons.manage_accounts_rounded, '/admin/users',
            const Color(0xFF8B6FD9)),
        _Tile('Settings', Icons.settings_rounded, '/admin/settings',
            const Color(0xFF7A7A7A)),
        _Tile('Login Logs', Icons.history_rounded, '/admin/login-logs',
            const Color(0xFF5B6AD9)),
        _Tile('Data Retention', Icons.delete_sweep_rounded,
            '/admin/data-retention', const Color(0xFFD94F4F)),
        _Tile('Admin Tools', Icons.build_rounded, '/admin/tools',
            const Color(0xFF5A6A7A)),
      ]),
    ];

    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: Row(
          children: [
            KtsLogo(size: 32, onDark: true),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'KTS POS',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                Text(
                  user.fullName,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Logout',
            onPressed: () => ref.read(authProvider.notifier).logout(),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 680;
          final maxWidth = isWide ? 720.0 : double.infinity;

          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: sections.length,
                itemBuilder: (ctx, i) => _SectionView(section: sections[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Tile {
  final String label;
  final IconData icon;
  final String route;
  final Color color;
  const _Tile(this.label, this.icon, this.route, this.color);
}

class _Section {
  final String title;
  final List<_Tile> tiles;
  const _Section(this.title, this.tiles);
}

class _SectionView extends StatelessWidget {
  final _Section section;
  const _SectionView({required this.section});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              section.title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppTheme.textHint,
                letterSpacing: 0.8,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < section.tiles.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 68),
                  _TileRow(tile: section.tiles[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TileRow extends StatelessWidget {
  final _Tile tile;
  const _TileRow({required this.tile});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push(tile.route),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: tile.color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(tile.icon, color: tile.color, size: 19),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                tile.label,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppTheme.textHint, size: 20),
          ],
        ),
      ),
    );
  }
}
