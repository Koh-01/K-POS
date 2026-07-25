class User {
  final int id;
  final String username;
  final String fullName;
  final String role;
  final bool isActive;
  final Map<String, dynamic> permissions;

  const User({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
    required this.isActive,
    this.permissions = const {},
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as int,
        username: json['username'] as String,
        fullName: json['full_name'] as String? ?? '',
        role: json['role'] as String,
        isActive: json['is_active'] as bool,
        permissions: (json['permissions'] as Map<String, dynamic>?) ?? {},
      );

  bool get isAdmin => role == 'admin';

  // Permission helpers — defaults match existing behaviour before permissions were added
  bool get canViewCash   => isAdmin || (permissions['can_view_cash']   as bool? ?? true);
  bool get canAddCash    => isAdmin || (permissions['can_add_cash']    as bool? ?? true);
  bool get canEditCash   => isAdmin || (permissions['can_edit_cash']   as bool? ?? true);
  bool get canDeleteCash => isAdmin || (permissions['can_delete_cash'] as bool? ?? true);
  bool get canManageCatalog => isAdmin || (permissions['can_manage_catalog'] as bool? ?? false);
  bool get canManagePromotion => isAdmin || (permissions['can_manage_promotion'] as bool? ?? false);
  bool get canManagePayment => isAdmin || (permissions['can_manage_payment'] as bool? ?? false);
  bool get canManageSettings => isAdmin || (permissions['can_manage_settings'] as bool? ?? false);
}
