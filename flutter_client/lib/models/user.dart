class User {
  final String identity;
  final String role;
  String avatar;

  User({
    required this.identity,
    this.role = 'user',
    this.avatar = '',
  });

  bool get isAdmin => role == 'admin';

  factory User.fromJson(Map<String, dynamic> json) => User(
        identity: json['identity'] as String? ?? '',
        role: json['role'] as String? ?? 'user',
        avatar: json['avatar'] as String? ?? '',
      );
}
