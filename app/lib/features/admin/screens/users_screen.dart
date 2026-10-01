import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/user.dart';
import '../../auth/providers/auth_provider.dart';
import '../../../shared/utils/error_utils.dart';

final _usersProvider = FutureProvider.autoDispose<List<User>>((ref) async {
  final res = await ApiClient.instance.get('/users');
  return (res.data as List)
      .map((e) => User.fromJson(e as Map<String, dynamic>))
      .toList();
});

class UsersScreen extends ConsumerWidget {
  const UsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usersAsync = ref.watch(_usersProvider);
    final currentUserId = ref.watch(authProvider).user?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Manage Users')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context, ref),
        child: const Icon(Icons.person_add),
      ),
      body: usersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (users) => ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemCount: users.length,
          itemBuilder: (ctx, i) => _UserTile(
            user: users[i],
            isSelf: users[i].id == currentUserId,
            onRefresh: () => ref.invalidate(_usersProvider),
          ),
        ),
      ),
    );
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _AddCashierDialog(),
    );
    if (created != true) return;
    ref.invalidate(_usersProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('User created successfully')),
        );
    }
  }
}

/// Validates each field in place and stays open until the cashier is
/// created, so a short password or a taken username never throws away what
/// the Admin already typed.
class _AddCashierDialog extends StatefulWidget {
  const _AddCashierDialog();

  @override
  State<_AddCashierDialog> createState() => _AddCashierDialogState();
}

class _AddCashierDialogState extends State<_AddCashierDialog> {
  static const _minPasswordLength = 8;

  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _fullName = TextEditingController();
  final _password = TextEditingController();
  bool _saving = false;
  bool _showPassword = false;
  String? _usernameError;
  String? _serverError;

