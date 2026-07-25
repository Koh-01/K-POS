import 'dart:io';
import 'package:path_provider/path_provider.dart';

Future<String> downloadCsv(String content, String filename) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$filename');
  await file.writeAsString(content);
  return file.path;
}
