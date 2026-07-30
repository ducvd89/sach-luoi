package com.sachnoi.sach_noi

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Kế thừa AudioServiceActivity thay vì FlutterActivity: nút trên tai nghe và
/// lệnh từ màn hình khoá cần đánh thức đúng activity này, nếu không Android sẽ
/// mở một bản sao mới và mất trạng thái đang nghe.
class MainActivity : AudioServiceActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        xinQuyenThongBao()
    }

    /// Nối cầu để Dart nhờ Android nén file âm thanh.
    ///
    /// Bản máy tính nén bằng thư viện Rust qua FFI; ở đây dùng MediaCodec của hệ
    /// điều hành nên không phải nhồi thêm thư viện nào vào APK.
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, KENH_MA_HOA)
            .setMethodCallHandler { goi, tra ->
                if (goi.method != "nen") {
                    tra.notImplemented()
                    return@setMethodCallHandler
                }
                // Nén một file 30 phút mất vài giây; chạy trên luồng chính thì
                // giao diện đứng, nên đẩy sang luồng nền rồi trả kết quả về.
                Thread {
                    val ketQua = runCatching {
                        MaHoaAudio.nen(
                            goi.argument<String>("wavPath")!!,
                            goi.argument<String>("outBase")!!,
                            goi.argument<String>("dinhDang")!!,
                            goi.argument<Int>("bitrate")!!,
                        )
                    }
                    runOnUiThread {
                        ketQua.fold(
                            onSuccess = { tra.success(it) },
                            onFailure = { tra.error("ma_hoa", it.message ?: "$it", null) },
                        )
                    }
                }.start()
            }
    }

    /// Xin quyền hiện thông báo.
    ///
    /// Từ Android 13, khai POST_NOTIFICATIONS trong manifest chỉ là xin phép
    /// được hỏi — chưa hỏi thì hệ thống đặt app ở mức importance=NONE và lặng lẽ
    /// bỏ mọi thông báo. Với ứng dụng sách nói thì mất luôn thẻ "Đang phát":
    /// phiên media vẫn sống nên nút trên tai nghe chạy, nhưng khu thông báo,
    /// quick settings và màn hình khoá đều trống trơn.
    ///
    /// Hỏi ngay lúc mở app chứ không đợi tới lúc bấm phát: hộp thoại bật lên
    /// giữa lúc đang chọn sách để nghe thì phiền hơn là hỏi một lần lúc đầu.
    private fun xinQuyenThongBao() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val quyen = Manifest.permission.POST_NOTIFICATIONS
        // Đã cấp rồi thì thôi; đã từ chối hai lần thì Android tự bỏ qua lời gọi
        // này, không có hộp thoại nào bật lên quấy người dùng nữa.
        if (checkSelfPermission(quyen) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(quyen), MA_XIN_THONG_BAO)
    }

    private companion object {
        const val MA_XIN_THONG_BAO = 1001
        const val KENH_MA_HOA = "sachnoi/ma_hoa"
    }
}