  @override
  void dispose() {
    _username.dispose();
    _fullName.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _usernameError = null;
      _serverError = null;
    });
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ApiClient.instance.post(
        '/users',
        data: {
          'username': _username.text.trim(),
          'full_name': _fullName.text.trim(),
          'password': _password.text,
          'role': 'cashier',
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      final message = friendlyError(e);
      if (!mounted) return;
      setState(() {
        if (message.toLowerCase().contains('username')) {
          _usernameError = 'This username is already taken. Try another one.';
        } else {
          _serverError = message;
        }
      });
      _formKey.currentState!.validate();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Cashier'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _username,
                  enabled: !_saving,
                  decoration: InputDecoration(
                    labelText: 'Username',
                    helperText: 'Used to sign in on the POS',
                    errorMaxLines: 2,
                    errorText: _usernameError,
                  ),
                  textInputAction: TextInputAction.next,
                  onChanged: (_) {
                    if (_usernameError != null) {
                      setState(() => _usernameError = null);
                    }
                  },
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Enter a username' : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _fullName,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Full Name',
                    errorMaxLines: 2,
                  ),
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Enter the cashier\'s name'
                      : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _password,
                  enabled: !_saving,
                  obscureText: !_showPassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    helperText: 'At least $_minPasswordLength characters',
                    errorMaxLines: 2,
                    suffixIcon: IconButton(
                      tooltip: _showPassword
                          ? 'Hide password'
                          : 'Show password',
                      icon: Icon(
                        _showPassword ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _saving ? null : _submit(),
                  validator: (value) {
                    final length = (value ?? '').length;
                    if (length == 0) return 'Enter a password';
                    if (length < _minPasswordLength) {
                      return 'Password needs at least $_minPasswordLength characters '
                          '(${_minPasswordLength - length} more)';
                    }
                    return null;
                  },
                ),
                if (_serverError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _serverError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}

class _UserTile extends StatelessWidget {
  final User user;
  final bool isSelf;
  final VoidCallback onRefresh;

  const _UserTile({
    required this.user,
    required this.isSelf,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      tileColor: user.isActive ? null : Colors.grey.shade50,
      leading: CircleAvatar(
        backgroundColor: user.isAdmin
            ? const Color(0xFF1E6FD9).withValues(alpha: 0.12)
            : Colors.orange.shade100,
        child: Icon(
          user.isAdmin ? Icons.admin_panel_settings : Icons.person,
          color: user.isAdmin ? const Color(0xFF1E6FD9) : Colors.orange,
        ),
      ),
      title: Text(
        '${user.fullName}${isSelf ? ' (you)' : ''}',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: user.isActive ? null : Colors.grey,
        ),
      ),
      subtitle: Text(
        '@${user.username} · ${user.role}${user.isActive ? '' : ' · Inactive'}',
        style: TextStyle(color: user.isActive ? null : Colors.grey),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.lock_reset_outlined),
            tooltip: 'Change Password',
            onPressed: () => _changePassword(context),
          ),
          if (!isSelf && !user.isAdmin)
            IconButton(
              icon: const Icon(Icons.security_outlined),
              tooltip: 'Edit Permissions',
              onPressed: () => _editPermissions(context),
            ),
          if (!isSelf) ...[
            Switch(
              value: user.isActive,
              onChanged: (_) => _toggleStatus(context),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: 'Delete User',
              onPressed: () => _deleteUser(context),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    final ctrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Change Password — ${user.fullName}'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'New Password',
              helperText: 'At least 8 characters',
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Please enter a new password.';
              if (v.length < 8) {
                return 'Password must be at least 8 characters.';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed == true && ctrl.text.isNotEmpty && context.mounted) {
      try {
        await ApiClient.instance.put(
          '/users/${user.id}/password',
          data: {'new_password': ctrl.text},
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('Password updated')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      }
    }
  }

  Future<void> _editPermissions(BuildContext context) async {
    final perms = Map<String, bool>.from({
      'can_view_cash': user.permissions['can_view_cash'] as bool? ?? true,
      'can_add_cash': user.permissions['can_add_cash'] as bool? ?? true,
      'can_edit_cash': user.permissions['can_edit_cash'] as bool? ?? true,
      'can_delete_cash': user.permissions['can_delete_cash'] as bool? ?? true,
      'can_manage_catalog':
          user.permissions['can_manage_catalog'] as bool? ?? false,
      'can_manage_promotion':
          user.permissions['can_manage_promotion'] as bool? ?? false,
      'can_manage_payment':
          user.permissions['can_manage_payment'] as bool? ?? false,
      'can_manage_settings':
          user.permissions['can_manage_settings'] as bool? ?? false,
      'hide_salary_from_cash':
          user.permissions['hide_salary_from_cash'] as bool? ?? false,
    });

    final saved = await showDialog<Map<String, bool>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setState) => AlertDialog(
          title: Text('Permissions — ${user.fullName}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PermSwitch(
                  label: 'View Cash Records',
                  subtitle: 'Show cash in / out section in cashier app',
                  value: perms['can_view_cash']!,
                  onChanged: (v) => setState(() {
                    perms['can_view_cash'] = v;
                    if (!v) {
                      perms['can_add_cash'] = false;
                      perms['can_edit_cash'] = false;
                      perms['can_delete_cash'] = false;
                    }
                  }),
                ),
                _PermSwitch(
                  label: 'Add Cash Record',
                  subtitle: 'Create new cash in / out entries',
                  value: perms['can_add_cash']!,
                  enabled: perms['can_view_cash']!,
                  onChanged: (v) => setState(() => perms['can_add_cash'] = v),
                ),
                _PermSwitch(
                  label: 'Edit Cash Record',
                  subtitle: 'Modify existing cash in / out entries',
                  value: perms['can_edit_cash']!,
                  enabled: perms['can_view_cash']!,
                  onChanged: (v) => setState(() => perms['can_edit_cash'] = v),
                ),
                _PermSwitch(
                  label: 'Delete Cash Record',
                  subtitle: 'Remove cash in / out entries',
                  value: perms['can_delete_cash']!,
                  enabled: perms['can_view_cash']!,
                  onChanged: (v) =>
                      setState(() => perms['can_delete_cash'] = v),
                ),
                _PermSwitch(
                  label: 'Categories & Products',
                  subtitle: 'Add, edit & delete catalog items',
                  value: perms['can_manage_catalog']!,
                  onChanged: (v) =>
                      setState(() => perms['can_manage_catalog'] = v),
                ),
                _PermSwitch(
                  label: 'Promotions',
                  subtitle: 'Add, edit & delete promotions',
                  value: perms['can_manage_promotion']!,
                  onChanged: (v) =>
                      setState(() => perms['can_manage_promotion'] = v),
                ),
                _PermSwitch(
                  label: 'Payment Edit / Void',
                  subtitle: 'Edit orders & void payments',
                  value: perms['can_manage_payment']!,
                  onChanged: (v) =>
                      setState(() => perms['can_manage_payment'] = v),
                ),
                _PermSwitch(
                  label: 'Edit Settings',
                  subtitle: 'Store info, receipt format, tax, DuitNow QR',
                  value: perms['can_manage_settings']!,
                  onChanged: (v) =>
                      setState(() => perms['can_manage_settings'] = v),
                ),
                const Divider(),
                _PermSwitch(
                  label: 'Hide Salary Records',
                  subtitle: 'Salary entries hidden in cash view',
                  value: perms['hide_salary_from_cash']!,
                  onChanged: (v) =>
                      setState(() => perms['hide_salary_from_cash'] = v),
                  isWarning: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, perms),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != null && context.mounted) {
      try {
        await ApiClient.instance.put(
          '/users/${user.id}/permissions',
          data: saved,
        );
        onRefresh();
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('Permissions saved')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      }
    }
  }

  Future<void> _toggleStatus(BuildContext context) async {
    try {
      await ApiClient.instance.patch(
        '/users/${user.id}/status',
        data: {'is_active': !user.isActive},
      );
      onRefresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  Future<void> _deleteUser(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete User'),
        content: Text('Delete "${user.fullName}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
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
        await ApiClient.instance.delete('/users/${user.id}');
        onRefresh();
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('User deleted')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(friendlyError(e)),
                duration: const Duration(seconds: 4),
              ),
            );
        }
      }
    }
  }
}

class _PermSwitch extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool isWarning;
  final bool enabled;

  const _PermSwitch({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.isWarning = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isWarning ? Colors.orange.shade800 : null,
          ),
        ),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        value: value,
        onChanged: enabled ? onChanged : null,
        activeThumbColor: isWarning ? Colors.orange : null,
      ),
    );
  }
}
