import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:first/firebase_options.dart';

/// Background handler must be top-level.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('FCM background: ${message.messageId} ${message.data}');
}

class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();

  bool _initialized = false;

  bool get isReady => _initialized;

  Future<void> initAfterSupabase() async {
    if (_initialized) return;
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e, st) {
      debugPrint('Firebase init skipped (add flutterfire configure / dart-define): $e\n$st');
      return;
    }

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    final messaging = FirebaseMessaging.instance;
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('FCM permission denied');
    }

    FirebaseMessaging.onMessage.listen((RemoteMessage m) {
      debugPrint('FCM foreground: ${m.data}');
    });

    FirebaseMessaging.instance.onTokenRefresh.listen(_upsertToken);

    await _refreshAndStoreToken();
    _initialized = true;
  }

  Future<void> onAuthSessionReady() async {
    if (!_initialized) return;
    await _refreshAndStoreToken();
  }

  Future<void> onSignedOut() async {
    if (!_initialized) return;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  /// Removes only this install's row from [device_tokens] (call while still signed in).
  Future<void> removeCurrentDeviceTokenFromSupabase() async {
    if (!_initialized) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await Supabase.instance.client
          .from('device_tokens')
          .delete()
          .eq('user_id', uid)
          .eq('fcm_token', token);
    } catch (e) {
      debugPrint('device_tokens delete (this device): $e');
    }
  }

  Future<void> _refreshAndStoreToken() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await _upsertToken(token);
    } catch (e) {
      debugPrint('FCM getToken: $e');
    }
  }

  Future<void> _upsertToken(String token) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await Supabase.instance.client.from('device_tokens').upsert(
        {
          'user_id': uid,
          'fcm_token': token,
          'platform': Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'other'),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,fcm_token',
      );
    } catch (e) {
      debugPrint('device_tokens upsert: $e');
    }
  }
}
