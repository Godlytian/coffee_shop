class GroupItem {
  final String id;
  final String groupId;
  final int orderItemId;
  final String cartLineKey;
  final int assignedQty;

  const GroupItem({
    required this.id,
    required this.groupId,
    required this.orderItemId,
    required this.cartLineKey,
    required this.assignedQty,
  });

  factory GroupItem.fromJson(Map<String, dynamic> json) {
    return GroupItem(
      id: json['id']?.toString() ?? '',
      groupId: json['group_id']?.toString() ?? '',
      orderItemId: (json['order_item_id'] as num?)?.toInt() ?? 0,
      cartLineKey: json['cart_line_key']?.toString() ?? '',
      assignedQty: (json['assigned_qty'] as num?)?.toInt() ?? 0,
    );
  }

  factory GroupItem.fromLocalMap(Map<String, dynamic> map) =>
      GroupItem.fromJson(map);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'group_id': groupId,
      'order_item_id': orderItemId,
      'cart_line_key': cartLineKey,
      'assigned_qty': assignedQty,
    };
  }
}
