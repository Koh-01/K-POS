import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/api/api_client.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/models/store_settings.dart';

final settingsProvider = FutureProvider<StoreSettings>((ref) async {
  try {
    final res = await ApiClient.instance.get('/settings');
    return StoreSettings.fromJson(res.data as Map<String, dynamic>);
  } catch (_) {
    return StoreSettings.defaults;
  }
});

class SettingsNotifier extends StateNotifier<AsyncValue<StoreSettings>> {
  SettingsNotifier() : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final res = await ApiClient.instance.get('/settings');
      state = AsyncValue.data(
          StoreSettings.fromJson(res.data as Map<String, dynamic>));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> save(Map<String, dynamic> payload) async {
    await ApiClient.instance.put('/settings', data: payload);
    await load();
  }
}

final settingsMutableProvider =
    StateNotifierProvider<SettingsNotifier, AsyncValue<StoreSettings>>(
  (_) => SettingsNotifier(),
);

/// Full URL to the DuitNow QR image, or null if not configured.
final duitnowQrUrlProvider = FutureProvider<String?>((ref) async {
  final settings = await ref.watch(settingsProvider.future);
  final path = settings.duitnowQrImageUrl;
  if (path == null || path.isEmpty) return null;
  final prefs = await SharedPreferences.getInstance();
  final base = (prefs.getString('base_url') ?? ApiConstants.defaultBaseUrl)
      .replaceAll(RegExp(r'/$'), '');
  return '$base/$path';
});
