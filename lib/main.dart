import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FakeNotifApp());
}

class FakeNotifApp extends StatelessWidget {
  const FakeNotifApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إشعارات وهمية',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const HomeScreen(),
    );
  }
}

// ============================================================
// Model
// ============================================================
class FakeNotif {
  final String id;
  String appName;
  String title;
  String body;
  String? iconPath;
  DateTime scheduledAt;

  FakeNotif({
    required this.id,
    required this.appName,
    required this.title,
    required this.body,
    this.iconPath,
    required this.scheduledAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'appName': appName,
        'title': title,
        'body': body,
        'iconPath': iconPath,
        'scheduledAt': scheduledAt.toIso8601String(),
      };

  static FakeNotif fromJson(Map<String, dynamic> j) => FakeNotif(
        id: j['id'] as String,
        appName: j['appName'] as String,
        title: j['title'] as String,
        body: j['body'] as String,
        iconPath: j['iconPath'] as String?,
        scheduledAt: DateTime.parse(j['scheduledAt'] as String),
      );
}

// ============================================================
// Notification service
// ============================================================
class NotifService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;

    tzdata.initializeTimeZones();
    try {
      final String tzName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(tzName));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings init =
        InitializationSettings(android: androidInit);

    await _plugin.initialize(init);

    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.requestNotificationsPermission();
      await android.requestExactAlarmsPermission();
    }

    _inited = true;
  }

  static int _numericId(String s) {
    int h = 0;
    for (int i = 0; i < s.length; i++) {
      h = (h * 31 + s.codeUnitAt(i)) & 0x7fffffff;
    }
    return h;
  }

  static Future<void> schedule(FakeNotif n) async {
    await init();

    AndroidNotificationDetails? androidDetails;
    if (n.iconPath != null && n.iconPath!.isNotEmpty) {
      final File f = File(n.iconPath!);
      if (await f.exists()) {
        androidDetails = AndroidNotificationDetails(
          'fake_chan_${n.id}',
          n.appName,
          channelDescription: 'Fake notifications',
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          largeIcon: FilePathAndroidBitmap(n.iconPath!),
          styleInformation: BigTextStyleInformation(
            n.body,
            contentTitle: n.title,
          ),
        );
      }
    }
    androidDetails ??= AndroidNotificationDetails(
      'fake_chan_${n.id}',
      n.appName,
      channelDescription: 'Fake notifications',
      importance: Importance.max,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      styleInformation: BigTextStyleInformation(
        n.body,
        contentTitle: n.title,
      ),
    );

    final NotificationDetails details =
        NotificationDetails(android: androidDetails);

    final tz.TZDateTime when = tz.TZDateTime.from(n.scheduledAt, tz.local);

    if (when.isBefore(tz.TZDateTime.now(tz.local))) {
      await _plugin.show(_numericId(n.id), n.title, n.body, details);
      return;
    }

    try {
      await _plugin.zonedSchedule(
        _numericId(n.id),
        n.title,
        n.body,
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } on PlatformException {
      await _plugin.zonedSchedule(
        _numericId(n.id),
        n.title,
        n.body,
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  static Future<void> cancel(FakeNotif n) async {
    await init();
    await _plugin.cancel(_numericId(n.id));
  }

  static Future<void> cancelAll() async {
    await init();
    await _plugin.cancelAll();
  }
}

// ============================================================
// Storage
// ============================================================
class NotifStore {
  static const String _key = 'fake_notifs_v1';

  static Future<List<FakeNotif>> load() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String? raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return <FakeNotif>[];
    try {
      final List<dynamic> arr = jsonDecode(raw) as List<dynamic>;
      return arr
          .map((dynamic e) =>
              FakeNotif.fromJson(Map<String, dynamic>.from(e as Map<dynamic, dynamic>)))
          .toList();
    } catch (_) {
      return <FakeNotif>[];
    }
  }

  static Future<void> save(List<FakeNotif> list) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String raw =
        jsonEncode(list.map((FakeNotif e) => e.toJson()).toList());
    await p.setString(_key, raw);
  }
}

// ============================================================
// Home
// ============================================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<FakeNotif> _items = <FakeNotif>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await NotifService.init();
    final List<FakeNotif> loaded = await NotifStore.load();
    if (!mounted) return;
    setState(() {
      _items = loaded;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    await NotifStore.save(_items);
  }

  Future<void> _addOrEdit({FakeNotif? existing}) async {
    final FakeNotif? result = await Navigator.of(context).push<FakeNotif>(
      MaterialPageRoute<FakeNotif>(
        builder: (_) => EditorScreen(existing: existing),
      ),
    );
    if (result == null) return;
    setState(() {
      if (existing == null) {
        _items.add(result);
      } else {
        final int idx =
            _items.indexWhere((FakeNotif e) => e.id == existing.id);
        if (idx >= 0) {
          _items[idx] = result;
        }
      }
    });
    await _persist();
    await NotifService.schedule(result);
  }

  Future<void> _delete(FakeNotif n) async {
    await NotifService.cancel(n);
    setState(() {
      _items.removeWhere((FakeNotif e) => e.id == n.id);
    });
    await _persist();
  }

  Future<void> _fireNow(FakeNotif n) async {
    final FakeNotif immediate = FakeNotif(
      id: n.id,
      appName: n.appName,
      title: n.title,
      body: n.body,
      iconPath: n.iconPath,
      scheduledAt: DateTime.now(),
    );
    await NotifService.schedule(immediate);
  }

  Future<void> _cancelAll() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('إلغاء الكل'),
        content: const Text('هل تريد إلغاء جميع الإشعارات المجدولة؟'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('لا'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('نعم'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await NotifService.cancelAll();
    setState(() {
      _items = <FakeNotif>[];
    });
    await _persist();
  }

  String _fmt(DateTime d) {
    final String dd = d.day.toString().padLeft(2, '0');
    final String mm = d.month.toString().padLeft(2, '0');
    final String yy = d.year.toString();
    final String hh = d.hour.toString().padLeft(2, '0');
    final String mi = d.minute.toString().padLeft(2, '0');
    return '$yy/$mm/$dd  $hh:$mi';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('إشعارات وهمية'),
          backgroundColor: const Color(0xFF1F1B24),
          actions: <Widget>[
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'إلغاء الكل',
              onPressed: _items.isEmpty ? null : _cancelAll,
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _addOrEdit(),
          icon: const Icon(Icons.add),
          label: const Text('إشعار جديد'),
          backgroundColor: const Color(0xFF5E35B1),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'لا توجد إشعارات مجدولة.\nاضغط "إشعار جديد" للبدء.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF9E9E9E)),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (BuildContext ctx, int i) {
                      final FakeNotif n = _items[i];
                      return Card(
                        color: const Color(0xFF1E1E1E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: n.iconPath != null &&
                                    File(n.iconPath!).existsSync()
                                ? Image.file(
                                    File(n.iconPath!),
                                    width: 44,
                                    height: 44,
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    width: 44,
                                    height: 44,
                                    color: const Color(0xFF4527A0),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.notifications,
                                      color: Colors.white,
                                    ),
                                  ),
                          ),
                          title: Text(
                            n.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                n.appName,
                                style: const TextStyle(
                                  color: Color(0xFFB39DDB),
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                n.body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFCCCCCC),
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _fmt(n.scheduledAt),
                                style: const TextStyle(
                                  color: Color(0xFF9E9E9E),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                          trailing: PopupMenuButton<String>(
                            color: const Color(0xFF2A2A2A),
                            onSelected: (String v) {
                              if (v == 'now') {
                                _fireNow(n);
                              } else if (v == 'edit') {
                                _addOrEdit(existing: n);
                              } else if (v == 'delete') {
                                _delete(n);
                              }
                            },
                            itemBuilder: (_) => const <PopupMenuEntry<String>>[
                              PopupMenuItem<String>(
                                value: 'now',
                                child: Text('إطلاق فوري'),
                              ),
                              PopupMenuItem<String>(
                                value: 'edit',
                                child: Text('تعديل'),
                              ),
                              PopupMenuItem<String>(
                                value: 'delete',
                                child: Text('حذف'),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

// ============================================================
// Editor
// ============================================================
class EditorScreen extends StatefulWidget {
  final FakeNotif? existing;
  const EditorScreen({super.key, this.existing});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final TextEditingController _appCtrl;
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  final ScrollController _scrollCtrl = ScrollController();
  final ImagePicker _picker = ImagePicker();

  String? _iconPath;
  DateTime _scheduledAt = DateTime.now().add(const Duration(minutes: 1));

  @override
  void initState() {
    super.initState();
    final FakeNotif? e = widget.existing;
    _appCtrl = TextEditingController(text: e?.appName ?? 'WhatsApp');
    _titleCtrl = TextEditingController(text: e?.title ?? 'رسالة جديدة');
    _bodyCtrl = TextEditingController(
        text: e?.body ?? 'هذا نص إشعار تجريبي يمكنك تخصيصه بالكامل.');
    _iconPath = e?.iconPath;
    if (e != null) _scheduledAt = e.scheduledAt;
  }

  @override
  void dispose() {
    _appCtrl.dispose();
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickIcon() async {
    try {
      PermissionStatus st = await Permission.photos.request();
      if (!st.isGranted && !st.isLimited) {
        final PermissionStatus st2 = await Permission.storage.request();
        if (!st2.isGranted) return;
      }
      final XFile? x = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
      );
      if (x == null) return;

      final Directory dir = await getApplicationDocumentsDirectory();
      final String ext = x.path.contains('.')
          ? x.path.substring(x.path.lastIndexOf('.'))
          : '.png';
      final String dest =
          '${dir.path}/icon_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(x.path).copy(dest);

      if (!mounted) return;
      setState(() {
        _iconPath = dest;
      });
    } catch (_) {}
  }

  void _clearIcon() {
    setState(() {
      _iconPath = null;
    });
  }

  Future<void> _pickDateTime() async {
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: _scheduledAt,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null) return;
    if (!mounted) return;
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_scheduledAt),
    );
    if (t == null) return;
    setState(() {
      _scheduledAt =
          DateTime(d.year, d.month, d.day, t.hour, t.minute);
    });
  }

  void _save() {
    final String app = _appCtrl.text.trim().isEmpty
        ? 'App'
        : _appCtrl.text.trim();
    final String title = _titleCtrl.text.trim().isEmpty
        ? '(بدون عنوان)'
        : _titleCtrl.text.trim();
    final String body =
        _bodyCtrl.text.trim().isEmpty ? ' ' : _bodyCtrl.text.trim();

    final FakeNotif n = FakeNotif(
      id: widget.existing?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      appName: app,
      title: title,
      body: body,
      iconPath: _iconPath,
      scheduledAt: _scheduledAt,
    );
    Navigator.of(context).pop(n);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.existing == null
              ? 'إشعار جديد'
              : 'تعديل الإشعار'),
          backgroundColor: const Color(0xFF1F1B24),
          actions: <Widget>[
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _save,
            ),
          ],
        ),
        body: SingleChildScrollView(
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('اسم التطبيق',
                  style: TextStyle(color: Color(0xFFB39DDB))),
              const SizedBox(height: 6),
              TextField(
                controller: _appCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDeco('مثال: WhatsApp'),
              ),
              const SizedBox(height: 14),
              const Text('عنوان الإشعار',
                  style: TextStyle(color: Color(0xFFB39DDB))),
              const SizedBox(height: 6),
              TextField(
                controller: _titleCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDeco('عنوان قصير'),
              ),
              const SizedBox(height: 14),
              const Text('محتوى الرسالة',
                  style: TextStyle(color: Color(0xFFB39DDB))),
              const SizedBox(height: 6),
              TextField(
                controller: _bodyCtrl,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDeco('نص الإشعار'),
              ),
              const SizedBox(height: 18),
              const Text('الأيقونة',
                  style: TextStyle(color: Color(0xFFB39DDB))),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _iconPath != null && File(_iconPath!).existsSync()
                        ? Image.file(
                            File(_iconPath!),
                            width: 64,
                            height: 64,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            width: 64,
                            height: 64,
                            color: const Color(0xFF2A2A2A),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.image,
                              color: Color(0xFF777777),
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _pickIcon,
                      icon: const Icon(Icons.photo_library),
                      label: const Text('اختر صورة من الاستوديو'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5E35B1),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  if (_iconPath != null) ...<Widget>[
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _clearIcon,
                      icon: const Icon(Icons.close, color: Colors.redAccent),
                      tooltip: 'مسح الأيقونة',
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 18),
              const Text('موعد الإرسال',
                  style: TextStyle(color: Color(0xFFB39DDB))),
              const SizedBox(height: 8),
              InkWell(
                onTap: _pickDateTime,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF4527A0)),
                  ),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.schedule,
                          color: Color(0xFFB39DDB)),
                      const SizedBox(width: 10),
                      Text(
                        _fmtFull(_scheduledAt),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('حفظ وجدولة'),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF666666)),
      filled: true,
      fillColor: const Color(0xFF1E1E1E),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF333333)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF7E57C2)),
      ),
    );
  }

  static String _fmtFull(DateTime d) {
    final String dd = d.day.toString().padLeft(2, '0');
    final String mm = d.month.toString().padLeft(2, '0');
    final String yy = d.year.toString();
    final String hh = d.hour.toString().padLeft(2, '0');
    final String mi = d.minute.toString().padLeft(2, '0');
    return '$yy/$mm/$dd  $hh:$mi';
  }
}