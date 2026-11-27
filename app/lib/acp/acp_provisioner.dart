/// Provisions the Linux rootfs inside the app so the ACP agent (pi/pi-acp)
/// can run under PRoot.
///
/// Mirrors `proot-distro install`, but pulls the rootfs from an OCI registry
/// instead of a single tarball:
///   1. anonymous bearer token from the registry's WWW-Authenticate realm
///   2. manifest list -> the arm64 platform manifest
///   3. stream the arm64 layer blob (tar+gzip)
///   4. extract it (archive: GZip + Tar)
///   5. `proot -0 -r <rootfs> ... apt-get install nodejs npm`
///   6. `proot ... npm i -g @earendil-works/pi-coding-agent pi-acp`
///
/// The host and the rootfs are both arm64, so no qemu emulation is needed —
/// provisioning happens on-device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

enum AcpSandboxStage {
  missing,
  pulling,
  downloading,
  extracting,
  installing,
  ready,
  failed,
}

class AcpSandboxProvisioner {
  AcpSandboxProvisioner({
    required this.rootfsDir,
    required this.imageRef,
    this.prootPath = 'proot',
    this.agentPackages = const [
      '@earendil-works/pi-coding-agent',
      'pi-acp',
    ],
    this.onProgress,
  });

  /// Where the rootfs is unpacked (app-private dir).
  final String rootfsDir;

  /// OCI image reference, e.g. `docker.m.daocloud.io/library/debian:trixie`.
  final String imageRef;

  /// Path to the PRoot binary (bundled in APK assets, or on PATH).
  final String prootPath;

  final List<String> agentPackages;
  final void Function(double progress, String message)? onProgress;

  AcpSandboxStage _stage = AcpSandboxStage.missing;
  AcpSandboxStage get stage => _stage;

  String get markerPath => '$rootfsDir/.acp-ready';

  Future<bool> isReady() async => File(markerPath).existsSync();

  /// Pull + extract + install node/pi/pi-acp. Idempotent.
  Future<void> provision() async {
    if (await isReady()) {
      _stage = AcpSandboxStage.ready;
      return;
    }
    Directory(rootfsDir).createSync(recursive: true);
    try {
      _stage = AcpSandboxStage.pulling;
      final tmp = File('$rootfsDir/acp-rootfs.tar.gz');
      await _pullLayer(imageRef, tmp);

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

  /// Resolve the arm64 layer blob and stream it to [dest].
  Future<void> _pullLayer(String ref, File dest) async {
    final colon = ref.indexOf(':');
    final hostAndRepo = colon < 0 ? ref : ref.substring(0, colon);
    final tag = colon < 0 ? 'latest' : ref.substring(colon + 1);
    final slash = hostAndRepo.indexOf('/');
    final host = slash < 0 ? hostAndRepo : hostAndRepo.substring(0, slash);
    final repo = slash < 0
        ? 'library/$hostAndRepo'
        : hostAndRepo.substring(slash + 1);
    final base = 'https://$host';
    final accept =
        'application/vnd.oci.image.index.v1+json,'
        'application/vnd.docker.distribution.manifest.list.v2+json,'
        'application/vnd.docker.distribution.manifest.v2+json';

    final client = HttpClient();
    try {
      final token = await _authToken(client, base, repo);
      final index = await _readJson(
        client,
        '$base/v2/$repo/manifests/$tag',
        token: token,
        accept: accept,
      );
      final manifests = index['manifests'] as List<dynamic>?;
      final String manifestDigest;
      final Map<String, dynamic> manifest;
      if (manifests != null && manifests.isNotEmpty) {
        final arm = manifests.firstWhere(
          (m) {
            final p = (m as Map<String, dynamic>)['platform']
                as Map<String, dynamic>;
            return p['architecture'] == 'arm64' && p['os'] == 'linux';
          },
          orElse: () => manifests.first as Map<String, dynamic>,
        ) as Map<String, dynamic>;
        manifestDigest = arm['digest'] as String;
        manifest = await _readJson(
          client,
          '$base/v2/$repo/manifests/$manifestDigest',
          token: token,
          accept: accept,
        );
      } else {
        manifest = index;
      }
      final layers = manifest['layers'] as List<dynamic>? ?? const [];
      if (layers.isEmpty) {
        throw StateError('image has no layers: $ref');
      }
      final layer = layers.first as Map<String, dynamic>;
      final digest = layer['digest'] as String;
      final size = layer['size'] as int? ?? -1;
      onProgress?.call(0, 'downloading ${size ~/ 1048576}MB layer');

      final request = await _open(
        client,
        '$base/v2/$repo/blobs/$digest',
        token: token,
        accept: '*/*',
      );
      final res = await request.close();
      if (res.statusCode != 200) {
        throw StateError('layer download failed: HTTP ${res.statusCode}');
      }
      final sink = dest.openWrite();
      var received = 0;
      final subscription = res.listen(
        (bytes) {
          sink.add(bytes);
          received += bytes.length;
          onProgress?.call(
            size > 0 ? (received / size).clamp(0.0, 1.0).toDouble() : 0.5,
            'downloading ${received ~/ 1048576}/${size ~/ 1048576}MB',
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

  Future<String> _authToken(
    HttpClient client,
    String base,
    String repo,
  ) async {
    final headReq = await _open(client, '$base/v2/', token: '');
    final head = await headReq.close();
    if (head.statusCode == 200) {
      await head.drain<void>().catchError((_) {});
      return '';
    }
    final www = head.headers.value('www-authenticate') ?? '';
    await head.drain<void>().catchError((_) {});
    final realm = _bearerParam(www, 'realm');
    final service = _bearerParam(www, 'service');
    if (realm.isEmpty) {
      throw StateError('no auth realm in: $www');
    }
    final uri = Uri.parse('$realm')
        .replace(queryParameters: {
          'service': service,
          'scope': 'repository:$repo:pull',
        });
    final tokReq = await _open(client, uri.toString(), token: '');
    final res = await tokReq.close();
    if (res.statusCode != 200) {
      throw StateError('token request failed: HTTP ${res.statusCode}');
    }
    final body = await utf8.decodeStream(res);
    final json = jsonDecode(body) as Map<String, dynamic>;
    return (json['token'] ?? json['access_token'] ?? '') as String;
  }

  String _bearerParam(String header, String key) {
    for (final part in header.split(',')) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      if (part.substring(0, eq).trim() == key) {
        return part.substring(eq + 1).trim().replaceAll('"', '');
      }
    }
    return '';
  }

  Future<HttpClientRequest> _open(
    HttpClient client,
    String url, {
    required String token,
    String accept = '*/*',
  }) async {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Accept', accept);
    if (token.isNotEmpty) {
      req.headers.set('Authorization', 'Bearer $token');
    }
    return req;
  }

  Future<HttpClientResponse> _openBody(
    HttpClient client,
    String url, {
    required String token,
    required String accept,
  }) async =>
      await (await _open(
        client,
        url,
        token: token,
        accept: accept,
      )).close();

  Future<Map<String, dynamic>> _readJson(
    HttpClient client,
    String url, {
    required String token,
    required String accept,
  }) async {
    final res = await _openBody(
      client,
      url,
      token: token,
      accept: accept,
    );
    if (res.statusCode != 200) {
      throw StateError('GET $url failed: HTTP ${res.statusCode}');
    }
    return jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
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
      if (_isSymlink(data['type'])) {
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
