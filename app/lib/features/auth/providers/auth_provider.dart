import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/db/local_db.dart';
import '../../../core/models/user.dart';
import '../../../core/storage/token_storage.dart';
import '../../../shared/utils/error_utils.dart';

class AuthState {
  final User? user;
  final bool isLoading;
  final String? error;

  const AuthState({this.user, this.isLoading = false, this.error});

  bool get isAuthenticated => user != null;
  AuthState copyWith({User? user, bool? isLoading, String? error}) => AuthState(
        user: user ?? this.user,
        isLoading: isLoading ?? this.isLoading,
        error: error,
      );
}

class AuthNotifier extends StateNotifier<AuthState> {
  Timer? _permRefreshTimer;

  AuthNotifier() : super(const AuthState(isLoading: true)) {
    _tryRestoreSession();
  }

  @override
  void dispose() {
    _permRefreshTimer?.cancel();
    super.dispose();
  }

  void _startPermRefresh() {
    _permRefreshTimer?.cancel();
    _permRefreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => refreshUser(),
    );
  }

  void _stopPermRefresh() {
    _permRefreshTimer?.cancel();
    _permRefreshTimer = null;
  }

  Future<void> _tryRestoreSession() async {
    final token = await TokenStorage.read();
    if (token == null) {
      state = const AuthState();
      return;
    }
    try {
      final res = await ApiClient.instance.get('/me');
      final user = User.fromJson(res.data as Map<String, dynamic>);
      _cacheUserSilently(user);
      state = AuthState(user: user);
      _startPermRefresh();
    } catch (e) {
      if (_isAuthError(e)) {
        // Token genuinely rejected by server — force re-login
        await TokenStorage.delete();
        _clearUserSilently();
        state = const AuthState();
      } else {
        // Network unavailable — restore from local cache and stay logged in
        final cached = await _getCachedUserSilently();
        if (cached != null) {
          state = AuthState(user: cached);
          _startPermRefresh();
        } else {
          // No local cache and no network — cannot restore
          await TokenStorage.delete();
          state = const AuthState();
        }
      }
    }
  }

  Future<void> login(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final res = await ApiClient.instance.post(
        '/login',
        data: {'username': username, 'password': password},
      );
      final token = res.data['access_token'] as String;
      await TokenStorage.save(token);
      final meRes = await ApiClient.instance.get('/me');
      final user = User.fromJson(meRes.data as Map<String, dynamic>);
      _cacheUserSilently(user);
      state = AuthState(user: user);
      _startPermRefresh();
    } on Exception catch (e) {
      state = state.copyWith(isLoading: false, error: friendlyError(e));
    }
  }

  Future<void> logout() async {
    _stopPermRefresh();
    await TokenStorage.delete();
    _clearUserSilently();
    state = const AuthState();
  }

  Future<void> refreshUser() async {
    try {
      final res = await ApiClient.instance.get('/me');
      final user = User.fromJson(res.data as Map<String, dynamic>);
      _cacheUserSilently(user);
      state = state.copyWith(user: user);
    } catch (_) {
      // keep existing state on network error
    }
  }

  // DB cache helpers — failures are non-fatal; login/session must not break if SQLite has issues
  void _cacheUserSilently(User user) {
    LocalDb.saveUser(user).catchError((_) {});
  }

  void _clearUserSilently() {
    LocalDb.clearUser().catchError((_) {});
  }

  Future<User?> _getCachedUserSilently() async {
    try {
      return await LocalDb.getCachedUser();
    } catch (_) {
      return null;
    }
  }

  // Returns true only for explicit auth rejection (401/403), not network errors
  bool _isAuthError(Object e) {
    ApiException? apiEx;
    if (e is ApiException) {
      apiEx = e;
    } else if (e is DioException && e.error is ApiException) {
      apiEx = e.error as ApiException;
    }
    return apiEx != null &&
        (apiEx.statusCode == 401 || apiEx.statusCode == 403);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (_) => AuthNotifier(),
);
