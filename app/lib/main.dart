/// Ứng dụng Sách lười.
///
/// Chạy trên Windows như một ứng dụng desktop bình thường; toàn bộ giao diện và
/// logic viết bằng Dart nên phần lớn dùng lại được khi đưa lên Android/iOS.
library;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'state/app_state.dart';
import 'ui/app_scope.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const SachLuoiApp());
}

class SachLuoiApp extends StatefulWidget {
  const SachLuoiApp({super.key});

  @override
  State<SachLuoiApp> createState() => _SachLuoiAppState();
}

class _SachLuoiAppState extends State<SachLuoiApp> {
  late final Future<AppState> _future = AppState.create();
  AppState? _state;

  @override
  void dispose() {
    _state?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppState>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light),
            home: _StartupError(error: snapshot.error!),
          );
        }
        if (!snapshot.hasData) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.dark),
            home: const _Splash(),
          );
        }

        _state = snapshot.data;
        final state = snapshot.data!;
        return AppScope(
          state: state,
          child: AnimatedBuilder(
            animation: state,
            builder: (context, _) => MaterialApp(
              title: 'Sách lười',
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.light),
              darkTheme: buildTheme(Brightness.dark),
              themeMode: switch (state.settings.darkMode) {
                true => ThemeMode.dark,
                false => ThemeMode.light,
                null => ThemeMode.system,
              },
              home: const HomeShell(),
            ),
          ),
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('📖', style: TextStyle(fontSize: 52)),
            SizedBox(height: 18),
            Text('Sách lười', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            SizedBox(height: 22),
            SizedBox(width: 180, child: LinearProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 44, color: Colors.redAccent),
              const SizedBox(height: 14),
              const Text('Không khởi động được ứng dụng', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SelectableText('$error', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
