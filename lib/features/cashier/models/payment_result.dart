part of '../presentation/screens/cashier_screen.dart';

class _PaymentResult {
  final String method;
  final num totalPaymentReceived;
  final num changeAmount;

  _PaymentResult({
    required this.method,
    required this.totalPaymentReceived,
    required this.changeAmount,
  });
}
