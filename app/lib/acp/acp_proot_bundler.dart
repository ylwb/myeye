/// Extracts the bundled PRoot binary (and its libtalloc dependency) from the
/// APK assets into the app data directory, so the ACP sandbox can spawn it.
library;

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

class AcpProotPaths {
  const AcpProotPaths({required this.prootPath, required this.libDir});
  final String prootPath;
  final String libDir;
}

class AcpProotBundler {
  AcpProotBundler._();

  /// Extract `assets/acp/{proot,libtalloc.so.2}` once; idempotent.
  static Future<AcpProotPaths> ensureExtracted() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/acp/proot');
    dir.createSync(recursive: true);
    final proot = File('${dir.path}/proot');
    final libtalloc = File('${dir.path}/libtalloc.so.2');
    if (!proot.existsSync()) {
      final data = await rootBundle.load('assets/acp/proot');
      proot.writeAsBytesSync(data.buffer.asUint8List());
      proot.chmodSync(0o755);
    }
    if (!libtalloc.existsSync()) {
      final data = await rootBundle.load('assets/acp/libtalloc.so.2');
      libtalloc.writeAsBytesSync(data.buffer.asUint8List());
    }
    return AcpProotPaths(prootPath: proot.path, libDir: dir.path);
  }
}
