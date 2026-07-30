package com.sachnoi.sach_noi

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/// Nén file WAV đã xuất bằng bộ mã hoá có sẵn trong Android.
///
/// Bản máy tính nén bằng libopus/libmp3lame liên kết vào thư viện Rust, nhưng
/// hai thư viện đó không biên dịch chéo sang Android được (libopus không có mã
/// nguồn kèm theo, libmp3lame đụng stdint.h của NDK). Không cần sửa chúng: hệ
/// điều hành đã có MediaCodec, không thêm một byte nào vào APK.
///
/// Khác biệt so với bản máy tính:
///   - Opus chỉ có từ API 29 (Android 10). Máy cũ hơn rơi về AAC.
///   - Android **không có** bộ mã hoá MP3. Xin MP3 thì trả về AAC, vì AAC nhỏ
///     hơn WAV khoảng 16 lần và mọi điện thoại đều đọc được.
/// Vì vậy hàm này trả về đường dẫn thật đã ghi, để bên Dart đặt đúng tên file.
object MaHoaAudio {

    /// Số mẫu đẩy vào bộ mã hoá mỗi lượt. Nhỏ thì tốn vòng lặp, lớn thì tốn RAM;
    /// 8192 mẫu (16 KB) là mức các ví dụ của Android hay dùng.
    private const val KHOI_MAU = 8192

    private const val CHO_US = 10_000L

    /// Nén [wavPath] rồi ghi cạnh [outBase] với đuôi do máy quyết định.
    /// Trả về đường dẫn đã ghi. Ném [IllegalStateException] kèm lý do nếu lỗi.
    fun nen(wavPath: String, outBase: String, dinhDang: String, bitrate: Int): String {
        val (pcm, sr) = docWav(File(wavPath))

        val muonOpus = dinhDang == "opus"
        val duocOpus = muonOpus && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        val mime = if (duocOpus) "audio/opus" else "audio/mp4a-latm"
        val duoi = if (duocOpus) "opus" else "m4a"
        val dinhDangMuxer = if (duocOpus) {
            MediaMuxer.OutputFormat.MUXER_OUTPUT_OGG
        } else {
            MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
        }

        // AAC ở 48 kbps cho giọng nói tương đương MP3 128k; xin MP3 128 (đơn vị
        // kbps) hay Opus 32000 (bit/s) đều quy về bit/s ở đây.
        val bps = if (bitrate < 1000) bitrate * 1000 else bitrate

        val ra = "$outBase.$duoi"
        val tam = File("$ra.tmp")
        // Ghi vào file tạm rồi đổi tên: tắt máy giữa lúc nén thì không để lại
        // file dở dang mà phần xuất file tưởng là đã xong.
        tam.parentFile?.mkdirs()

        val codec = MediaCodec.createEncoderByType(mime)
        val muxer = MediaMuxer(tam.absolutePath, dinhDangMuxer)
        try {
            val fmt = MediaFormat.createAudioFormat(mime, sr, 1)
            fmt.setInteger(MediaFormat.KEY_BIT_RATE, bps)
            if (!duocOpus) {
                fmt.setInteger(
                    MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC,
                )
            }
            fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, KHOI_MAU * 2)
            codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()

            chay(codec, muxer, pcm, sr)
        } finally {
            runCatching { codec.stop() }
            codec.release()
            runCatching { muxer.stop() }
            muxer.release()
        }

        val dich = File(ra)
        if (dich.exists()) dich.delete()
        if (!tam.renameTo(dich)) {
            tam.delete()
            throw IllegalStateException("không đổi tên được sang $ra")
        }
        return ra
    }

    /// Vòng đẩy PCM vào và hứng khung nén ra.
    private fun chay(codec: MediaCodec, muxer: MediaMuxer, pcm: ByteArray, sr: Int) {
        val info = MediaCodec.BufferInfo()
        var daDay = 0            // byte PCM đã đưa vào
        var hetDauVao = false
        var track = -1
        var muxerChay = false

        while (true) {
            if (!hetDauVao) {
                val i = codec.dequeueInputBuffer(CHO_US)
                if (i >= 0) {
                    val buf = codec.getInputBuffer(i)!!
                    buf.clear()
                    val con = pcm.size - daDay
                    val n = minOf(con, minOf(buf.capacity(), KHOI_MAU * 2))
                    if (n > 0) buf.put(pcm, daDay, n)

                    // Mốc thời gian tính theo số mẫu đã đẩy, không theo đồng hồ
                    // thật — nếu không thì file bị lệch thời lượng.
                    val us = daDay.toLong() / 2 * 1_000_000L / sr
                    daDay += n
                    hetDauVao = daDay >= pcm.size
                    val co = if (hetDauVao) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
                    codec.queueInputBuffer(i, 0, n, us, co)
                }
            }

            val o = codec.dequeueOutputBuffer(info, CHO_US)
            when {
                o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (!muxerChay) {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        muxerChay = true
                    }
                }
                o >= 0 -> {
                    val buf = codec.getOutputBuffer(o)!!
                    // Khung cấu hình của codec do muxer tự lo, không ghi tay.
                    val laCauHinh = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (!laCauHinh && info.size > 0 && muxerChay) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        muxer.writeSampleData(track, buf, info)
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
                o == MediaCodec.INFO_TRY_AGAIN_LATER && hetDauVao && !muxerChay -> {
                    throw IllegalStateException("bộ mã hoá không trả về khung nào")
                }
            }
        }
    }

    /// Đọc WAV 16-bit mono do chính ứng dụng ghi ra. Trả về (PCM, tần số).
    private fun docWav(f: File): Pair<ByteArray, Int> {
        val byte = f.readBytes()
        if (byte.size < 44 || String(byte, 0, 4) != "RIFF" || String(byte, 8, 4) != "WAVE") {
            throw IllegalStateException("không phải file WAV: ${f.name}")
        }
        var sr = 0
        var i = 12
        while (i + 8 <= byte.size) {
            val ten = String(byte, i, 4)
            val co = ByteBuffer.wrap(byte, i + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            val than = i + 8
            when {
                ten == "fmt " && than + 16 <= byte.size -> {
                    sr = ByteBuffer.wrap(byte, than + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
                }
                ten == "data" -> {
                    if (sr == 0) throw IllegalStateException("WAV thiếu chunk fmt")
                    val het = minOf(than + co, byte.size)
                    return Pair(byte.copyOfRange(than, het), sr)
                }
            }
            // Chunk luôn căn theo số chẵn byte.
            i = than + co + (co and 1)
        }
        throw IllegalStateException("WAV không có chunk data")
    }
}
