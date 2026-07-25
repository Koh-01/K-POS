import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import '../providers/settings_provider.dart';
import '../../auth/providers/auth_provider.dart';
import '../../../app.dart';
import '../../../core/api/api_client.dart';
import '../../../core/constants/api_constants.dart';
import '../../payments/services/receipt_printer.dart';
import 'package:blue_thermal_printer/blue_thermal_printer.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _storeNameCtrl = TextEditingController();
  final _storeAddressCtrl = TextEditingController();
  final _storePhoneCtrl = TextEditingController();
  final _storeEmailCtrl = TextEditingController();
  final _taxRegCtrl = TextEditingController();
  final _sstRateCtrl = TextEditingController();
  final _serviceRateCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _receiptHeaderCtrl = TextEditingController();
  final _receiptFooterCtrl = TextEditingController();
  bool _enableSst = false;
  bool _enableServiceCharge = false;
  bool _paymentToCashRecord = false;
  bool _saving = false;
  bool _darkMode = false;
  int _receiptHeaderSize = 1;
  int _receiptHeaderAlign = 1;
  int _receiptFooterSize = 0;
  int _receiptFooterAlign = 1;
  bool _receiptShowLogo = false;

  List<BluetoothDevice> _devices = [];
  String? _connectedAddress;
  bool _loadingDevices = false;

  String? _qrImagePath;
  bool _uploadingQr = false;

  String? _logoPath;
  bool _uploadingLogo = false;

  // Auto-save: don't start debouncing edits until both the local prefs and
  // the server settings have populated the fields once, or the initial
  // population itself would be mistaken for a user edit and re-saved.
  bool _prefsLoaded = false;
  bool _settingsLoaded = false;
  bool get _readyForAutoSave => _prefsLoaded && _settingsLoaded;
  Timer? _autoSaveDebounce;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    // Refresh user from server so permission changes take effect without re-login
    ref.read(authProvider.notifier).refreshUser();
    final settingsAsync = ref.read(settingsMutableProvider);
    settingsAsync.whenData((s) {
      _storeNameCtrl.text = s.storeName;
      _storeAddressCtrl.text = s.storeAddress ?? '';
      _storePhoneCtrl.text = s.storePhone ?? '';
      _storeEmailCtrl.text = s.storeEmail ?? '';
      _taxRegCtrl.text = s.taxRegistrationNumber ?? '';
      _sstRateCtrl.text = (s.sstRate * 100).toStringAsFixed(1);
      _serviceRateCtrl.text = (s.serviceChargeRate * 100).toStringAsFixed(1);
      _enableSst = s.enableSst;
      _enableServiceCharge = s.enableServiceCharge;
      _paymentToCashRecord = s.paymentToCashRecord;
      _qrImagePath = s.duitnowQrImageUrl;
      _logoPath = s.storeLogoPath;
      _receiptHeaderCtrl.text = s.receiptHeader;
      _receiptHeaderSize = s.receiptHeaderSize;
      _receiptHeaderAlign = s.receiptHeaderAlign;
      _receiptFooterCtrl.text = s.receiptFooter;
      _receiptFooterSize = s.receiptFooterSize;
      _receiptFooterAlign = s.receiptFooterAlign;
      _receiptShowLogo = s.receiptShowLogo;
      _settingsLoaded = true;
      if (mounted) setState(() {});
    });
    for (final c in [
      _storeNameCtrl,
      _storeAddressCtrl,
      _storePhoneCtrl,
      _storeEmailCtrl,
      _taxRegCtrl,
      _sstRateCtrl,
      _serviceRateCtrl,
      _receiptHeaderCtrl,
      _receiptFooterCtrl,
      _baseUrlCtrl,
    ]) {
      c.addListener(_scheduleAutoSave);
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _darkMode = prefs.getBool('dark_mode') ?? false;
      _baseUrlCtrl.text = prefs.getString('base_url') ?? '';
      _connectedAddress = prefs.getString('printer_address');
      _prefsLoaded = true;
    });
  }

  void _scheduleAutoSave() {
    if (!_readyForAutoSave) return;
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 700), _saveSettings);
  }

  Future<void> _saveSettings() async {
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await ref.read(settingsMutableProvider.notifier).save({
        'store_name': _storeNameCtrl.text.trim(),
        'store_address': _storeAddressCtrl.text.trim(),
        'store_phone': _storePhoneCtrl.text.trim(),
        'store_email': _storeEmailCtrl.text.trim(),
        'tax_registration_number': _taxRegCtrl.text.trim(),
        'sst_rate': (double.tryParse(_sstRateCtrl.text) ?? 6.0) / 100,
        'service_charge_rate':
            (double.tryParse(_serviceRateCtrl.text) ?? 10.0) / 100,
        'sst_enabled': _enableSst,
        'service_charge_enabled': _enableServiceCharge,
        'payment_to_cash_record': _paymentToCashRecord,
        'receipt_header': _receiptHeaderCtrl.text.trim(),
        'receipt_header_size': _receiptHeaderSize,
        'receipt_header_align': _receiptHeaderAlign,
        'receipt_footer': _receiptFooterCtrl.text.trim(),
        'receipt_footer_size': _receiptFooterSize,
        'receipt_footer_align': _receiptFooterAlign,
        'receipt_show_logo': _receiptShowLogo,
      });
      final prefs = await SharedPreferences.getInstance();
      final url = _baseUrlCtrl.text.trim();
      if (url.isNotEmpty) await prefs.setString('base_url', url);
      // Auto-saved silently — no confirmation snackbar on every edit; the
      // AppBar "Saving…" indicator is enough feedback.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to save settings. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleDarkMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', value);
    ref.read(themeModeProvider.notifier).state =
        value ? ThemeMode.dark : ThemeMode.light;
    setState(() => _darkMode = value);
  }

  Future<void> _uploadQrImage() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (picked == null) return;

    setState(() => _uploadingQr = true);
    try {
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(picked.path,
            filename: 'duitnow_qr.jpg'),
      });
      final res = await ApiClient.instance.post('/settings/duitnow-qr', data: form);
      final path = res.data['duitnow_qr_image_url'] as String?;

      final prefs = await SharedPreferences.getInstance();
      final base = (prefs.getString('base_url') ??
              ApiConstants.defaultBaseUrl)
          .replaceAll(RegExp(r'/$'), '');
      setState(() => _qrImagePath =
          (path != null && path.isNotEmpty) ? '$base/$path' : null);

      ref.invalidate(settingsMutableProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('DuitNow QR updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Upload failed. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _uploadingQr = false);
    }
  }

  Future<void> _uploadLogoImage() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (picked == null) return;

    setState(() => _uploadingLogo = true);
    try {
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(picked.path,
            filename: 'store_logo.jpg'),
      });
      final res = await ApiClient.instance.post('/settings/store-logo', data: form);
      final path = res.data['store_logo_path'] as String?;

      final prefs = await SharedPreferences.getInstance();
      final base = (prefs.getString('base_url') ??
              ApiConstants.defaultBaseUrl)
          .replaceAll(RegExp(r'/$'), '');
      setState(() => _logoPath =
          (path != null && path.isNotEmpty) ? '$base/$path' : null);

      ref.invalidate(settingsMutableProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Store logo updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Upload failed. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
  }

  Future<void> _loadBluetoothDevices() async {
    setState(() => _loadingDevices = true);
    try {
      final devices = await ReceiptPrinter.getBondedDevices();
      setState(() => _devices = devices);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not scan Bluetooth devices. Make sure Bluetooth is enabled.')));
      }
    } finally {
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  Future<void> _connectDevice(BluetoothDevice device) async {
    try {
      await ReceiptPrinter.connect(device);
      await ReceiptPrinter.savePrinterAddress(device.address ?? '');
      setState(() => _connectedAddress = device.address);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Connected to ${device.name}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not connect to printer. Please try again.')));
      }
    }
  }

  Future<void> _testPrint() async {
    try {
      await ReceiptPrinter.testPrint();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Test print sent')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Print failed. Make sure the printer is connected.')));
      }
    }
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    _storeNameCtrl.dispose();
    _storeAddressCtrl.dispose();
    _storePhoneCtrl.dispose();
    _storeEmailCtrl.dispose();
    _taxRegCtrl.dispose();
    _sstRateCtrl.dispose();
    _serviceRateCtrl.dispose();
    _baseUrlCtrl.dispose();
    _receiptHeaderCtrl.dispose();
    _receiptFooterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).user;
    final canEdit = user?.canManageSettings ?? true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          if (canEdit && _saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white70),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!canEdit)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                border: Border.all(color: Colors.orange.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, size: 16, color: Colors.orange.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'View only — you do not have permission to edit settings.',
                      style: TextStyle(fontSize: 13, color: Colors.orange.shade800),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                IgnorePointer(
                  ignoring: !canEdit,
                  child: Opacity(
                    opacity: canEdit ? 1.0 : 0.65,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
          _Section(
            title: 'Store Info',
            children: [
              _Field(label: 'Store Name', ctrl: _storeNameCtrl),
              _Field(label: 'Address', ctrl: _storeAddressCtrl),
              _Field(label: 'Phone', ctrl: _storePhoneCtrl),
              _Field(
                  label: 'Email',
                  ctrl: _storeEmailCtrl,
                  keyboardType: TextInputType.emailAddress),
              _Field(
                  label: 'Tax Registration No.',
                  ctrl: _taxRegCtrl),
            ],
          ),
          _Section(
            title: 'Store Logo',
            children: [
              if (_logoPath != null && _logoPath!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      _logoPath!,
                      height: 100,
                      errorBuilder: (ctx, err, st) => const Text(
                          'Cannot load logo',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: _uploadingLogo
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.image_outlined),
                  label: Text(_logoPath != null && _logoPath!.isNotEmpty
                      ? 'Replace Store Logo'
                      : 'Upload Store Logo'),
                  onPressed: _uploadingLogo ? null : _uploadLogoImage,
                ),
              ),
            ],
          ),
          _Section(
            title: 'Tax & Charges',
            children: [
              SwitchListTile(
                title: const Text('Enable SST'),
                value: _enableSst,
                onChanged: (v) {
                  setState(() => _enableSst = v);
                  _scheduleAutoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (_enableSst)
                _Field(
                    label: 'SST Rate (%)',
                    ctrl: _sstRateCtrl,
                    keyboardType: TextInputType.number),
              SwitchListTile(
                title: const Text('Enable Service Charge'),
                value: _enableServiceCharge,
                onChanged: (v) {
                  setState(() => _enableServiceCharge = v);
                  _scheduleAutoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (_enableServiceCharge)
                _Field(
                    label: 'Service Charge Rate (%)',
                    ctrl: _serviceRateCtrl,
                    keyboardType: TextInputType.number),
            ],
          ),
          _Section(
            title: 'Cash Records',
            children: [
              SwitchListTile(
                title: const Text('Add Payment Income to Cash Records'),
                subtitle: const Text(
                    'Every completed payment also creates a Cash In record'),
                value: _paymentToCashRecord,
                onChanged: (v) {
                  setState(() => _paymentToCashRecord = v);
                  _scheduleAutoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          _Section(
            title: 'Receipt',
            children: [
              SwitchListTile(
                title: const Text('Show Logo on Receipt'),
                value: _receiptShowLogo,
                onChanged: (v) {
                  setState(() => _receiptShowLogo = v);
                  _scheduleAutoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              _Field(label: 'Header Text', ctrl: _receiptHeaderCtrl),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _DropdownField(
                      label: 'Header Size',
                      value: _receiptHeaderSize,
                      items: const {0: 'Small', 1: 'Normal', 2: 'Large'},
                      onChanged: (v) {
                        setState(() => _receiptHeaderSize = v!);
                        _scheduleAutoSave();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DropdownField(
                      label: 'Header Align',
                      value: _receiptHeaderAlign,
                      items: const {0: 'Left', 1: 'Center', 2: 'Right'},
                      onChanged: (v) {
                        setState(() => _receiptHeaderAlign = v!);
                        _scheduleAutoSave();
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Field(label: 'Footer Text', ctrl: _receiptFooterCtrl),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _DropdownField(
                      label: 'Footer Size',
                      value: _receiptFooterSize,
                      items: const {0: 'Small', 1: 'Normal', 2: 'Large'},
                      onChanged: (v) {
                        setState(() => _receiptFooterSize = v!);
                        _scheduleAutoSave();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DropdownField(
                      label: 'Footer Align',
                      value: _receiptFooterAlign,
                      items: const {0: 'Left', 1: 'Center', 2: 'Right'},
                      onChanged: (v) {
                        setState(() => _receiptFooterAlign = v!);
                        _scheduleAutoSave();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
          _Section(
            title: 'Server',
            children: [
              _Field(
                  label: 'Backend URL',
                  ctrl: _baseUrlCtrl,
                  hint: 'https://your-tunnel.trycloudflare.com'),
            ],
          ),
          _Section(
            title: 'Appearance',
            children: [
              SwitchListTile(
                title: const Text('Dark Mode'),
                value: _darkMode,
                onChanged: _toggleDarkMode,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          _Section(
            title: 'DuitNow QR',
            children: [
              if (_qrImagePath != null && _qrImagePath!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      _qrImagePath!,
                      height: 160,
                      errorBuilder: (ctx, err, st) => const Text(
                          'Cannot load QR image',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: _uploadingQr
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.qr_code),
                  label: Text(_qrImagePath != null && _qrImagePath!.isNotEmpty
                      ? 'Replace QR Image'
                      : 'Upload QR Image'),
                  onPressed: _uploadingQr ? null : _uploadQrImage,
                ),
              ),
            ],
          ),
                      ], // Column children (locked sections end)
                    ), // Column
                  ), // Opacity
                ), // IgnorePointer
                // Bluetooth Printer — always interactive regardless of permission
                _Section(
                  title: 'Bluetooth Printer',
            children: [
              if (_connectedAddress != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('Connected: $_connectedAddress',
                      style: const TextStyle(color: Color(0xFF10B981))),
                ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: _loadingDevices
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.bluetooth_searching),
                      label: const Text('Scan Devices'),
                      onPressed:
                          _loadingDevices ? null : _loadBluetoothDevices,
                    ),
                  ),
                  if (_connectedAddress != null) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.print),
                      label: const Text('Test'),
                      onPressed: _testPrint,
                    ),
                  ],
                ],
              ),
              ..._devices.map(
                (d) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.print_outlined),
                  title: Text(d.name ?? 'Unknown'),
                  subtitle: Text(d.address ?? ''),
                  trailing: d.address == _connectedAddress
                      ? const Icon(Icons.check_circle,
                          color: Color(0xFF10B981))
                      : TextButton(
                          onPressed: () => _connectDevice(d),
                          child: const Text('Connect')),
                ),
              ),
            ],
          ),
              ], // ListView children
            ), // ListView
          ), // Expanded
        ], // Column children (body)
      ), // Column (body)
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(title.toUpperCase(),
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                    letterSpacing: 0.8)),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: children),
            ),
          ),
          const SizedBox(height: 12),
        ],
      );
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String? hint;
  final TextInputType keyboardType;

  const _Field({
    required this.label,
    required this.ctrl,
    this.hint,
    this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextFormField(
          controller: ctrl,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            isDense: true,
          ),
        ),
      );
}

class _DropdownField extends StatelessWidget {
  final String label;
  final int value;
  final Map<int, String> items;
  final ValueChanged<int?> onChanged;

  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          DropdownButtonFormField<int>(
            value: value,
            isDense: true,
            decoration: const InputDecoration(isDense: true),
            items: items.entries
                .map((e) => DropdownMenuItem(
                    value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: onChanged,
          ),
        ],
      );
}
