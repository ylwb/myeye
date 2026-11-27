/// Provisions the Linux rootfs inside the app so the ACP agent (pi/pi-acp)
/// can run under PRoot.
///
/// Mirrors `proot-distro install` but is self-contained:
///   1. download a Debian arm64 rootfs tarball
///   2. extract it (archive: GZip + Tar)
///   3. `proot -0 -r <rootfs> ... apt-get install nodejs npm`
///   4. `proot ... npm i -g @earendil-works/pi-coding-agent pi-acp`
///
/// The host and the rootfs are both arm64, so no qemu emulation is needed —
/// this is what makes provisioning possible on-device, unlike a CI image.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

enum AcpSandboxStage {
  missing,
  downloading,
  extracting,
  installing,
  ready,
  failed,
}

class AcpSandboxProvisioner {
  AcpSandboxProvisioner({
    required this.rootfsDir,
    required this.rootfsUrl,
    this.prootPath = 'proot',
    this.agentPackages = const [
      '@earendil-works/pi-coding-agent',
      'pi-acp',
    ],
    this.onProgress,
  });

  /// Where the rootfs is unpacked (app-private dir).
  final String rootfsDir;

  /// Debian arm64 rootfs tarball URL.
  final String rootfsUrl;

  /// Path to the PRoot binary (bundled in APK assets, or on PATH).
  final String prootPath;

  final List<String> agentPackages;
  final void Function(double progress, String message)? onProgress;

  AcpSandboxStage _stage = AcpSandboxStage.missing;
  AcpSandboxStage get stage => _stage;

  String get markerPath => '$rootfsDir/.acp-ready';

  Future<bool> isReady() async => File(markerPath).existsSync();

  /// Download + extract + install node/pi/pi-acp. Idempotent.
  Future<void> provision() async {
    if (await isReady()) {
      _stage = AcpSandboxStage.ready;
      return;
    }
    Directory(rootfsDir).createSync(recursive: true);
    try {
      _stage = AcpSandboxStage.downloading;
      final tmp = File('$rootfsDir/acp-rootfs.tar.gz');
      await _download(rootfsUrl, tmp);

      _stage = AcpSandboxStage.extracting;
      await _extractTarGz(tmp, rootfsDir);
      await tmp.delete();

      _stage = AcpSandboxStage.installing;
      await _chrootRun(
        'export DEBIAN_FRONTEND=noninteractive '
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; '
        'apt-get update -y >/dev/null 2>&1; '
        'apt-get install -y --no-install-recommends nodejs npm >/dev/null 2>&1; '
        'npm install -g ${agentPackages.join(' ')} >/dev/null 2>&1',
      );

      File(markerPath).writeAsStringSync('ok');
      _stage = AcpSandboxStage.ready;
    } catch (e) {
      _stage = AcpSandboxStage.failed;
      rethrow;
    }
  }

  Future<void> _download(String url, File dest) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('rootfs download failed: HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      final sink = dest.openWrite();
      var received = 0;
      final subscription = response.listen(
        (bytes) {
          sink.add(bytes);
          received += bytes.length;
          onProgress?.call(
            total > 0 ? received / total : 0,
            'downloading rootfs',
          );
        },
        onError: (Object _) => sink.close(),
        cancelOnError: false,
      );
      await subscription.asFuture<void>().catchError((_) {});
      await sink.flush();
      await sink.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _extractTarGz(File src, String destDir) async {
    final bytes = await src.readAsBytes();
    final raw = GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(raw);
    for (final entry in archive) {
      final data = entry as Map<String, dynamic>;
      final name = data['path'] as String? ?? '';
      if (name.isEmpty || name.contains('..') || name.startsWith('/')) continue;
      final path = '$destDir/$name';
      final isSymlink = _isSymlink(data['type']);
      if (isSymlink) {
        final target = data['link'] as String? ?? '';
        Directory(path).parent.createSync(recursive: true);
        final res = Process.runSync('ln', ['-sfn', target, path]);
        if (res.exitCode != 0) {
          throw StateError('symlink failed for $name: ${res.stderr}');
        }
        continue;
      }
      if (name.endsWith('/')) {
        Directory(path).createSync(recursive: true);
        continue;
      }
      Directory(path).parent.createSync(recursive: true);
      final payload = data['data'];
      if (payload is List<int>) {
        File(path).writeAsBytesSync(payload);
      }
      final mode = data['mode'] as int? ?? 0;
      if (mode & 0x111 != 0) {
        Process.runSync('chmod', ['755', path]);
      }
    }
  }

  bool _isSymlink(Object? type) =>
      type == 2 || type == 0x50 || type == 'link' || type == 'symbolic-link';

  Future<void> _chrootRun(String shellCommand) async {
    final args = <String>[
      '-0',
      '-r', rootfsDir,
      '-b', '/dev',
      '-b', '/proc',
      '-b', '/sys',
      '-b', '/etc/resolv.conf',
      '/bin/sh',
      '-c', shellCommand,
    ];
    final proc = await Process.start(prootPath, args);
    final lines = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      onProgress?.call(0.9, 'installing: $line');
    }
    final code = await proc.exitCode;
    if (code != 0) {
      throw StateError('proot chroot install failed with exit $code');
    }
  }
}
