import 'station.dart';

/// User preferences that drive the morning show. Pure Dart so the generator
/// can run in the background isolate and from `tool/` scripts.
class ShowConfig {
  const ShowConfig({
    this.listenerName = '',
    this.city = 'Sierre, Valais, Suisse',
    this.onAirCity = 'SOLAR CITY',
    this.interests = 'actualité générale, tech, IA, science, jeux vidéo',
    this.showMinutes = 12,
    this.songSeconds = 120,
    this.musicStyle = '',
    this.grokModel = 'x-ai/grok-4.7',
    this.ttsModel = 'google/gemini-3.8-flash-tts',
  });

  final String listenerName;

  /// Real home city (weather, local news) and its name on air.
  final String city;
  final String onAirCity;
  final String interests;

  /// Target length of the whole show, music included.
  final int showMinutes;

  /// Songs longer than this are faded out (Suno songs run 2–4 min).
  final int songSeconds;

  /// Extra direction appended to every Suno prompt; empty = station presets only.
  final String musicStyle;
  final String grokModel;
  final String ttsModel;

  /// Station theme (generated once) and fallback songs when Suno is down.
  static const themeModel = 'google/lyria-3-clip-preview';
  static const fallbackSongModel = 'google/lyria-3-pro-preview';

  /// Roughly one song every four minutes of show.
  int get songCount => (showMinutes / 4).round().clamp(1, 8);

  /// Seconds of the show left for the hosts once songs and jingles are placed.
  int get talkSeconds => (showMinutes * 60 - songCount * (songSeconds + 4)).clamp(90, 3600);

  /// Home as configured; trips are picked from the phone's UTC offset.
  Place placeAt(Duration utcOffset) => placeFor(
        utcOffset,
        home: city == homePlace.city && onAirCity == homePlace.onAir
            ? homePlace
            : Place(city: city, onAir: onAirCity, flavor: city),
      );

  Map<String, dynamic> toJson() => {
        'listenerName': listenerName,
        'city': city,
        'onAirCity': onAirCity,
        'interests': interests,
        'showMinutes': showMinutes,
        'songSeconds': songSeconds,
        'musicStyle': musicStyle,
        'grokModel': grokModel,
        'ttsModel': ttsModel,
      };

  factory ShowConfig.fromJson(Map<String, dynamic> j) {
    const d = ShowConfig();
    return ShowConfig(
      listenerName: j['listenerName'] as String? ?? d.listenerName,
      city: j['city'] as String? ?? d.city,
      onAirCity: j['onAirCity'] as String? ?? d.onAirCity,
      interests: j['interests'] as String? ?? d.interests,
      showMinutes: j['showMinutes'] as int? ?? d.showMinutes,
      songSeconds: j['songSeconds'] as int? ?? d.songSeconds,
      musicStyle: j['musicStyle'] as String? ?? d.musicStyle,
      grokModel: _upgrade(j['grokModel'] as String?, d.grokModel),
      ttsModel: _upgrade(j['ttsModel'] as String?, d.ttsModel),
    );
  }

  /// Former defaults saved by older builds follow the new default; a model
  /// the user typed in themselves is kept.
  static const _formerDefaults = {'x-ai/grok-4.3'};
  static String _upgrade(String? saved, String current) =>
      saved == null || _formerDefaults.contains(saved) ? current : saved;

  ShowConfig copyWith({
    String? listenerName,
    String? city,
    String? onAirCity,
    String? interests,
    int? showMinutes,
    int? songSeconds,
    String? musicStyle,
    String? grokModel,
    String? ttsModel,
  }) =>
      ShowConfig(
        listenerName: listenerName ?? this.listenerName,
        city: city ?? this.city,
        onAirCity: onAirCity ?? this.onAirCity,
        interests: interests ?? this.interests,
        showMinutes: showMinutes ?? this.showMinutes,
        songSeconds: songSeconds ?? this.songSeconds,
        musicStyle: musicStyle ?? this.musicStyle,
        grokModel: grokModel ?? this.grokModel,
        ttsModel: ttsModel ?? this.ttsModel,
      );
}
