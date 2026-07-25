import 'package:dio/dio.dart';
import '../../core/api/api_exception.dart';

String friendlyError(Object e) {
  if (e is ApiException) return e.message;
  if (e is DioException && e.error is ApiException) {
    return (e.error as ApiException).message;
  }
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('Failed host lookup')) {
    return 'Cannot connect to server. Please check your network connection.';
  }
  if (s.contains('TimeoutException') || s.contains('timed out')) {
    return 'Connection timed out. Please try again.';
  }
  if (s.contains('FormatException')) {
    return 'Received an unexpected response from the server.';
  }
  return 'Something went wrong. Please try again.';
}

String loadError(Object e) => '${friendlyError(e)}\nPull down to refresh.';
