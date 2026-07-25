import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _tokenKey = 'jwt_token';

  static Future<void> save(String token) =>
      _storage.write(key: _tokenKey, value: token);

  static Future<String?> read() => _storage.read(key: _tokenKey);

  static Future<void> delete() => _storage.delete(key: _tokenKey);
}
