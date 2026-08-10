package com.sachnoi.sach_noi

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/// Kế thừa AudioServiceActivity thay vì FlutterActivity: nút trên tai nghe và
/// lệnh từ màn hình khoá cần đánh thức đúng activity này, nếu không Android sẽ
/// mở một bản sao mới và mất trạng thái đang nghe.
class MainActivity : AudioServiceActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        xinQuyenThongBao()
    }

    /// Nối cầu để Dart nhờ Android nén file âm thanh và cất file xuất ra.
    ///
    /// Bản máy tính nén bằng thư viện Rust qua FFI; ở đây dùng MediaCodec của hệ
    /// điều hành nên không phải nhồi thêm thư viện nào vào APK.
    /// Nơi phát tiến trình nén — Opus/AAC nhanh hơn hẳn đọc file nên chỉ báo lúc
    /// đổi từ 1% trở lên (xem [MaHoaAudio]), khỏi dội tin nhắn qua kênh.
    private var tienDoNenSink: EventChannel.EventSink? = null

    /// Nơi đẩy trạng thái tay cầm sang Dart.
    ///
    /// Android KHÔNG có XInput — đó là API riêng của Windows. Cùng cái tay cầm
    /// Xbox ấy nhưng ở đây hệ điều hành đưa vào bằng KeyEvent (nút, phím mũi
    /// tên) và MotionEvent (cần gạt), nên phải bắt ở tầng Activity rồi chuyển
    /// tiếp. Phần hiểu và xử lý nằm bên Dart, dùng chung với bản Windows.
    private var tayCamSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        EventChannel(engine.dartExecutor.binaryMessenger, KENH_TAY_CAM)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    tayCamSink = sink
                }
                override fun onCancel(args: Any?) {
                    tayCamSink = null
                }
            })
        EventChannel(engine.dartExecutor.binaryMessenger, KENH_TIEN_DO_NEN)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    tienDoNenSink = sink
                }
                override fun onCancel(args: Any?) {
                    tienDoNenSink = null
                }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, KENH_MA_HOA)
            .setMethodCallHandler { goi, tra ->
                // Mở màn hình chọn thư mục phải ở luồng giao diện, và kết quả về
                // sau ở onActivityResult chứ không trả ngay tại đây được.
                if (goi.method == "chonThuMuc") {
                    moManHinhChonThuMuc(tra)
                    return@setMethodCallHandler
                }
                if (goi.method !in VIEC_NEN) {
                    tra.notImplemented()
                    return@setMethodCallHandler
                }
                // Nén một file 30 phút mất vài giây; chạy trên luồng chính thì
                // giao diện đứng, nên đẩy sang luồng nền rồi trả kết quả về.
                Thread {
                    val ketQua = runCatching { lamViec(goi.method, goi) }
                    runOnUiThread {
                        ketQua.fold(
                            onSuccess = { tra.success(it) },
                            onFailure = { tra.error("ma_hoa", it.message ?: "$it", null) },
                        )
                    }
                }.start()
            }
    }

    private fun lamViec(viec: String, goi: io.flutter.plugin.common.MethodCall): Any = when (viec) {
        "nen" -> {
            // requestId rỗng nghĩa là bên Dart không cần nghe tiến trình — đỡ
            // phải đẩy sự kiện lên luồng chính cho không ai nhận.
            val requestId = goi.argument<String>("requestId") ?: ""
            MaHoaAudio.nen(
                goi.argument<String>("wavPath")!!,
                goi.argument<String>("outBase")!!,
                goi.argument<String>("dinhDang")!!,
                goi.argument<Int>("bitrate")!!,
            ) { phan ->
                if (requestId.isNotEmpty()) {
                    runOnUiThread { tienDoNenSink?.success(mapOf("requestId" to requestId, "phan" to phan)) }
                }
            }
        }
        "dangKy" -> XuatRaThuVien.dangKy(
            applicationContext,
            goi.argument<String>("nguon")!!,
            goi.argument<String>("thuMucCon")!!,
            goi.argument<String>("tenFile")!!,
        )
        "chepVaoThuMuc" -> ThuMucNguoiDung.chep(
            applicationContext,
            goi.argument<String>("nguon")!!,
            goi.argument<String>("cay")!!,
            goi.argument<String>("thuMucCon") ?: "",
            goi.argument<String>("tenFile")!!,
        )
        "tenThuMuc" -> ThuMucNguoiDung.ten(applicationContext, goi.argument<String>("cay")!!)
        "conQuyenThuMuc" -> ThuMucNguoiDung.conQuyen(applicationContext, goi.argument<String>("cay")!!)
        else -> throw IllegalStateException("không có việc '$viec'")
    }

    /// Mở màn hình chọn thư mục của hệ thống.
    private fun moManHinhChonThuMuc(tra: MethodChannel.Result) {
        if (choThuMuc != null) {
            tra.error("dang_cho", "đang có một lượt chọn thư mục chưa xong", null)
            return
        }
        val y = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        try {
            choThuMuc = tra
            startActivityForResult(y, MA_CHON_THU_MUC)
        } catch (e: Exception) {
            choThuMuc = null
            tra.error("khong_mo_duoc", "máy không có trình chọn thư mục: ${e.message}", null)
        }
    }

    override fun onActivityResult(ma: Int, ketQua: Int, du: Intent?) {
        if (ma != MA_CHON_THU_MUC) {
            super.onActivityResult(ma, ketQua, du)
            return
        }
        val tra = choThuMuc
        choThuMuc = null
        val cay = du?.data
        if (ketQua != RESULT_OK || cay == null) {
            tra?.success(null) // người dùng bấm quay lại
            return
        }
        // Không giữ lại thì quyền mất ngay khi thoát app, lần xuất sau ghi là lỗi.
        try {
            contentResolver.takePersistableUriPermission(
                cay,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            tra?.error("khong_giu_duoc_quyen", "không giữ được quyền ghi: ${e.message}", null)
            return
        }
        tra?.success(cay.toString())
    }

    // -- tay cầm chơi game ---------------------------------------------------

    /// Nút và phím mũi tên của tay cầm.
    ///
    /// Nuốt luôn (trả về true) chứ không để lọt xuống Flutter: phím mũi tên của
    /// tay cầm vào tới Flutter thì thành phím mũi tên bàn phím, mà màn hình
    /// nghe đã bắt phím ấy để tua ±15 giây — bấm sang phải để chọn nút bên cạnh
    /// lại hoá ra tua bài đang nghe.
    ///
    /// Bàn phím thật thì không đụng tới: điều kiện lọc theo nguồn thiết bị.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (laTayCam(event.source)) {
            val ma = when (event.keyCode) {
                KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_DPAD_CENTER -> "chon"
                KeyEvent.KEYCODE_BUTTON_B -> "quayLai"
                KeyEvent.KEYCODE_BUTTON_Y -> "phatDung"
                KeyEvent.KEYCODE_BUTTON_X -> "moChuong"
                KeyEvent.KEYCODE_DPAD_UP -> "len"
                KeyEvent.KEYCODE_DPAD_DOWN -> "xuong"
                KeyEvent.KEYCODE_DPAD_LEFT -> "trai"
                KeyEvent.KEYCODE_DPAD_RIGHT -> "phai"
                // L1/L2 và R1/R2 cùng làm một việc: chuyển tab qua lại.
                KeyEvent.KEYCODE_BUTTON_L1, KeyEvent.KEYCODE_BUTTON_L2 -> "vaiTrai"
                KeyEvent.KEYCODE_BUTTON_R1, KeyEvent.KEYCODE_BUTTON_R2 -> "vaiPhai"
                else -> null
            }
            if (ma != null) {
                // Chỉ báo lúc bấm xuống và lúc nhả; lượt tự lặp của hệ điều
                // hành thì bỏ qua vì bên Dart đã có nhịp lặp riêng. Nhưng vẫn
                // NUỐT hết, kể cả lượt lặp — lọt xuống Flutter một cái là màn
                // hình nghe hiểu thành phím mũi tên rồi tua bài đang nghe.
                if (event.repeatCount == 0 &&
                    (event.action == KeyEvent.ACTION_DOWN || event.action == KeyEvent.ACTION_UP)
                ) {
                    guiTayCam(mapOf(
                        "loai" to "nut",
                        "ma" to ma,
                        "xuong" to (event.action == KeyEvent.ACTION_DOWN),
                    ))
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /// Cần gạt trái. Tay cầm gửi trục liên tục kiểu này chứ không phải phím.
    ///
    /// Bắt ở `dispatch` chứ không ở `on`: `onGenericMotionEvent` chỉ được gọi
    /// khi cả cây view đã bỏ qua sự kiện, mà FlutterView có nhận sự kiện dạng
    /// này (nó dùng cho chuột và bánh xe cuộn) nên không chắc còn dư lại gì.
    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        val laCanGat = event.source and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK
        if (laCanGat && event.action == MotionEvent.ACTION_MOVE) {
            // Vài tay cầm báo phím mũi tên dưới dạng "mũ" (hat) trên trục riêng
            // thay vì thành phím — gộp cả hai vào chung một cặp trục.
            val x = truc(event, MotionEvent.AXIS_X) + truc(event, MotionEvent.AXIS_HAT_X)
            val y = truc(event, MotionEvent.AXIS_Y) + truc(event, MotionEvent.AXIS_HAT_Y)
            // Cần phải: Android đặt nó ở Z (ngang) và RZ (dọc), không phải RX/RY.
            // Cò cũng có máy báo bằng trục thay vì bằng phím — lấy cả hai đường,
            // chỗ nào không có thì giá trị là 0 nên không ảnh hưởng gì.
            val co = maxOf(
                truc(event, MotionEvent.AXIS_LTRIGGER),
                truc(event, MotionEvent.AXIS_BRAKE),
            )
            val coPhai = maxOf(
                truc(event, MotionEvent.AXIS_RTRIGGER),
                truc(event, MotionEvent.AXIS_GAS),
            )
            guiTayCam(mapOf(
                "loai" to "can",
                "x" to x.coerceIn(-1f, 1f).toDouble(),
                "y" to y.coerceIn(-1f, 1f).toDouble(),
                "xPhai" to truc(event, MotionEvent.AXIS_Z).coerceIn(-1f, 1f).toDouble(),
                "yPhai" to truc(event, MotionEvent.AXIS_RZ).coerceIn(-1f, 1f).toDouble(),
                "coTrai" to (co > NGUONG_CO),
                "coPhai" to (coPhai > NGUONG_CO),
            ))
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }

    /// Giá trị một trục, đã cắt vùng chết do chính thiết bị khai báo.
    ///
    /// Cần gạt không bao giờ về đúng 0; mỗi tay cầm lệch một kiểu nên lấy con
    /// số của thiết bị thay vì đoán một ngưỡng chung.
    private fun truc(event: MotionEvent, truc: Int): Float {
        val gia = event.getAxisValue(truc)
        val chet = event.device?.getMotionRange(truc, event.source)?.flat ?: 0f
        return if (kotlin.math.abs(gia) <= chet) 0f else gia
    }

    private fun laTayCam(nguon: Int): Boolean =
        nguon and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
            nguon and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK

    private fun guiTayCam(tin: Map<String, Any>) {
        val sink = tayCamSink ?: return
        runOnUiThread { sink.success(tin) }
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

    /// Chỗ giữ lời hứa trả kết quả trong lúc màn hình chọn thư mục đang mở.
    private var choThuMuc: MethodChannel.Result? = null

    private companion object {
        const val MA_XIN_THONG_BAO = 1001
        const val MA_CHON_THU_MUC = 1002
        const val KENH_MA_HOA = "sachnoi/ma_hoa"
        const val KENH_TIEN_DO_NEN = "sachnoi/ma_hoa_tien_do"
        const val KENH_TAY_CAM = "sachnoi/tay_cam"

        /// Cò bấm sâu hơn mức này (thang 0-1) thì tính là đã bấm.
        const val NGUONG_CO = 0.12f
        val VIEC_NEN = setOf("nen", "dangKy", "chepVaoThuMuc", "tenThuMuc", "conQuyenThuMuc")
    }
}
