part of 'package:coffee_shop/features/cashier/presentation/screens/cashier_screen.dart';

class OnlineOrdersRepository {
  Stream<List<Map<String, dynamic>>> pendingOnlineOrdersStream() {
    List<Map<String, dynamic>> filterPaidOnline(
      List<Map<String, dynamic>> rows,
    ) => rows
        .where(
          (row) =>
              row['status'] == OrderStatus.paid &&
              row['order_source'] == 'online',
        )
        .toList(growable: false);

    final local = LocalOrderStoreRepository.instance.watchAllOrders().map(
      filterPaidOnline,
    );
    final remote = supabase
        .from('orders')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .map(
          (rows) => rows
              .map((row) => Map<String, dynamic>.from(row))
              .toList(growable: false),
        );

    return Stream<List<Map<String, dynamic>>>.multi((controller) {
      StreamSubscription<List<Map<String, dynamic>>>? localSub;
      StreamSubscription<List<Map<String, dynamic>>>? remoteSub;
      var hasRemoteConnection = false;

      localSub = local.listen((rows) {
        if (!hasRemoteConnection) {
          controller.add(rows);
        }
      }, onError: controller.addError);

      remoteSub = remote.listen(
        (rows) {
          hasRemoteConnection = true;
          controller.add(filterPaidOnline(rows));
        },
        onError: (error, stackTrace) {
          hasRemoteConnection = false;
          controller.addError(error, stackTrace);
        },
      );

      controller.onCancel = () async {
        await localSub?.cancel();
        await remoteSub?.cancel();
      };
    });
  }

  Stream<List<Map<String, dynamic>>> allOnlineOrdersStream() =>
      LocalOrderStoreRepository.instance.watchAllOrders();
}
