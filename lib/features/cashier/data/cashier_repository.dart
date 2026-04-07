part of '../presentation/screens/cashier_screen.dart';

class CashierRepository {
  Stream<List<Map<String, dynamic>>> allOrdersStream({
    required int? cashierId,
    required int? shiftId,
  }) {
    return LocalOrderStoreRepository.instance.watchAllOrders();
  }

  Stream<List<Map<String, dynamic>>> activeOrdersStream({
    required int? cashierId,
    required int? shiftId,
  }) {
    return LocalOrderStoreRepository.instance.watchActiveOrders();
  }

  Future<List<Map<String, dynamic>>> fetchOtherActiveOrders({
    int? excludedOrderId,
    required int? cashierId,
    required int? shiftId,
  }) async {
    final rows = await LocalOrderStoreRepository.instance.fetchAllOrders();
    return rows
        .where((row) {
          if (row['deleted_at'] != null) return false;

          final status = row['status']?.toString();
          final sessionStatus = row['session_status']?.toString();
          final type = row['type']?.toString();

          bool isActive =
              status == 'active' ||
              ((sessionStatus == 'open' || type == 'dine_in') &&
                  (status == 'pending' || status == 'paid'));

          return isActive &&
              ((row['id'] as num?)?.toInt() ?? -1) != (excludedOrderId ?? -1);
        })
        .toList(growable: false);
  }
}
