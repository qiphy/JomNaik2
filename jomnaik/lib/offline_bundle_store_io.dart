import 'dart:io';

import 'package:path_provider/path_provider.dart';

class OfflineBundleStore {
  Future<Directory> get _directory async => getApplicationSupportDirectory();
  Future<String?> readBundle() async {
    final file = File('${(await _directory).path}/raptor_klang_valley.json');
    return await file.exists() ? file.readAsString() : null;
  }

  Future<String?> readVersion() async {
    final file = File('${(await _directory).path}/raptor_klang_valley.version');
    return await file.exists() ? file.readAsString() : null;
  }

  Future<void> writeBundle(String bundle, String version) async {
    final directory = await _directory;
    final temporary = File('${directory.path}/raptor_klang_valley.json.part');
    await temporary.writeAsString(bundle, flush: true);
    await temporary.rename('${directory.path}/raptor_klang_valley.json');
    await File(
      '${directory.path}/raptor_klang_valley.version',
    ).writeAsString(version, flush: true);
  }
}
