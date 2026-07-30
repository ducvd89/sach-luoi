package com.sachnoi.sach_noi

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/// Đưa file đã xuất vào thư viện nhạc của hệ thống.
///
/// Vì sao phải qua đây thay vì ghi thẳng: từ Android 10, app không ghi được vào
/// Download hay Music bằng File API nữa (scoped storage), khai
/// WRITE_EXTERNAL_STORAGE cũng vô ích. Còn thư mục riêng của app trên bộ nhớ
/// ngoài (Android/data/...) thì ghi được nhưng từ Android 11 lại bị chặn truy
/// cập cả từ trình quản lý file lẫn qua cáp USB — tức là ghi vào đó thì người
/// dùng không lấy file ra được.
///
/// MediaStore là đường duy nhất vừa không cần quyền vừa cho ra file người dùng
/// thấy và copy được: nó nằm trong Music/Sách lười/<tên sách>, hiện ở ứng dụng
/// Files, ở các app nghe nhạc, và khi cắm máy vào máy tính.
object XuatRaThuVien {

    /// Chép [nguon] vào Music/[thuMucCon]/[tenFile] rồi trả về đường dẫn người
    /// dùng thấy. Ném [IllegalStateException] kèm lý do nếu lỗi.
    fun dangKy(ctx: Context, nguon: String, thuMucCon: String, tenFile: String): String {
        val f = File(nguon)
        if (!f.exists()) throw IllegalStateException("không thấy file $nguon")
        val mime = when (f.extension.lowercase()) {
            "opus", "ogg" -> "audio/ogg"
            "m4a" -> "audio/mp4"
            "mp3" -> "audio/mpeg"
            else -> "audio/wav"
        }
        val duongDanHienThi = "Music/$thuMucCon/$tenFile"

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Trước Android 10 thì ghi thẳng vẫn được, chỉ cần quyền đã khai
            // trong manifest với maxSdkVersion=28.
            val dich = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
                "$thuMucCon/$tenFile",
            )
            dich.parentFile?.mkdirs()
            f.copyTo(dich, overwrite = true)
            f.delete()
            return dich.absolutePath
        }

        val bang = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val cr = ctx.contentResolver

        // Xuất lại cùng một chương thì phải thay bản cũ, không để hai file trùng
        // tên nằm cạnh nhau (MediaStore tự thêm "(1)" vào tên).
        cr.delete(
            bang,
            "${MediaStore.Audio.Media.RELATIVE_PATH}=? AND ${MediaStore.Audio.Media.DISPLAY_NAME}=?",
            arrayOf("Music/$thuMucCon/", tenFile),
        )

        val gia = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, tenFile)
            put(MediaStore.Audio.Media.MIME_TYPE, mime)
            put(MediaStore.Audio.Media.RELATIVE_PATH, "Music/$thuMucCon")
            put(MediaStore.Audio.Media.IS_MUSIC, 1)
            // Đánh dấu đang ghi: máy khác chưa thấy file nửa vời.
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }
        val uri = cr.insert(bang, gia)
            ?: throw IllegalStateException("MediaStore không nhận $duongDanHienThi")

        try {
            cr.openOutputStream(uri)?.use { ra ->
                f.inputStream().use { vao -> vao.copyTo(ra, 1 shl 16) }
            } ?: throw IllegalStateException("không mở được chỗ ghi cho $duongDanHienThi")
        } catch (e: Exception) {
            cr.delete(uri, null, null)
            throw IllegalStateException("không chép được sang $duongDanHienThi: ${e.message}")
        }

        cr.update(uri, ContentValues().apply {
            put(MediaStore.Audio.Media.IS_PENDING, 0)
        }, null, null)

        // Bản trong vùng riêng của app không cần giữ nữa.
        f.delete()
        return duongDanHienThi
    }
}
