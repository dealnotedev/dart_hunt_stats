import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  final StatsDb db;

  final _gameEventSubject = StreamController<dynamic>.broadcast();

  TrackerEngine(this.db, {required this.listenGameLog}) {
    _gameEventSubject.stream.listen(_handleGameEvent);
  }

  Future<void> _handleGameEvent(dynamic info) async {
    if (info is MatchEntity) {
      await saveHuntMatch(info);
    }

    if (info is _MapLoading) {
      _mapSubject.add(info.levelName);
      await _playMapSound(info.levelName);
    }
  }

  Future<void> start() async {
    await _refreshData();
    await _startTracking();
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
      lastBundle = bundle;
      _bundleSubject.add(bundle);
    } else {
      lastBundle = null;
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

  HuntBundle? lastBundle;

  Stream<String> get map => _mapSubject.stream;

  Stream<HuntBundle?> get lastMatch {
    final last = lastBundle;
    if (last != null) {
      return Stream<HuntBundle?>.value(last)
          .concatWith([_bundleSubject.stream]);
    } else {
      return _bundleSubject.stream;
    }
  }

  Future<void> saveHuntMatch(MatchEntity data) async {
    final previousTeamStats = data.match.teamId == lastBundle?.teamId
        ? lastBundle?.teamStats
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
        previousOwnStats: lastBundle?.ownStats,
        previousMatch: lastBundle?.match);

    lastBundle = bundle;
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

  Future<void> _startTracking() async {
    final finder = HuntFinder();
    final parser = HuntAttributesParser();

    final file = await finder.findHuntAttributes();
    final attributes = file.path;

    void emitData(dynamic data) {
      _gameEventSubject.add(data);
    }

    emitData(_HuntFound(attributes));

    final signatures = <String>{};
    Timer.periodic(const Duration(seconds: 30), (timer) async {
      final file = File(attributes);

      final data = await compute(parser.parseFromFile, file);

      if (signatures.add(data.header.signature)) {
        final match =
            await data.toEntity(db, outdated: false, teamOutdated: false);
        emitData(match);
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
