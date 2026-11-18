import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import 'ai_models.dart';

abstract class AiRepository {
  Future<void> initialize();
  Future<List<AiProfile>> profiles();
  Future<String?> activeProvider();
  Future<void> saveProfile(AiProfile profile);
  Future<void> writeCall(AiCall call);
  Future<List<AiCall>> calls({int limit = 100, int offset = 0});
  Future<AiCall?> latest(String scope);
  Future<Map<String, (BigInt, int)>> totals();
}

abstract class AiSecrets {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
}

class DeviceAiSecrets implements AiSecrets {
  const DeviceAiSecrets();
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read(String id) => _storage.read(key: 'mianban_ai_$id');
  @override
  Future<void> write(String id, String value) =>
      _storage.write(key: 'mianban_ai_$id', value: value);
  @override
  Future<void> delete(String id) => _storage.delete(key: 'mianban_ai_$id');
}

class DeviceAiRepository implements AiRepository {
  Future<Database>? _opening;
  Future<Database> get _db async {
    final opening = _opening ??= _open();
    try {
      return await opening;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  Future<Database> _open() async => openDatabase(
    '${await getDatabasesPath()}/mianban_ai.db',
    version: 1,
    onCreate: (db, version) async {
      await db.execute(
        'CREATE TABLE profiles (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE settings (id TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await db.execute('''CREATE TABLE calls (
        id TEXT PRIMARY KEY, started_at INTEGER NOT NULL, scope TEXT NOT NULL, status TEXT NOT NULL,
        currency TEXT, amount_nano INTEGER, payload TEXT NOT NULL)''');
      await db.execute(
        'CREATE INDEX calls_by_date ON calls(started_at DESC, id DESC)',
      );
      await db.execute(
        'CREATE INDEX calls_by_scope ON calls(scope, started_at DESC)',
      );
    },
  );

  @override
  Future<void> initialize() async {
    final db = await _db;
    // A process exit cannot establish whether a supplier accepted the request.
    await db.transaction((transaction) async {
      final pending = await transaction.query(
        'calls',
        where: 'status = ?',
        whereArgs: ['pending'],
      );
      for (final row in pending) {
        final value =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        value['status'] = 'interrupted';
        value['error'] = '调用期间应用退出，用量与费用待供应商账单核对';
        await transaction.update(
          'calls',
          {'status': 'interrupted', 'payload': jsonEncode(value)},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    });
  }

  @override
  Future<List<AiProfile>> profiles() async =>
      (await (await _db).query('profiles'))
          .map(
            (row) => AiProfile.fromJson(
              Map<String, dynamic>.from(
                jsonDecode(row['payload'] as String) as Map,
              ),
            ),
          )
          .toList();

  @override
  Future<String?> activeProvider() async {
    final rows = await (await _db).query(
      'settings',
      where: 'id = ?',
      whereArgs: ['active_provider'],
    );
    return rows.firstOrNull?['value'] as String?;
  }

  @override
  Future<void> saveProfile(AiProfile profile) async =>
      (await _db).transaction((transaction) async {
        await transaction.insert('profiles', {
          'id': profile.provider.name,
          'payload': jsonEncode(profile.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await transaction.insert('settings', {
          'id': 'active_provider',
          'value': profile.provider.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  @override
  Future<void> writeCall(AiCall call) async {
    await (await _db).insert('calls', {
      'id': call.id,
      'started_at': call.startedAt.millisecondsSinceEpoch,
      'scope': call.scope,
      'status': call.status,
      'currency': call.price?.currency,
      'amount_nano': call.amountNano,
      'payload': jsonEncode(call.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<AiCall>> calls({int limit = 100, int offset = 0}) async =>
      (await (await _db).query(
            'calls',
            orderBy: 'started_at DESC, id DESC',
            limit: limit,
            offset: offset,
          ))
          .map(
            (row) => AiCall.fromJson(
              Map<String, dynamic>.from(
                jsonDecode(row['payload'] as String) as Map,
              ),
            ),
          )
          .toList();

  @override
  Future<AiCall?> latest(String scope) async {
    final rows = await (await _db).query(
      'calls',
      where: 'scope = ? AND status IN (?, ?)',
      whereArgs: [scope, 'success', 'partial'],
      orderBy: 'started_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : AiCall.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(rows.first['payload'] as String) as Map,
            ),
          );
  }

  @override
  Future<Map<String, (BigInt, int)>> totals() async {
    final rows = await (await _db).query(
      'calls',
      columns: ['currency', 'amount_nano'],
    );
    final values = <String, (BigInt, int)>{};
    for (final row in rows) {
      final currency = row['currency'] as String? ?? 'unknown';
      final prior = values[currency] ?? (BigInt.zero, 0);
      final amount = row['amount_nano'] as int?;
      values[currency] = (
        prior.$1 + BigInt.from(amount ?? 0),
        prior.$2 + (amount == null ? 1 : 0),
      );
    }
    return values;
  }
}
