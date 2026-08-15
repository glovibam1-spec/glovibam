import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();

  // ================= Crashlytics =================
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

  await _initLocalNotifications();

  runApp(const GlovibamApp());
}

Future<void> _initLocalNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);
  await _localNotifications.initialize(initSettings);
}

class GlovibamApp extends StatelessWidget {
  const GlovibamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GLOVIBAM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String siteUrl = 'https://glovibam.com';

  late final WebViewController controller;

  double loadingProgress = 0;
  bool isLoading = true;
  bool hasError = false;
  bool isOffline = false;

  late final StreamSubscription<List<ConnectivityResult>> _connectivitySub;

  // امتدادات الملفات التي تعتبر "تنزيل" وليست صفحة عادية
  static const List<String> downloadableExtensions = [
    '.pdf',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.zip',
    '.rar',
  ];

  @override
  void initState() {
    super.initState();
    _initConnectivityListener();
    _initWebView();
    _initPushNotifications();
  }

  // ================= الإشعارات =================

  Future<void> _initPushNotifications() async {
    final messaging = FirebaseMessaging.instance;

    await messaging.requestPermission(alert: true, badge: true, sound: true);

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification != null) {
        _localNotifications.show(
          notification.hashCode,
          notification.title,
          notification.body,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'high_importance_channel',
              'إشعارات مهمة',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      final link = message.data['url'];
      if (link != null && link is String) {
        controller.loadRequest(Uri.parse(link));
      }
    });
  }

  // ================= الاتصال بالإنترنت =================

  void _initConnectivityListener() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final offline = results.every((r) => r == ConnectivityResult.none);
      setState(() {
        isOffline = offline;
      });
      if (!offline && hasError) {
        _reload();
      }
    });
  }

  // ================= فتح الروابط الخارجية =================

  bool _isExternalLink(String url) {
    return url.startsWith('tel:') ||
        url.startsWith('mailto:') ||
        url.startsWith('https://wa.me') ||
        url.startsWith('https://api.whatsapp.com') ||
        url.startsWith('whatsapp:') ||
        url.startsWith('geo:') ||
        url.contains('maps.google.com') ||
        url.contains('goo.gl/maps');
  }

  bool _isDownloadableFile(String url) {
    final lowerUrl = url.toLowerCase();
    return downloadableExtensions.any((ext) => lowerUrl.endsWith(ext));
  }

  Future<void> _openExternally(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذّر فتح الرابط: $url')));
      }
    }
  }

  // ================= WebView =================

  void _initWebView() {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            setState(() {
              loadingProgress = progress / 100;
            });
          },
          onPageStarted: (String url) {
            setState(() {
              isLoading = true;
              hasError = false;
            });
          },
          onPageFinished: (String url) {
            setState(() {
              isLoading = false;
            });
          },
          onWebResourceError: (WebResourceError error) {
            setState(() {
              isLoading = false;
              hasError = true;
            });
            FirebaseCrashlytics.instance.recordError(
              'WebView error: ${error.description}',
              null,
              fatal: false,
            );
          },
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;

            // روابط خارجية (واتساب، اتصال، بريد، خرائط)
            if (_isExternalLink(url)) {
              _openExternally(url);
              return NavigationDecision.prevent;
            }

            // ملفات للتنزيل (فواتير PDF وغيرها)
            if (_isDownloadableFile(url)) {
              _openExternally(url);
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(siteUrl));

    // تفعيل دعم رفع الملفات والصور (Android فقط)
    if (controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      androidController.setOnShowFileSelector(_androidFilePicker);
    }
  }

  // معالج اختيار الملفات عند طلب الموقع رفع صورة/ملف
  Future<List<String>> _androidFilePicker(FileSelectorParams params) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.any,
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        return [Uri.file(path).toString()];
      }
    } catch (e) {
      FirebaseCrashlytics.instance.recordError(e, null, fatal: false);
    }
    return [];
  }

  void _reload() {
    setState(() {
      hasError = false;
      isLoading = true;
    });
    controller.reload();
  }

  Future<bool> _onWillPop() async {
    if (await controller.canGoBack()) {
      controller.goBack();
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    _connectivitySub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).maybePop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('GLOVIBAM'), elevation: 0),
        body: SafeArea(
          child: Column(
            children: [
              if (isLoading && !isOffline)
                LinearProgressIndicator(
                  value: loadingProgress == 0 ? null : loadingProgress,
                  minHeight: 3,
                ),
              Expanded(
                child: isOffline
                    ? _buildOfflineView()
                    : hasError
                    ? _buildErrorView()
                    : RefreshIndicator(
                        onRefresh: () async {
                          controller.reload();
                          await Future.delayed(
                            const Duration(milliseconds: 500),
                          );
                        },
                        child: WebViewWidget(controller: controller),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOfflineView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 72, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'لا يوجد اتصال بالإنترنت',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'تأكد من اتصالك بالشبكة ثم حاول مرة أخرى',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 72,
              color: Colors.redAccent,
            ),
            const SizedBox(height: 16),
            const Text(
              'حدث خطأ أثناء تحميل الصفحة',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}
