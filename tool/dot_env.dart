import 'dart:io';

/// Reads [name] from the environment, else from `.env` at the project root.
String? secret(String name) {
  final fromEnv = Platform.environment[name];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final file = File('.env');
  if (!file.existsSync()) return null;
  for (final line in file.readAsLinesSync()) {
    final i = line.indexOf('=');
    if (i > 0 && line.substring(0, i).trim() == name) {
      return line.substring(i + 1).trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
    }
  }
  return null;
}
