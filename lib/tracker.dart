import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:hunt_stats/db/entities.dart';
import 'package:hunt_stats/db/entities_ext.dart';
import 'package:hunt_stats/db/stats_db.dart';
import 'package:hunt_stats/generated/assets.dart';
import 'package:hunt_stats/hunt_bundle.dart';
import 'package:hunt_stats/hunt_finder.dart';
import 'package:hunt_stats/parser/hunt_attributes_parser.dart';
import 'package:hunt_stats/parser/models.dart';
import 'package:hunt_stats/ringtone.dart';
import 'package:rxdart/rxdart.dart';

class TrackerEngine {
  final _bundleSubject = StreamController<HuntBundle?>.broadcast();
  final _mapSubject = StreamController<String>.broadcast();

  final bool listenGameLog;
  final bool useSeparateIsolate;
  final StatsDb db;

  DateTime _lastPingTime = DateTime.now();

  bool _huntFound = false;

  static final _gameEventSubject = StreamController<dynamic>.broadcast();

  TrackerEngine(this.db,
      {required this.listenGameLog, required this.useSeparateIsolate}) {
    _port.listen(_handleGameEvent);
    _gameEventSubject.stream.listen(_handleGameEvent);
  }

  Future<void> _handleGameEvent(dynamic info) async {
    if (info is MatchEntity) {
      await saveHuntMatch(info);
    }

    if (info is _HuntFound) {
      _huntFound = true;
    }

    if (info is MatchEntity || info is _NoNewMatches) {
      _lastPingTime = DateTime.now();
    }

    if (info is _MapLoading) {
      _mapSubject.add(info.levelName);
      await _playMapSound(info.levelName);
    }
  }

  void _startPinger() async {
    while (true) {
      await Future.delayed(const Duration(seconds: 15));

      final now = DateTime.now();

      if (_huntFound && now.difference(_lastPingTime).inSeconds.abs() > 60) {
        _lastPingTime = now;
        await _respawnIsolate();
      }
    }
  }

  Isolate? _isolate;

  Future<void> start() async {
    await _refreshData();
    await _respawnIsolate();

    if (useSeparateIsolate) {
      _startPinger();
    }
  }

  final _port = ReceivePort('Tracking');

  Future<void> _respawnIsolate() async {
    if (_isolate != null) {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
    }

    final args = [_port.sendPort, listenGameLog, useSeparateIsolate];

    if (useSeparateIsolate) {
      _isolate =
          await Isolate.spawn(_startTracking, args, errorsAreFatal: false);
    } else {
      _startTracking(args);
    }
  }

  Future<void> _playMapSound(String mapName) async {
    switch (mapName.trim().toLowerCase().split('/')[1]) {
      case 'creek':
        RingtonePlayer.play(Assets.assetsCreek);
        break;
      case 'cemetery':
        RingtonePlayer.play(Assets.assetsCemetery);
        break;
      case 'civilwar':
        RingtonePlayer.play(Assets.assetsCivilwar);
        break;
    }
  }

  Future<void> _refreshData() async {
    final header = await db.getLastMatch();

    if (header != null) {
      final players = await db.getMatchPlayers(header.id);
      final match = MatchEntity(match: header, players: players);
      final ownStats = await db.getOwnStats();
      final teamStats = await db.getTeamStats(header.teamId);

      final enemiesStats = await db.getEnemiesStats(_getEnemiesMap(players));

      final myProfileId = await db.calculateMostPlayerTeammate(
          players.where((element) => element.teammate).map((e) => e.profileId));

      final bundle = HuntBundle(
          match: match,
          me: players
              .firstWhereOrNull((element) => element.profileId == myProfileId),
          enemyStats: enemiesStats.values.toList(),
          ownStats: ownStats,
          teamStats: teamStats,
          previousTeamStats: null,
          previousOwnStats: null,
          previousMatch: null);
      _lastBundle = bundle;
      _bundleSubject.add(bundle);
    } else {
      _lastBundle = null;
      _bundleSubject.add(null);
    }
  }

