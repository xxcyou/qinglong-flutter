class EnvVar {
  const EnvVar({
    this.id,
    this.name = '',
    this.value = '',
    this.remarks,
    this.status = 0,
    this.position,
  });

  final int? id;
  final String name;
  final String value;
  final String? remarks;
  final int status;
  final int? position;

  bool get isEnabled => status == 1;

  factory EnvVar.fromJson(Map<String, dynamic> json) {
    int? asInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    return EnvVar(
      id: asInt(json['id']),
      name: json['name'] as String? ?? '',
      value: json['value'] as String? ?? '',
      remarks: json['remarks'] as String?,
      status: asInt(json['status']) ?? 0,
      position: asInt(json['position']),
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        'value': value,
        if (remarks != null) 'remarks': remarks,
        'status': status,
      };

  EnvVar copyWith({
    int? id,
    String? name,
    String? value,
    String? remarks,
    int? status,
    int? position,
  }) {
    return EnvVar(
      id: id ?? this.id,
      name: name ?? this.name,
      value: value ?? this.value,
      remarks: remarks ?? this.remarks,
      status: status ?? this.status,
      position: position ?? this.position,
    );
  }
}
