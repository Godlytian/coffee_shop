import 'dart:io';

import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:coffee_shop/features/printing/services/thermal_printer_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> showPrinterSettingsDialog(
  BuildContext context, {
  required void Function(String message, {bool isError}) onNotify,
}) async {
  await showDialog(
    context: context,
    builder: (context) => PrinterSettingsDialog(onNotify: onNotify),
  );
}

class PrinterSettingsDialog extends StatefulWidget {
  final void Function(String message, {bool isError}) onNotify;

  const PrinterSettingsDialog({super.key, required this.onNotify});

  @override
  State<PrinterSettingsDialog> createState() => _PrinterSettingsDialogState();
}

class _PrinterSettingsDialogState extends State<PrinterSettingsDialog> {
  final ThermalPrinterService _service = ThermalPrinterService.instance;

  List<BluetoothDevice> _devices = [];
  BluetoothDevice? _selectedDevice;
  bool _isLoading = true;
  bool _isConnected = false;
  String? _loadError;
  bool _autoPrintReceipt = true;
  bool _showPrintPopupAfterPayment = true;

  @override
  void initState() {
    super.initState();
    _initPrinter();
    _loadPreferences();
  }

  Future<bool> _ensureLocationServiceEnabled() async {
    try {
      final serviceStatus = await Permission.locationWhenInUse.serviceStatus;
      return serviceStatus == ServiceStatus.enabled;
    } on MissingPluginException {
      return true;
    }
  }

  Future<bool> _ensureBluetoothPermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }

    try {
      final locationServiceEnabled = await _ensureLocationServiceEnabled();
      if (!locationServiceEnabled) {
        throw Exception(
          'Location Services (GPS) is off. Please enable location service, then retry printer scan.',
        );
      }

      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

      final hasBluetoothPermission =
          (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
          (statuses[Permission.bluetoothConnect]?.isGranted ?? false);

      if (!hasBluetoothPermission) {
        return false;
      }

      final locationStatus = await Permission.locationWhenInUse.status;
      if (!locationStatus.isGranted) {
        final requested = await Permission.locationWhenInUse.request();
        if (!requested.isGranted) {
          return false;
        }
      }

      return true;
    } on MissingPluginException {
      return true;
    }
  }

  Future<void> _initPrinter() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final hasPermission = await _ensureBluetoothPermissions();
      if (!hasPermission) {
        throw Exception(
          'Bluetooth permission is required. Please allow Bluetooth and Location access for printer discovery.',
        );
      }

      final devices = await _service.getBondedDevices();
      final connected = await _service.isConnected;
      final prefs = await SharedPreferences.getInstance();
      final savedAddress = prefs.getString('printer_address');

      BluetoothDevice? targetDevice;
      if (savedAddress != null && devices.isNotEmpty) {
        try {
          targetDevice = devices.firstWhere((d) => d.address == savedAddress);
        } catch (_) {
          targetDevice = null;
        }
      }

      if (!mounted) return;
      setState(() {
        _devices = devices;
        _isConnected = connected;
        _selectedDevice =
            targetDevice ?? (devices.isNotEmpty ? devices.first : null);
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _devices = [];
        _selectedDevice = null;
        _isConnected = false;
        _isLoading = false;
        _loadError = error.toString().replaceFirst('Exception: ', '');
      });
      widget.onNotify(_loadError!, isError: true);
    }
  }

  Future<void> _handleConnect() async {
    if (_selectedDevice == null) return;

    setState(() => _isLoading = true);

    final success = await _service.connect(_selectedDevice!);

    if (success) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('printer_address', _selectedDevice!.address ?? '');
      await prefs.setString('printer_name', _selectedDevice!.name ?? '');

      if (mounted) {
        setState(() => _isConnected = true);
        widget.onNotify('Printer Connected!');
      }
    } else {
      if (mounted) {
        widget.onNotify('Connection Failed', isError: true);
      }
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _handleDisconnect() async {
    setState(() => _isLoading = true);
    await _service.disconnect();
    if (mounted) {
      setState(() {
        _isConnected = false;
        _isLoading = false;
      });
      widget.onNotify('Printer Disconnected');
    }
  }

  Future<void> _handleTestPrint() async {
    try {
      await _service.printTestReceipt(
        printerName: _selectedDevice?.name ?? 'Unknown',
      );
      widget.onNotify('Test Print Sent');
    } catch (e) {
      widget.onNotify(e.toString(), isError: true);
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _autoPrintReceipt = prefs.getBool('auto_print_receipt') ?? true;
      _showPrintPopupAfterPayment =
          prefs.getBool('show_print_popup_after_payment') ?? true;
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_print_receipt', _autoPrintReceipt);
    await prefs.setBool(
      'show_print_popup_after_payment',
      _showPrintPopupAfterPayment,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Printer Settings'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              const SizedBox(
                height: 100,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loadError != null)
              Column(
                children: [
                  Text(_loadError!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _initPrinter,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry Permission & Refresh'),
                  ),
                ],
              )
            else if (_devices.isEmpty)
              Column(
                children: [
                  const Text(
                    'No paired devices found.\nPair printer in Bluetooth settings, then refresh.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _initPrinter,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh Devices'),
                  ),
                ],
              )
            else
              Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _isConnected
                          ? Colors.green.withOpacity(0.1)
                          : Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _isConnected ? Icons.check_circle : Icons.error,
                          color: _isConnected ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _isConnected
                              ? 'Status: Connected'
                              : 'Status: Disconnected',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: _initPrinter,
                          tooltip: 'Refresh devices',
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 15),
                  DropdownButtonFormField<BluetoothDevice>(
                    decoration: const InputDecoration(
                      labelText: 'Select Printer',
                      border: OutlineInputBorder(),
                    ),
                    value: _selectedDevice,
                    isExpanded: true,
                    items: _devices.map((device) {
                      return DropdownMenuItem(
                        value: device,
                        child: Text(
                          device.name ?? 'Unknown Device',
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (device) {
                      setState(() {
                        _selectedDevice = device;
                      });
                    },
                  ),
                ],
              ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-print receipt after payment'),
              value: _autoPrintReceipt,
              onChanged: (value) async {
                setState(() {
                  _autoPrintReceipt = value;
                  if (_autoPrintReceipt) {
                    _showPrintPopupAfterPayment = false;
                  }
                });
                await _savePreferences();
              },
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show print popup after payment'),
              subtitle: const Text('Only active when auto-print is disabled'),
              value: _showPrintPopupAfterPayment,
              onChanged: _autoPrintReceipt
                  ? null
                  : (value) async {
                      setState(() => _showPrintPopupAfterPayment = value);
                      await _savePreferences();
                    },
            ),
          ],
        ),
      ),
      actions: [
        if (!_isLoading && _loadError == null && _devices.isNotEmpty) ...[
          if (_isConnected)
            TextButton.icon(
              onPressed: _handleTestPrint,
              icon: const Icon(Icons.print),
              label: const Text('Test Print'),
            ),
          if (_isConnected)
            TextButton(
              onPressed: _handleDisconnect,
              child: const Text(
                'Disconnect',
                style: TextStyle(color: Colors.red),
              ),
            )
          else
            ElevatedButton(
              onPressed: _handleConnect,
              child: const Text('Connect'),
            ),
        ],
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
