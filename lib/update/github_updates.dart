import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _networkTimeout = Duration(seconds: 30);
const _maxApkBytes = 256 * 1024 * 1024;
final _repositoryPattern = RegExp(r'^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$');
final _versionTag = RegExp(r'^v([0-9]+\.[0-9]+\.[0-9]+)$');
final _apkName = RegExp(
  r'^mianban-android-([0-9]+\.[0-9]+\.[0-9]+)-([1-9][0-9]*)\.apk$',
);
final _digestPattern = RegExp(r'^sha256:([0-9a-f]{64})$');

class UpdateFailure implements Exception {
  const UpdateFailure(this.message);
  final String message;
}

class AndroidUpdate {
  const AndroidUpdate({
    required this.versionName,
    required this.versionCode,
    required this.bytes,
    required this.sha256Hex,
    required this.url,
  });

  final String versionName, sha256Hex;
  final int versionCode, bytes;
  final Uri url;

  static AndroidUpdate? fromRelease(
    Object? data,
    String repository,
    int installedCode,
  ) {
    if (!_repositoryPattern.hasMatch(repository)) {
      throw const UpdateFailure('更新源配置无效');
    }
    if (data is! Map || data['draft'] != false || data['prerelease'] != false) {
      throw const UpdateFailure('公开发行信息无法读取');
    }
    final tag = data['tag_name'];
    final assets = data['assets'];
    final version = tag is String
        ? _versionTag.firstMatch(tag)?.group(1)
        : null;
    if (version == null || assets is! List) {
      throw const UpdateFailure('公开发行信息无法读取');
    }

    AndroidUpdate? update;
    for (final asset in assets.whereType<Map>()) {
      final name = asset['name'];
      final match = name is String ? _apkName.firstMatch(name) : null;
      if (name is! String || match == null || match[1] != version) continue;
      final code = int.tryParse(match[2]!);
      if (code == null || code > 2100000000 || update != null) {
        throw const UpdateFailure('发行包版本信息有误');
      }
      final size = asset['size'];
      final digest = asset['digest'];
      final sha = digest is String
          ? _digestPattern.firstMatch(digest)?.group(1)
          : null;
      if (asset['state'] != 'uploaded' ||
          size is! int ||
          size < 1 ||
          size > _maxApkBytes ||
          sha == null) {
        throw const UpdateFailure('发行包缺少完整的校验信息');
      }
      update = AndroidUpdate(
        versionName: version,
        versionCode: code,
        bytes: size,
        sha256Hex: sha,
        url: Uri.https(
          'github.com',
          '/$repository/releases/download/$tag/$name',
        ),
      );
    }
    if (update == null) throw const UpdateFailure('最新发行版本没有可用的安卓安装包');
    return update.versionCode > installedCode ? update : null;
  }

  Future<void> saveVerified(
    Stream<List<int>> data,
    File apk,
    void Function(int) progress,
  ) async {
    await apk.parent.create(recursive: true);
    final staging = await apk.parent.createTemp('download-');
    final pending = File('${staging.path}${Platform.pathSeparator}update.apk');
    try {
      final output = await pending.open(mode: FileMode.write);
      var received = 0;
      try {
        await for (final chunk in data.timeout(_networkTimeout)) {
          received += chunk.length;
          if (received > bytes) throw const UpdateFailure('安装包大小与发行信息不符');
          await output.writeFrom(chunk);
          progress(received * 100 ~/ bytes);
        }
      } finally {
        await output.close();
      }
      if (received != bytes) throw const UpdateFailure('安装包下载不完整');
      final digest = await sha256.bind(pending.openRead()).single;
      if (digest.toString() != sha256Hex) throw const UpdateFailure('安装包校验失败');
      await pending.rename(apk.path);
    } finally {
      if (await pending.exists()) await pending.delete();
      await staging.delete();
    }
  }
}

class GitHubUpdates {
  GitHubUpdates(this.repository);

  final String repository;
  final _http = HttpClient()..connectionTimeout = _networkTimeout;

  Future<AndroidUpdate?> check(int installedCode) async {
    if (!_repositoryPattern.hasMatch(repository)) {
      throw const UpdateFailure('此版本尚未配置更新源');
    }
    final url = Uri.https(
      'api.github.com',
      '/repos/$repository/releases/latest',
    );
    final request = await _http.getUrl(url).timeout(_networkTimeout);
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    final response = await request.close().timeout(_networkTimeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().timeout(_networkTimeout);
      throw UpdateFailure(switch (response.statusCode) {
        HttpStatus.notFound => '尚未找到公开发行版本',
        HttpStatus.forbidden || HttpStatus.tooManyRequests => '更新查询暂时受限，请稍后重试',
        _ => '暂时无法读取 GitHub 发行版本',
      });
    }
    final data = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_networkTimeout)) {
      if (data.length + chunk.length > 1024 * 1024) {
        throw const UpdateFailure('发行信息过长');
      }
      data.add(chunk);
    }
    return AndroidUpdate.fromRelease(
      jsonDecode(utf8.decode(data.takeBytes())),
      repository,
      installedCode,
    );
  }

  Future<void> download(
    AndroidUpdate release,
    File apk,
    void Function(int) progress,
  ) async {
    var url = release.url;
    for (var redirects = 0; redirects <= 4; redirects++) {
      if (url.scheme != 'https' ||
          url.port != 443 ||
          url.userInfo.isNotEmpty ||
          !const {
            'github.com',
            'release-assets.githubusercontent.com',
            'objects.githubusercontent.com',
          }.contains(url.host)) {
        throw const UpdateFailure('安装包下载地址无效');
      }
      final request = await _http.getUrl(url).timeout(_networkTimeout);
      request.followRedirects = false;
      final response = await request.close().timeout(_networkTimeout);
      if (response.statusCode == HttpStatus.ok) {
        await release.saveVerified(response, apk, progress);
        return;
      }
      final target = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>().timeout(_networkTimeout);
      if (!response.isRedirect || target == null) break;
      url = url.resolve(target);
    }
    throw const UpdateFailure('暂时无法下载安装包，请重试');
  }

  void close() => _http.close(force: true);
}
