import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mianban/update/github_updates.dart';

const repository = 'CrissMagic/mianban';
const data = [152, 18, 189, 244];

Map<String, dynamic> release({String? digest, bool prerelease = false}) => {
  'tag_name': 'v0.3.5',
  'draft': false,
  'prerelease': prerelease,
  'assets': [
    {
      'name': 'mianban-android-0.3.5-9.apk',
      'size': data.length,
      'state': 'uploaded',
      'digest': digest ?? 'sha256:${sha256.convert(data)}',
      'browser_download_url': 'https://unexpected.example/test.apk',
    },
  ],
};

void main() {
  test('updates use Android build code and fixed public repository URL', () {
    final information = release();
    expect(AndroidUpdate.fromRelease(information, repository, 9), isNull);
    expect(AndroidUpdate.fromRelease(information, repository, 10), isNull);
    final update = AndroidUpdate.fromRelease(information, repository, 8)!;
    expect(update.versionCode, 9);
    expect(update.versionName, '0.3.5');
    expect(update.url.host, 'github.com');
    expect(
      update.url.path,
      '/$repository/releases/download/v0.3.5/mianban-android-0.3.5-9.apk',
    );
  });

  test('rejects prereleases, missing digests and ambiguous update assets', () {
    final invalid = [release(prerelease: true), release(digest: ''), release()];
    final duplicate = invalid.last['assets'] as List;
    duplicate.add(duplicate.single);
    for (final information in invalid) {
      expect(
        () => AndroidUpdate.fromRelease(information, repository, 8),
        throwsA(isA<UpdateFailure>()),
      );
    }
  });

  test(
    'only commits verified complete downloads and cleans staging data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mianban-update-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final apk = File('${directory.path}${Platform.pathSeparator}update.apk');
      final update = AndroidUpdate.fromRelease(release(), repository, 8)!;
      final progresses = <int>[];
      await update.saveVerified(
        Stream.fromIterable([data.take(2).toList(), data.skip(2).toList()]),
        apk,
        progresses.add,
      );
      expect(await apk.readAsBytes(), data);
      expect(progresses, [50, 100]);
      for (final broken in const [
        [1],
        [1, 2, 3, 4],
        [1, 2, 3, 4, 5],
      ]) {
        await expectLater(
          update.saveVerified(Stream.value(broken), apk, (_) {}),
          throwsA(isA<UpdateFailure>()),
        );
        expect(await apk.readAsBytes(), data);
        expect(await directory.list().length, 1);
      }
    },
  );
}
