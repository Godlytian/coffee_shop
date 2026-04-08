class GroupItem {
  final String id;
  final String groupId;
  final int orderItemId;
  final int assignedQty;

  const GroupItem({
    required this.id,
    required this.groupId,
    required this.orderItemId,
    required this.assignedQty,
  });

  factory GroupItem.fromJson(Map<String, dynamic> json) {
    return GroupItem(
      id: json['id']?.toString() ?? '',
      groupId: json['group_id']?.toString() ?? '',
      orderItemId: (json['order_item_id'] as num?)?.toInt() ?? 0,
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
      'assigned_qty': assignedQty,
    };
  }
}
