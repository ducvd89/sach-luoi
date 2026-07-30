/// Đưa AppState xuống toàn bộ cây widget mà không cần thư viện ngoài.
library;

import 'package:flutter/widgets.dart';

import '../state/app_state.dart';

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'Không tìm thấy AppScope phía trên widget này');
    return scope!.notifier!;
  }

  /// Lấy state mà không đăng ký lắng nghe thay đổi (dùng trong hàm xử lý sự kiện).
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'Không tìm thấy AppScope phía trên widget này');
    return scope!.notifier!;
  }
}
