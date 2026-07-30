package com.sachnoi.sach_noi

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File

/// Ghi file xuất ra vào thư mục do chính người dùng chọn.
///
/// Đường này khác [XuatRaThuVien]: MediaStore chỉ đưa được file vào Music của hệ
/// thống, còn ở đây người dùng chỉ ra bất kỳ thư mục nào — kể cả thẻ nhớ ngoài
/// hay thư mục đồng bộ đám mây — rồi Android cấp cho app quyền ghi đúng vào cây
/// thư mục ấy (Storage Access Framework).
///
/// Quyền lấy được là loại "giữ lại được": máy khởi động lại vẫn còn, nên chọn một
/// lần là dùng mãi. Nhưng người dùng có thể rút lại trong phần Cài đặt của máy,
/// và gỡ app thì mất, nên trước khi ghi luôn phải hỏi [conQuyen].
///
/// Không dùng androidx.documentfile để khỏi thêm phụ thuộc — DocumentsContract
/// là API trần của chính nó, chỉ dài hơn vài dòng.
object ThuMucNguoiDung {

    /// Quyền ghi vào [cay] còn không.
    fun conQuyen(ctx: Context, cay: String): Boolean {
        val uri = Uri.parse(cay)
        return ctx.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isWritePermission
        }
    }

    /// Tên thư mục để hiện lên giao diện, ví dụ "Sách nói".
    fun ten(ctx: Context, cay: String): String {
        val uri = Uri.parse(cay)
        val doc = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
        ctx.contentResolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { con -> if (con.moveToFirst() && !con.isNull(0)) return con.getString(0) }
        // Provider nào không trả tên thì suy từ URI: ".../tree/primary%3AMusic"
        return uri.lastPathSegment?.substringAfterLast(':')?.ifEmpty { null } ?: "thư mục đã chọn"
    }

    /// Chép [nguon] vào [cay]/[thuMucCon]/[tenFile], xoá bản gốc, trả về đường
    /// dẫn để hiện cho người dùng.
    fun chep(ctx: Context, nguon: String, cay: String, thuMucCon: String, tenFile: String): String {
        val f = File(nguon)
        if (!f.exists()) throw IllegalStateException("không thấy file $nguon")
        if (!conQuyen(ctx, cay)) {
            throw IllegalStateException("mất quyền ghi vào thư mục đã chọn — hãy chọn lại")
        }

        val cr = ctx.contentResolver
        val cayUri = Uri.parse(cay)
        var thuMuc = DocumentsContract.buildDocumentUriUsingTree(cayUri, DocumentsContract.getTreeDocumentId(cayUri))
        if (thuMucCon.isNotEmpty()) {
            thuMuc = timHoacTaoThuMuc(ctx, cayUri, thuMuc, thuMucCon)
        }

        // Xuất lại cùng một chương thì thay bản cũ. Không xoá trước thì provider
        // tự thêm "(1)" vào tên và người dùng có hai file cạnh nhau.
        timCon(ctx, cayUri, thuMuc, tenFile)?.let {
            runCatching { DocumentsContract.deleteDocument(cr, it) }
        }

        val mime = when (f.extension.lowercase()) {
            "opus", "ogg" -> "audio/ogg"
            "m4a" -> "audio/mp4"
            "mp3" -> "audio/mpeg"
            else -> "audio/wav"
        }
        val dich = DocumentsContract.createDocument(cr, thuMuc, mime, tenFile)
            ?: throw IllegalStateException("không tạo được $tenFile trong thư mục đã chọn")

        try {
            cr.openOutputStream(dich)?.use { ra ->
                f.inputStream().use { vao -> vao.copyTo(ra, 1 shl 16) }
            } ?: throw IllegalStateException("không mở được chỗ ghi cho $tenFile")
        } catch (e: Exception) {
            runCatching { DocumentsContract.deleteDocument(cr, dich) }
            throw IllegalStateException("không chép được sang thư mục đã chọn: ${e.message}")
        }

        // Bản trong vùng riêng của app không cần giữ nữa.
        f.delete()

        // Provider có quyền đổi tên (trùng tên, ký tự lạ, tự thêm đuôi), nên lấy
        // lại tên thật chứ đừng đoán.
        val tenThat = docDisplayName(ctx, dich) ?: tenFile
        val goc = ten(ctx, cay)
        return if (thuMucCon.isEmpty()) "$goc/$tenThat" else "$goc/$thuMucCon/$tenThat"
    }

    private fun docDisplayName(ctx: Context, doc: Uri): String? {
        ctx.contentResolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { con -> if (con.moveToFirst() && !con.isNull(0)) return con.getString(0) }
        return null
    }

    /// URI của mục tên [ten] nằm trong [thuMuc], hoặc null nếu chưa có.
    private fun timCon(ctx: Context, cay: Uri, thuMuc: Uri, ten: String): Uri? {
        val con = DocumentsContract.buildChildDocumentsUriUsingTree(
            cay,
            DocumentsContract.getDocumentId(thuMuc),
        )
        ctx.contentResolver.query(
            con,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) == ten) {
                    return DocumentsContract.buildDocumentUriUsingTree(cay, c.getString(0))
                }
            }
        }
        return null
    }

    private fun timHoacTaoThuMuc(ctx: Context, cay: Uri, cha: Uri, ten: String): Uri {
        timCon(ctx, cay, cha, ten)?.let { return it }
        return DocumentsContract.createDocument(
            ctx.contentResolver,
            cha,
            DocumentsContract.Document.MIME_TYPE_DIR,
            ten,
        ) ?: throw IllegalStateException("không tạo được thư mục con '$ten'")
    }
}
