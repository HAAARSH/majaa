class BeatModel {
  final String id;
  final String beatName;
  final String beatCode;
  final List<String> weekdays;
  final String area;
  final String route;
  final String teamId;

  const BeatModel({
    required this.id, required this.beatName, required this.beatCode,
    required this.weekdays, this.area = '', this.route = '', required this.teamId,
  });

  factory BeatModel.fromJson(Map<String, dynamic> json) => BeatModel(
    id: json['id'] as String,
    beatName: json['beat_name'] as String,
    beatCode: json['beat_code'] as String? ?? '',
    weekdays: List<String>.from(json['weekdays'] as List? ?? []),
    area: json['area'] as String? ?? '',
    route: json['route'] as String? ?? '',
    teamId: json['team_id'] as String? ?? 'JA',
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'beat_name': beatName, 'beat_code': beatCode, 'weekdays': weekdays,
    'area': area, 'route': route, 'team_id': teamId,
  };

  BeatModel copyWith({List<String>? weekdays}) => BeatModel(
    id: id, beatName: beatName, beatCode: beatCode,
    weekdays: weekdays ?? this.weekdays,
    area: area, route: route, teamId: teamId,
  );
}
