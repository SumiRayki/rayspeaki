class Channel {
  final int id;
  String name;
  String background;
  bool hasPassword;
  List<ChannelMember> members;

  Channel({
    required this.id,
    required this.name,
    this.background = '',
    this.hasPassword = false,
    this.members = const [],
  });

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        id: json['id'] as int,
        name: json['name'] as String? ?? '',
        background: json['background'] as String? ?? '',
        hasPassword: json['hasPassword'] as bool? ?? false,
      );
}

class ChannelMember {
  final String id; // socket id
  final String identity;

  ChannelMember({required this.id, required this.identity});

  factory ChannelMember.fromJson(Map<String, dynamic> json) => ChannelMember(
        id: json['id'] as String? ?? '',
        identity: json['identity'] as String? ?? '',
      );
}
