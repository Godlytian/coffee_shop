class CartGroup {
  final String id;
  final int orderId;
  final int groupIndex;
  final String groupName;
  final String paymentStatus;
  final double amountPaid;
  final String? closedAt;
  final int? closedBy;

  const CartGroup({
    required this.id,
    required this.orderId,
    required this.groupIndex,
    required this.groupName,
    this.paymentStatus = 'pending',
    this.amountPaid = 0,
    this.closedAt,
    this.closedBy,
  });

  factory CartGroup.fromJson(Map<String, dynamic> json) {
    return CartGroup(
      id: json['id']?.toString() ?? '',
      orderId: (json['order_id'] as num?)?.toInt() ?? 0,
      groupIndex: (json['group_index'] as num?)?.toInt() ?? 0,
      groupName: json['group_name']?.toString() ?? 'Group',
      paymentStatus: json['payment_status']?.toString() ?? 'pending',
      amountPaid: (json['amount_paid'] as num?)?.toDouble() ?? 0,
      closedAt: json['closed_at']?.toString(),
      closedBy: (json['closed_by'] as num?)?.toInt(),
    );
  }

  factory CartGroup.fromLocalMap(Map<String, dynamic> map) =>
      CartGroup.fromJson(map);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'order_id': orderId,
      'group_index': groupIndex,
      'group_name': groupName,
      'payment_status': paymentStatus,
      'amount_paid': amountPaid,
      'closed_at': closedAt,
      'closed_by': closedBy,
    };
  }

  CartGroup copyWith({
    String? paymentStatus,
    double? amountPaid,
    String? closedAt,
    int? closedBy,
    String? groupName,
  }) {
    return CartGroup(
      id: id,
      orderId: orderId,
      groupIndex: groupIndex,
      groupName: groupName ?? this.groupName,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      amountPaid: amountPaid ?? this.amountPaid,
      closedAt: closedAt ?? this.closedAt,
      closedBy: closedBy ?? this.closedBy,
    );
  }
}
