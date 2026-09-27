import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/api_constants.dart';
import '../storage/token_storage.dart';
import 'api_exception.dart';

class ApiClient {
  static Dio? _instance;
  static String? _lastBaseUrl;

  static Dio get instance {
    _instance ??= _build();
    return _instance!;
  }

  static void reset() => _instance = null;

  /// Resolves a relative path (e.g. an `image_path` returned by the API)
  /// against the currently configured server base URL. Returns null if
  /// [path] is null/empty, and passes absolute URLs through unchanged.
  static String? resolveUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final base = _lastBaseUrl ?? ApiConstants.defaultBaseUrl;
    return '${base.endsWith('/') ? base.substring(0, base.length - 1) : base}/'
        '${path.startsWith('/') ? path.substring(1) : path}';
  }

  static Dio _build() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: ApiConstants.connectTimeout,
        receiveTimeout: ApiConstants.receiveTimeout,
        headers: {'Content-Type': 'application/json'},
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final prefs = await SharedPreferences.getInstance();
          options.baseUrl =
              prefs.getString('base_url') ?? ApiConstants.defaultBaseUrl;
          _lastBaseUrl = options.baseUrl;

          final token = await TokenStorage.read();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          return handler.next(options);
        },
        onError: (DioException e, handler) {
          return handler.reject(
            DioException(
              requestOptions: e.requestOptions,
              error: ApiException.fromDio(e),
              response: e.response,
              type: e.type,
            ),
          );
        },
      ),
    );

    return dio;
  }
}
