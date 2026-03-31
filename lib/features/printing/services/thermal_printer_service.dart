import 'dart:async';

import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:coffee_shop/core/utils/formatters.dart';
import 'package:flutter/services.dart';

class ThermalPrinterService {
  ThermalPrinterService._();
  static final ThermalPrinterService instance = ThermalPrinterService._();

  final BlueThermalPrinter _printer = BlueThermalPrinter.instance;

  String _formatPrice(num value) => CurrencyFormatters.formatRupiah(value);

  String _truncateForPaper(String value, {int maxChars = 20}) {
    final clean = value.trim();
    if (clean.length <= maxChars) return clean;
    return '${clean.substring(0, maxChars - 1)}…';
  }

  Future<List<BluetoothDevice>> getBondedDevices() async {
    try {
      final devices = await _printer.getBondedDevices().timeout(
        const Duration(seconds: 8),
      );
      return devices;
    } on TimeoutException {
      throw Exception(
        'Bluetooth scan timeout. Make sure Bluetooth is on, then tap Refresh.',
      );
    } on PlatformException catch (error) {
      throw Exception(
        error.message ?? 'Failed to load paired bluetooth devices.',
      );
    } catch (error) {
      throw Exception('Failed to load paired bluetooth devices: $error');
    }
  }

  Future<bool> get isConnected async {
    try {
      return await _printer.isConnected ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> connect(BluetoothDevice device) async {
    try {
      if (await isConnected) {
        return true;
      }
      await _printer.connect(device).timeout(const Duration(seconds: 10));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> disconnect() async {
    try {
      await _printer.disconnect();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// CUSTOMER RECEIPT
  Future<void> printPaymentReceipt({
    required int orderId,
    required List<Map<String, dynamic>> lines,
    required num total,
    required String paymentMethod,
    required num paid,
    required num change,
    String? customerName,
    String? tableName,
    String? orderType, // Added Order Type
  }) async {
    if (!(await isConnected)) {
      throw Exception('Printer not connected');
    }

    // Get last 3 digits of order ID (or pad with zeros if it's less than 3 digits)
    final orderIdStr = orderId.toString();
    final shortOrderId = orderIdStr.length >= 3
        ? orderIdStr.substring(orderIdStr.length - 3)
        : orderIdStr.padLeft(3, '0');

    await _printer.printNewLine();
    // 2 = Size, 1 = Center align
    await _printer.printCustom('ULUN', 2, 1);
    await _printer.printCustom('ORDER #$shortOrderId', 1, 1);
    await _printer.printCustom(
      DateTime.now().toString().substring(0, 16),
      1,
      1,
    );
    await _printer.printCustom('--------------------------------', 1, 1);

    // Print customer info only if provided
    if (customerName != null && customerName.trim().isNotEmpty) {
      await _printer.printCustom('Customer: $customerName', 1, 0);
    }
    if (tableName != null && tableName.trim().isNotEmpty) {
      await _printer.printCustom('Table: $tableName', 1, 0);
    }
    if (orderType != null && orderType.trim().isNotEmpty) {
      await _printer.printCustom('Order Type: $orderType', 1, 0);
    }

    await _printer.printNewLine();
    await _printer.printCustom('Item(s):', 1, 0);

    // Loop through order items
    for (final line in lines) {
      final name = line['name']?.toString() ?? '-';
      final qty = (line['qty'] as num?)?.toInt() ?? 1;
      final subtotal = (line['subtotal'] as num?) ?? 0;

      // printLeftRight puts the item name and price perfectly on opposite sides
      await _printer.printLeftRight('$qty $name', _formatPrice(subtotal), 1);

      // Handle Add-ons if they exist in your data structure
      if (line['addons'] != null) {
        final addons = line['addons'] as List<dynamic>;
        for (final addonObj in addons) {
          final addon = addonObj as Map<String, dynamic>;
          final addonName = addon['name']?.toString() ?? 'Add-on';
          final addonPrice = (addon['price'] as num?) ?? 0;

          if (addonPrice > 0) {
            await _printer.printLeftRight(
              '  -$addonName',
              _formatPrice(addonPrice),
              1,
            );
          } else {
            // If add-on is free, just print the name
            await _printer.printCustom('  -$addonName', 1, 0);
          }
        }
      }
    }

    await _printer.printCustom('--------------------------------', 1, 1);

    // Totals and Payments
    await _printer.printLeftRight('Total:', _formatPrice(total), 1);
    await _printer.printLeftRight(
      'Payment Method:',
      paymentMethod.toUpperCase(),
      1,
    );

    // Hide Paid and Change lines if the payment is QRIS
    if (paymentMethod.toLowerCase() != 'qris') {
      await _printer.printLeftRight('Paid:', _formatPrice(paid), 1);
      await _printer.printLeftRight('Change:', _formatPrice(change), 1);
    }

    // Footer
    await _printer.printNewLine();
    await _printer.printCustom('Thank You', 1, 1);
    await _printer.printCustom('Wifi: CAFEULUN', 1, 1);
    await _printer.printCustom('Password: punyaulun', 1, 1);

    await _printer.printNewLine();
    await _printer.printNewLine();
    await _printer.paperCut();
  }

  /// SHIFT REPORT RECEIPT
  Future<void> printShiftReceipt({
    required int shiftId,
    required String cashierName,
    required String openedAt,
    required String closedAt,
    required List<Map<String, dynamic>> items,
    required int totalOrders,
    required num cashTotal,
    required num qrisTotal,
    required num total,
  }) async {
    if (!(await isConnected)) {
      throw Exception('Printer not connected');
    }

    await _printer.printNewLine();
    await _printer.printCustom('ULUN', 2, 1);
    await _printer.printCustom('SHIFT #$shiftId', 1, 1);
    await _printer.printCustom(
      DateTime.now().toString().substring(0, 16),
      1,
      1,
    );
    await _printer.printCustom('--------------------------------', 1, 1);

    await _printer.printCustom('Cashier: $cashierName', 1, 0);
    await _printer.printCustom('Opened: $openedAt', 1, 0);
    await _printer.printCustom('Closed: $closedAt', 1, 0);
    await _printer.printCustom('Total Orders: $totalOrders', 1, 0);

    await _printer.printNewLine();
    await _printer.printCustom('Items:', 1, 0);

    for (final item in items) {
      final name = item['name']?.toString() ?? '-';
      final qty = (item['qty'] as num?)?.toInt() ?? 1;
      final subtotal = (item['subtotal'] as num?) ?? 0;
      final compactLabel = '$qty ${_truncateForPaper(name)}';

      await _printer.printLeftRight(compactLabel, _formatPrice(subtotal), 1);
      if (item['addons'] != null) {
        final addons = item['addons'] as List<dynamic>;
        for (final addonObj in addons) {
          final addon = addonObj as Map<String, dynamic>;
          final addonName = addon['name']?.toString() ?? 'Add-on';
          final addonPrice = (addon['price'] as num?) ?? 0;
          if (addonPrice > 0) {
            await _printer.printLeftRight(
              '  +$addonName',
              _formatPrice(addonPrice),
              1,
            );
          }
        }
      }
    }

    await _printer.printCustom('--------------------------------', 1, 1);
    await _printer.printLeftRight('Cash:', _formatPrice(cashTotal), 1);
    await _printer.printLeftRight('QRIS:', _formatPrice(qrisTotal), 1);
    await _printer.printLeftRight('Total:', _formatPrice(total), 1);

    await _printer.printNewLine();
    await _printer.printNewLine();
    await _printer.paperCut();
  }

  /// Print a simple test receipt
  Future<void> printTestReceipt({required String printerName}) async {
    if (!(await isConnected)) {
      throw Exception('Printer not connected');
    }

    await _printer.printNewLine();
    await _printer.printCustom('CONNECTED SUCCESS', 2, 1);
    await _printer.printNewLine();
    await _printer.printCustom('Device: $printerName', 1, 0);
    await _printer.printCustom(
      'Date: ${DateTime.now().toString().substring(0, 16)}',
      1,
      0,
    );
    await _printer.printNewLine();
    await _printer.printCustom('--------------------------------', 1, 1);
    await _printer.paperCut();
  }
}
