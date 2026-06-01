/// Connected player in a netplay room.
class PlayerInfo {
  const PlayerInfo({
    required this.id,
    required this.name,
    this.isHost = false,
    this.isReady = false,
    this.latency = 0,
    this.slot = 0,
  });

  final String id;
  final String name;
  final bool isHost;
  final bool isReady;

  /// 1-based controller slot (P1 = 1).
  final int slot;
  final int latency;

  PlayerInfo copyWith({
    String? id,
    String? name,
    bool? isHost,
    bool? isReady,
    int? slot,
    int? latency,
  }) {
    return PlayerInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      isHost: isHost ?? this.isHost,
      isReady: isReady ?? this.isReady,
      slot: slot ?? this.slot,
      latency: latency ?? this.latency,
    );
  }

  factory PlayerInfo.fromJson(Map<String, dynamic> json) {
    return PlayerInfo(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Player',
      isHost: json['isHost'] as bool? ?? false,
      isReady: json['isReady'] as bool? ?? false,
      slot: (json['slot'] as num?)?.toInt() ?? 0,
      latency: json['latency'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isHost': isHost,
        'isReady': isReady,
        'slot': slot,
        'latency': latency,
      };
}