  static Map<int, PlayerEntity> _getEnemiesMap(List<PlayerEntity> players) {
    final enemies = players
        .where((element) => !element.teammate && element.hasMutuallyKillDowns);
    final map = <int, PlayerEntity>{};
    map.addEntries(enemies.map((e) => MapEntry(e.profileId, e)));
    return map;
  }

  HuntBundle? _lastBundle;

  Stream<String> get map => _mapSubject.stream;

  Stream<HuntBundle?> get lastMatch {
    final last = _lastBundle;
    if (last != null) {
      return Stream<HuntBundle?>.value(last)
          .concatWith([_bundleSubject.stream]);
    } else {
      return _bundleSubject.stream;
    }
  }

  Future<void> saveHuntMatch(MatchEntity data) async {
    final previousTeamStats = data.match.teamId == _lastBundle?.teamId
        ? _lastBundle?.teamStats
        : await db.getTeamStats(data.match.teamId);

    await db.insertHuntMatch(data.match);

    if (data.match.id == 0) return;

    final players = data.players;

    for (var element in players) {
      element.matchId = data.match.id;
      element.teamId = data.match.teamId;
    }

    await db.insertHuntMatchPlayers(players);

    final enemiesStats = await db.getEnemiesStats(_getEnemiesMap(players));

    final myProfileId = await db.calculateMostPlayerTeammate(
        players.where((element) => element.teammate).map((e) => e.profileId));

    final ownStats = await db.getOwnStats();
    final teamStats = await db.getTeamStats(data.match.teamId);

    final bundle = HuntBundle(
        match: data,
        me: players
            .firstWhereOrNull((element) => element.profileId == myProfileId),
        enemyStats: enemiesStats.values.toList(),
        ownStats: ownStats,
        teamStats: teamStats,
        previousTeamStats: previousTeamStats,
        previousOwnStats: _lastBundle?.ownStats,
        previousMatch: _lastBundle?.match);

    _lastBundle = bundle;
    _bundleSubject.add(bundle);
  }

  Future<void> invalidateMatches() async {
    await db.outdate();
    await _refreshData();
  }

  Future<void> invalidateTeam(String teamId) async {
    await db.outdateTeam(teamId);
    await _refreshData();
  }

  static void _startTracking(List<dynamic> args) async {
    final port = args[0] as SendPort;
    final listenGameLog = args[1] as bool;
    final bool separateIsolate = args[2] as bool;

    final finder = HuntFinder();
    final parser = HuntAttributesParser();

    final file = await finder.findHuntAttributes();
    final attributes = file.path;

    void emitData(dynamic data) {
      if (separateIsolate) {
        port.send(data);
      } else {
        _gameEventSubject.add(data);
      }
    }

    emitData(_HuntFound(attributes));

    final signatures = <String>{};
    Timer.periodic(const Duration(seconds: 30), (timer) async {
      final file = File(attributes);

      final data = await (separateIsolate
          ? parser.parseFromFile(file)
          : compute(parser.parseFromFile, file));

      if (signatures.add(data.header.signature)) {
        emitData(data.toEntity(outdated: false, teamOutdated: false));
      } else {
        emitData(_NoNewMatches());
      }
    });

    if (listenGameLog) {
      final userDirectory = file.parent.parent.parent;
      final logFile = File('${userDirectory.path}\\game.log');

      var length = await logFile.length();

      Timer.periodic(const Duration(seconds: 1), (timer) {
        final actualLength = logFile.lengthSync();
        if (actualLength == length) {
          return;
        }
        if (actualLength < length) {
          length = 0;
        }

        logFile.openRead(length).transform(utf8.decoder).forEach((s) {
          length += s.length;

          final parts = s.split(' ');
          final index = parts.indexOf('PrepareLevel');
          if (index != -1) {
            emitData(_MapLoading(parts[index + 1]));
          }
        });
      });
    }
  }

  Future<HuntMatchData> extractFromFile(File file) async {
    return HuntAttributesParser().parseFromFile(file);
  }
}

class _NoNewMatches {}

class _MapLoading {
  final String levelName;

  _MapLoading(this.levelName);
}

class _HuntFound {
  final String attributes;

  _HuntFound(this.attributes);
}
