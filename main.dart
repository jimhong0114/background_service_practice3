import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();//建立通知插件的全域實例

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();//初始化 Flutter 綁定，保證可以在 main 執行前使用平台通訊

  final hasPermission = await _checkNotificationPermissionAtStartup();//檢查通知權限

  ///如果沒權限就跳轉到提示畫面
  if (!hasPermission) {
    runApp(const PermissionDeniedApp());
    return;
  }

  await _initializeApp();//初始化應用
  runApp(const MyApp());//啟動 UI
}

Future<bool> _checkNotificationPermissionAtStartup() async {

  ///如果是 Android，取得裝置 SDK 版本
  if (Platform.isAndroid) {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;

    ///Android 13+ 需要請求通知權限，否則直接通過
    if (androidInfo.version.sdkInt >= 33) {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        final result = await Permission.notification.request();
        return result.isGranted;
      }
    }
  }
  return true;
}

Future<void> _initializeApp() async {

  final deviceInfo = DeviceInfoPlugin();// 取得裝置資訊以識別裝置名稱
  String? device;// 取得裝置資訊以識別裝置名稱

  ///依平台選擇裝置名稱
  if (Platform.isAndroid) {
    final androidInfo = await deviceInfo.androidInfo;
    device = androidInfo.model;
  } else if (Platform.isIOS) {
    final iosInfo = await deviceInfo.iosInfo;
    device = iosInfo.utsname.machine;
  }

  final prefs = await SharedPreferences.getInstance();//儲存裝置名稱到本地偏好設定
  await prefs.setString("device_name", device ?? "unknown");//儲存裝置名稱到本地偏好設定

  /// 初始化通知插件
  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(
      iOS: DarwinInitializationSettings(),
      android: AndroidInitializationSettings('ic_bg_service_small'),
    ),
  );

  /// 定義 Android 的通知頻道
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground',
    'MY FOREGROUND SERVICE',
    description: 'This channel is used for important notifications.',
    importance: Importance.max,
  );


  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);//建立通知頻道（僅 Android）


  await initializeService();// 初始化背景服務

  ///當服務啟動時，傳送裝置名稱給背景 Isolate
  FlutterBackgroundService().on('onServiceStarted').listen((event) {
    FlutterBackgroundService().invoke('setDevice', {
      'device': device ?? 'unknown',
    });
  });
}


Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'my_foreground',
      initialNotificationTitle: 'AWESOME SERVICE',
      initialNotificationContent: 'Initializing',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),//Android 設定：服務開機啟動、前景模式、通知樣式等
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
    ),//iOS 設定：僅支援前景執行
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) {
  service.invoke('onServiceStarted');//傳送服務啟動通知給主程式

  String device = "unknown";

  service.on('setDevice').listen((event) {
    device = event?['device'] ?? "unknown";
  });//監聽主程式傳來的裝置名稱

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((_) {
    service.stopSelf();
  });//可切換前/背景模式或停止服務

  Future.delayed(const Duration(seconds: 1), () {  //延遲1秒後
    Timer.periodic(const Duration(seconds: 1), (timer) async {  //每秒執行一次

      ///更新通知與資料，並傳送給主程式
      try {
        if (service is AndroidServiceInstance) {
          final androidService = service as AndroidServiceInstance;

          if (!await androidService.isForegroundService()) return;


          if (Platform.isAndroid &&
              !(await Permission.notification.isGranted)) {
            return;
          }

          await androidService.setForegroundNotificationInfo(
            title: "前景通知測試",
            content: "現在時間 ${DateTime.now()}",
          );
        }

        service.invoke('update', {
          "current_date": DateTime.now().toIso8601String(),
          "device": device,
        });
      } catch (e) {
        final sp = await SharedPreferences.getInstance();
        final logs = sp.getStringList('log') ?? [];
        logs.add("[ERROR] ${DateTime.now()} $e");
        await sp.setStringList('log', logs);
      }//若有錯誤，將錯誤記錄儲存在偏好設定中供 UI 顯示
    });
  });
}

///主畫面 Stateful Widget，控制服務的啟動與停止
class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String text = "Stop Service";

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Service App')),
        body: Column(
          children: [
            ///透過資料流接收背景服務傳來的時間與裝置資訊
            StreamBuilder<Map<String, dynamic>?>(
              stream: FlutterBackgroundService().on('update'),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.data!;
                String? device = data["device"];
                DateTime? date = DateTime.tryParse(data["current_date"] ?? "");
                return Column(
                  children: [
                    Text(device ?? 'Unknown'),
                    Text(date.toString()),
                  ],
                );
              },
            ),
            ElevatedButton(
              child: const Text("Foreground Mode"),
              onPressed: () =>
                  FlutterBackgroundService().invoke("setAsForeground"),
            ),
            ElevatedButton(
              child: const Text("Background Mode"),
              onPressed: () =>
                  FlutterBackgroundService().invoke("setAsBackground"),
            ),
            ElevatedButton(
              child: Text(text),
              onPressed: () async {
                final service = FlutterBackgroundService();
                var isRunning = await service.isRunning();
                isRunning
                    ? service.invoke("stopService")
                    : service.startService();

                setState(() {
                  text = isRunning ? 'Start Service' : 'Stop Service';
                });
              },
            ),
            const Expanded(child: LogView()),//顯示錯誤日誌（從 SharedPreferences 取得）
          ],
        ),
      ),
    );
  }
}

///每秒更新一次錯誤日誌
class LogView extends StatefulWidget {
  const LogView({Key? key}) : super(key: key);

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  late final Timer timer;
  List<String> logs = [];

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.reload();
      logs = sp.getStringList('log') ?? [];
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: logs.length,
      itemBuilder: (context, index) {
        return Text(logs[index]);
      },
    );
  }
}

///若通知權限沒開啟，顯示提示畫面與按鈕前往設定
class PermissionDeniedApp extends StatelessWidget {
  const PermissionDeniedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("需要通知權限才能繼續使用此 App"),
              ElevatedButton(
                onPressed: () async {
                  await openAppSettings();
                },
                child: const Text("前往設定開啟權限"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
