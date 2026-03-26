import 'dart:async';

import 'package:app_badger/app_badger.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OrderNotificationService {
  OrderNotificationService._();

  static final OrderNotificationService instance = OrderNotificationService._();

  static const List<String> _activeOrderStatuses = <String>[
    'pending',
    'processing',
    'assigned',
  ];

  final AudioPlayer _audioPlayer = AudioPlayer();
  RealtimeChannel? _channel;
  bool _initialized = false;
  int _unreadCount = 0;

  DateTime? _lastAlertAt;

  Future<void> initialize() async {
    if (_initialized) return;

    await Permission.notification.request();

    await _audioPlayer.setAudioContext(
      AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.ambient,
          options: {
            AVAudioSessionOptions.mixWithOthers,
            AVAudioSessionOptions.defaultToSpeaker,
          },
        ),
      ),
    );
    await _refreshUnreadCount();
    await _applyBadge();

    _channel = Supabase.instance.client
        .channel('public:orders:notifications')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'orders',
          callback: (payload) {
            unawaited(_handleOrderInsert(payload));
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          callback: (payload) {
            unawaited(_handleOrderUpdate(payload));
          },
        )
        .subscribe();

    _initialized = true;
  }

  Future<void> clearUnreadNotifications() async {
    _unreadCount = 0;
    try {
      await AppBadger.removeBadge();
    } catch (error) {
      debugPrint('Failed to clear app badge: $error');
    }
  }

  Future<void> playAlertOnce() async {
    final now = DateTime.now();
    if (_lastAlertAt != null &&
        now.difference(_lastAlertAt!) < const Duration(seconds: 1)) {
      return;
    }
    _lastAlertAt = now;
    await _playAlert();
  }

  Future<void> _handleOrderInsert(PostgresChangePayload payload) async {
    final newRow = payload.newRecord;
    final source = newRow['order_source']?.toString().toLowerCase();
    if (source != 'online') {
      return;
    }

    await _refreshUnreadCount();
    await _applyBadge();
  }

  Future<void> _handleOrderUpdate(PostgresChangePayload payload) async {
    final newRow = payload.newRecord;
    final oldRow = payload.oldRecord;

    final source = newRow['order_source']?.toString().toLowerCase();

    if (source != 'online') {
      return;
    }

    final oldStatus = oldRow['status']?.toString().toLowerCase();
    final newStatus = newRow['status']?.toString().toLowerCase();

    final justPaid = oldStatus != 'paid' && newStatus == 'paid';

    if (justPaid) {
      await playAlertOnce();
      await _refreshUnreadCount();
      await _applyBadge();
    }
  }

  Future<void> _playAlert() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/order_alert.wav'));
    } catch (error) {
      debugPrint('Failed to play order alert sound: $error');
    }
  }

  Future<void> _refreshUnreadCount() async {
    try {
      final rows = await Supabase.instance.client
          .from('orders')
          .select('id')
          .eq('order_source', 'online')
          .inFilter('status', _activeOrderStatuses);
      _unreadCount = (rows as List<dynamic>).length;
    } catch (error) {
      debugPrint('Failed to refresh unread online orders count: $error');
    }
  }

  Future<void> _applyBadge() async {
    try {
      if (_unreadCount <= 0) {
        await AppBadger.removeBadge();
        return;
      }
      await AppBadger.updateBadgeCount(_unreadCount);
    } catch (error) {
      debugPrint('Failed to update app badge: $error');
    }
  }
}
