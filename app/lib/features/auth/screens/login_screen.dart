import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/kts_logo.dart';
import 'register_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  bool _obscure = true;
  bool _showUrlField = false;

  @override
  void initState() {
    super.initState();
    _loadSavedUrl();
  }

  Future<void> _loadSavedUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('base_url') ?? '';
    setState(() => _urlCtrl.text = saved);
  }

  Future<void> _saveUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('base_url', url);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await _saveUrl();
    await ref
        .read(authProvider.notifier)
        .login(_userCtrl.text.trim(), _passCtrl.text);
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final width = MediaQuery.sizeOf(context).width;
    final isTablet = width >= 768;

    if (isTablet) {
      return Scaffold(
        body: Row(
          children: [
            // Left brand panel
            Expanded(
              flex: 5,
              child: Container(
                color: AppTheme.charcoal,
                child: SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      KtsLogo(size: 100, onDark: true),
                      const SizedBox(height: 28),
                      const Text(
                        'K POS',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Point of Sale System',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 15,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 60),
                      Container(
                        width: 48,
                        height: 2,
                        color: AppTheme.primaryBlue,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Right form panel
            Expanded(
              flex: 6,
              child: Container(
                color: AppTheme.cream,
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(48),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: _LoginForm(
                          formKey: _formKey,
                          userCtrl: _userCtrl,
                          passCtrl: _passCtrl,
                          urlCtrl: _urlCtrl,
                          obscure: _obscure,
                          showUrlField: _showUrlField,
                          auth: auth,
                          onToggleObscure: () =>
                              setState(() => _obscure = !_obscure),
                          onToggleUrl: () =>
                              setState(() => _showUrlField = !_showUrlField),
                          onSubmit: _submit,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Phone layout
    return Scaffold(
      backgroundColor: AppTheme.charcoal,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  KtsLogo(size: 72, onDark: true),
                  const SizedBox(height: 16),
                  const Text(
                    'K POS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Point of Sale System',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 7,
              child: Container(
                decoration: const BoxDecoration(
                  color: AppTheme.cream,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
                  child: _LoginForm(
                    formKey: _formKey,
                    userCtrl: _userCtrl,
                    passCtrl: _passCtrl,
                    urlCtrl: _urlCtrl,
                    obscure: _obscure,
                    showUrlField: _showUrlField,
                    auth: auth,
                    onToggleObscure: () => setState(() => _obscure = !_obscure),
                    onToggleUrl: () =>
                        setState(() => _showUrlField = !_showUrlField),
                    onSubmit: _submit,
                    showTitle: false,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoginForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController userCtrl;
  final TextEditingController passCtrl;
  final TextEditingController urlCtrl;
  final bool obscure;
  final bool showUrlField;
  final dynamic auth;
  final VoidCallback onToggleObscure;
  final VoidCallback onToggleUrl;
  final VoidCallback onSubmit;
  final bool showTitle;

  const _LoginForm({
    required this.formKey,
    required this.userCtrl,
    required this.passCtrl,
    required this.urlCtrl,
    required this.obscure,
    required this.showUrlField,
    required this.auth,
    required this.onToggleObscure,
    required this.onToggleUrl,
    required this.onSubmit,
    this.showTitle = true,
  });

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showTitle) ...[
            const Text(
              'Welcome back',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Sign in to continue',
              style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 32),
          ] else ...[
            const Text(
              'Welcome back',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Sign in to continue',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 24),
          ],
          if (showUrlField) ...[
            TextFormField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                prefixIcon: Icon(Icons.dns_outlined),
                hintText: 'https://your-tunnel.trycloudflare.com',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
          ],
          TextFormField(
            controller: userCtrl,
            decoration: const InputDecoration(
              labelText: 'Email or cashier username',
              prefixIcon: Icon(Icons.person_outline),
            ),
            textInputAction: TextInputAction.next,
            validator: (v) =>
                v == null || v.isEmpty ? 'Enter email or username' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: passCtrl,
            obscureText: obscure,
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: onToggleObscure,
              ),
            ),
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => onSubmit(),
            validator: (v) => v == null || v.isEmpty ? 'Enter password' : null,
          ),
          if (auth.error != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.danger.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.danger.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: AppTheme.danger,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      auth.error!,
                      style: const TextStyle(
                        color: AppTheme.danger,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 22),
          ElevatedButton(
            onPressed: auth.isLoading ? null : onSubmit,
            child: auth.isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Sign In'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: auth.isLoading
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const RegisterScreen(),
                    ),
                  ),
            child: const Text('Create a restaurant Admin account'),
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: onToggleUrl,
            icon: Icon(
              showUrlField ? Icons.expand_less : Icons.dns_outlined,
              size: 16,
            ),
            label: Text(
              showUrlField ? 'Hide server settings' : 'Change server URL',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
