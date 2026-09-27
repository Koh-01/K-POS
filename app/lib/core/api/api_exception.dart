import 'package:dio/dio.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final bool isNetworkError;

  const ApiException(
    this.message, {
    this.statusCode,
    this.isNetworkError = false,
  });

  factory ApiException.fromDio(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return const ApiException(
        'Connection timed out. Please check your network and try again.',
        isNetworkError: true,
      );
    }
    if (e.type == DioExceptionType.connectionError) {
      return const ApiException(
        'Cannot connect to server. Please check your network connection.',
        isNetworkError: true,
      );
    }
    if (e.response != null) {
      final statusCode = e.response!.statusCode;
      final data = e.response!.data;
      String? rawDetail;
      if (data is Map) {
        final detail = data['detail'];
        if (detail is String) {
          rawDetail = detail;
        } else if (detail is List && detail.isNotEmpty) {
          final first = detail.first;
          if (first is Map) rawDetail = first['msg'] as String?;
        }
      }
      final msg = _friendlyHttpMessage(statusCode, rawDetail);
      return ApiException(
        msg,
        statusCode: statusCode,
        isNetworkError:
            statusCode == 502 || statusCode == 503 || statusCode == 504,
      );
    }
    return const ApiException('Something went wrong. Please try again.');
  }

  /// Only these failures are safe to treat as "offline" and queue locally.
  /// Validation, authentication and permission errors must stay visible to
  /// the operator instead of becoming poison rows that retry forever.
  static bool isOfflineFailure(Object error) {
    if (error is ApiException) return error.isNetworkError;
    if (error is DioException && error.error is ApiException) {
      return (error.error as ApiException).isNetworkError;
    }
    return false;
  }

  static String _friendlyHttpMessage(int? statusCode, String? rawDetail) {
    switch (statusCode) {
      case 401:
        return 'Username or password is incorrect.';
      case 403:
        return 'You do not have permission to perform this action.';
      case 404:
        return 'The requested record was not found.';
      case 409:
        return rawDetail != null
            ? _cleanDetail(rawDetail)
            : 'This record already exists.';
      case 422:
        if (rawDetail != null) return _cleanDetail(rawDetail);
        return 'Please check your input and try again.';
      case 500:
      case 502:
      case 503:
        return 'Server error. Please try again later.';
      default:
        return rawDetail != null
            ? _cleanDetail(rawDetail)
            : 'Something went wrong. Please try again.';
    }
  }

  static String _cleanDetail(String msg) {
    final lower = msg.toLowerCase();
    final minLen = RegExp(
      r'at least (\d+) characters?',
      caseSensitive: false,
    ).firstMatch(msg);
    if (minLen != null) {
      return 'Must be at least ${minLen.group(1)} characters.';
    }
    final maxLen = RegExp(
      r'at most (\d+) characters?',
      caseSensitive: false,
    ).firstMatch(msg);
    if (maxLen != null) {
      return 'Must be no more than ${maxLen.group(1)} characters.';
    }
    if (lower.contains('already exists') || lower.contains('duplicate')) {
      return 'This record already exists. Please use a different value.';
    }
    if (lower.contains('incorrect') &&
        (lower.contains('username') || lower.contains('password'))) {
      return 'Username or password is incorrect.';
    }
    return msg;
  }

  @override
  String toString() => message;
}
