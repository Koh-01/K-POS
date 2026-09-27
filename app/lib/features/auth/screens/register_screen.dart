import 'package:flutter/material.dart';
import '../../../core/api/api_client.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/error_utils.dart';
import '../../../shared/widgets/kts_logo.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _key = GlobalKey<FormState>();
  final _restaurant = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _restaurant.dispose();
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_key.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ApiClient.instance.post('/auth/register', data: {
        'restaurant_name': _restaurant.text.trim(),
        'full_name': _name.text.trim(),
        'email': _email.text.trim(),
        'password': _password.text,
      });
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(title: const Text('Create Admin Account')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: _sent ? _success() : _form(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _success() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.mark_email_read_outlined, size: 64, color: AppTheme.primaryBlue),
      const SizedBox(height: 18),
      const Text('Check your email', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Text('We sent a verification link to ${_email.text.trim()}. Open it before signing in.', textAlign: TextAlign.center),
      const SizedBox(height: 24),
      ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Back to Sign In')),
    ],
  );

  Widget _form() => Form(
    key: _key,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: KtsLogo(size: 70)),
        const SizedBox(height: 18),
        const Text('Set up your restaurant', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 24),
        _field(_restaurant, 'Restaurant name', Icons.storefront_outlined),
        const SizedBox(height: 12),
        _field(_name, 'Your full name', Icons.person_outline),
        const SizedBox(height: 12),
        _field(_email, 'Email', Icons.email_outlined, email: true),
        const SizedBox(height: 12),
        _field(_password, 'Password', Icons.lock_outline, password: true),
        const SizedBox(height: 12),
        TextFormField(
          controller: _confirm,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Confirm password', prefixIcon: Icon(Icons.lock_outline)),
          validator: (value) => value != _password.text ? 'Passwords do not match' : null,
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(_error!, style: const TextStyle(color: AppTheme.danger), textAlign: TextAlign.center),
        ],
        const SizedBox(height: 22),
        ElevatedButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Create Account'),
        ),
      ],
    ),
  );

  TextFormField _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool email = false,
    bool password = false,
  }) => TextFormField(
    controller: controller,
    obscureText: password,
    keyboardType: email ? TextInputType.emailAddress : TextInputType.text,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
    validator: (value) {
      final text = value?.trim() ?? '';
      if (text.isEmpty) return 'Required';
      if (password && text.length < 8) return 'Use at least 8 characters';
      if (email && (!text.contains('@') || !text.split('@').last.contains('.'))) return 'Enter a valid email';
      return null;
    },
  );
}
