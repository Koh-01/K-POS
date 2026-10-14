class ApiConstants {
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://kpos.koh01.com',
  );
  // Kept short so a dead connection (Tunnel down, no signal, etc.) fails
  // fast into the app's offline fallback instead of leaving the UI looking
  // stuck for the length of a long default timeout.
  static const Duration connectTimeout = Duration(seconds: 5);
  static const Duration receiveTimeout = Duration(seconds: 15);
}
