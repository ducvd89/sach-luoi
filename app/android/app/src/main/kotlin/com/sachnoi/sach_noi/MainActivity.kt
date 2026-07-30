package com.sachnoi.sach_noi

import com.ryanheise.audioservice.AudioServiceActivity

/// Kế thừa AudioServiceActivity thay vì FlutterActivity: nút trên tai nghe và
/// lệnh từ màn hình khoá cần đánh thức đúng activity này, nếu không Android sẽ
/// mở một bản sao mới và mất trạng thái đang nghe.
class MainActivity : AudioServiceActivity()
