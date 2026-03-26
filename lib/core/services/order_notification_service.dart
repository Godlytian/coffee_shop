/*
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
*/
// lib/core/services/push_notification_service.dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// MUST be a top-level function to run when the app is terminated
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Display the notification manually if needed, or let FCM handle it
}

class PushNotificationService {
  static final PushNotificationService instance = PushNotificationService._();
  PushNotificationService._();

  final FlutterLocalNotificationsPlugin _localNotificationsPlugin = 
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    await Firebase.initializeApp();
    
    // Request permissions
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Setup Local Notifications (for custom sound and foreground display)
    const AndroidInitializationSettings androidInitSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosInitSettings = 
        DarwinInitializationSettings(
          requestSoundPermission: true,
          requestBadgePermission: true,
          requestAlertPermission: true,
        );

    const InitializationSettings initSettings = InitializationSettings(
      android: androidInitSettings,
      iOS: iosInitSettings,
    );

    await _localNotificationsPlugin.initialize(initSettings);

    // Create a specific channel for Android to enforce the custom sound
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'new_orders_channel', // id
      'New Orders', // name
      description: 'Notifications for new online orders',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('order_alert'), // Refers to the file in res/raw
    );

    await _localNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    // Get the FCM Token and save it to Supabase so your server knows where to send the push
    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken != null) {
      await _saveTokenToSupabase(fcmToken);
    }

    // Listen to token refreshes
    FirebaseMessaging.instance.onTokenRefresh.listen(_saveTokenToSupabase);
    
    // Listen for messages while app is open (Foreground)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      _showLocalNotification(message);
    });
  }

  Future<void> _saveTokenToSupabase(String token) async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        // You should create a 'fcm_tokens' table in Supabase to store these
        await Supabase.instance.client.from('fcm_tokens').upsert({
          'user_id': user.id,
          'token': token,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
    } catch (e) {
      debugPrint('Failed to save FCM token: $e');
    }
  }

  void _showLocalNotification(RemoteMessage message) {
    _localNotificationsPlugin.show(
      message.notification?.hashCode ?? 0,
      message.notification?.title ?? 'New Order!',
      message.notification?.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'new_orders_channel',
          'New Orders',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('order_alert'),
        ),
        iOS: DarwinNotificationDetails(
          sound: 'order_alert.wav',
          presentSound: true,
          presentAlert: true,
          presentBadge: true,
        ),
      ),
    );
  }
}