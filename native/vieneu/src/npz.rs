//! Đọc file .npz của numpy — chỉ đủ dùng cho bộ trọng số của VieNeu.
//!
//! .npz là một file zip chứa nhiều file .npy. Mỗi .npy có phần đầu ghi kiểu dữ
//! liệu và hình dạng, sau đó là mảng số thô. Ta chỉ cần float32 dạng C-order nên
//! phần đọc rất ngắn — kéo cả một thư viện numpy vào thì không đáng.

use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::path::Path;

pub struct Array {
    pub shape: Vec<usize>,
    pub data: Vec<f32>,
}

impl Array {
    pub fn len(&self) -> usize {
        self.data.len()
    }

    /// Xem mảng như bảng hai chiều: lấy hàng thứ [row].
    pub fn row(&self, row: usize) -> &[f32] {
        let width = *self.shape.last().unwrap_or(&1);
        &self.data[row * width..(row + 1) * width]
    }
}

/// Bộ trọng số đã đọc, tra theo tên.
pub type Npz = HashMap<String, Array>;

pub fn read_npz(path: &Path) -> Result<Npz, String> {
    let file = File::open(path).map_err(|e| format!("không mở được {}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("{} không phải .npz: {e}", path.display()))?;

    let mut out = HashMap::new();
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| format!("lỗi đọc mục {i}: {e}"))?;
        let name = entry.name().trim_end_matches(".npy").to_string();
        let mut raw = Vec::with_capacity(entry.size() as usize);
        entry.read_to_end(&mut raw).map_err(|e| format!("lỗi đọc {name}: {e}"))?;
        out.insert(name.clone(), parse_npy(&raw).map_err(|e| format!("{name}: {e}"))?);
    }
    Ok(out)
}

/// Đọc một mảng .npy float32 (hoặc float64/int, tự đổi sang f32).
fn parse_npy(raw: &[u8]) -> Result<Array, String> {
    if raw.len() < 10 || &raw[0..6] != b"\x93NUMPY" {
        return Err("thiếu chữ ký NUMPY".into());
    }
    let major = raw[6];
    // Bản 1.x ghi độ dài phần đầu bằng 2 byte, bản 2.x trở lên dùng 4 byte.
    let (header_len, body_at) = if major == 1 {
        (u16::from_le_bytes([raw[8], raw[9]]) as usize, 10)
    } else {
        (u32::from_le_bytes([raw[8], raw[9], raw[10], raw[11]]) as usize, 12)
    };
    let header = std::str::from_utf8(&raw[body_at..body_at + header_len])
        .map_err(|_| "phần đầu không phải UTF-8")?;
    let body = &raw[body_at + header_len..];

    if header.contains("'fortran_order': True") {
        return Err("mảng theo thứ tự Fortran — không hỗ trợ".into());
    }

    let shape = parse_shape(header)?;
    let count: usize = shape.iter().product::<usize>().max(if shape.is_empty() { 1 } else { 0 });

    let descr = field(header, "'descr': '").ok_or("thiếu descr")?;
    let data = match descr.as_str() {
        "<f4" => bytes_to_f32(body, count),
        "<f8" => body
            .chunks_exact(8)
            .take(count)
            .map(|b| f64::from_le_bytes(b.try_into().unwrap()) as f32)
            .collect(),
        "<i8" => body
            .chunks_exact(8)
            .take(count)
            .map(|b| i64::from_le_bytes(b.try_into().unwrap()) as f32)
            .collect(),
        "<i4" => body
            .chunks_exact(4)
            .take(count)
            .map(|b| i32::from_le_bytes(b.try_into().unwrap()) as f32)
            .collect(),
        other => return Err(format!("kiểu dữ liệu chưa hỗ trợ: {other}")),
    };

    if data.len() != count {
        return Err(format!("thiếu dữ liệu: cần {count}, đọc được {}", data.len()));
    }
    Ok(Array { shape, data })
}

fn bytes_to_f32(body: &[u8], count: usize) -> Vec<f32> {
    body.chunks_exact(4)
        .take(count)
        .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
        .collect()
}

fn field(header: &str, key: &str) -> Option<String> {
    let start = header.find(key)? + key.len();
    let rest = &header[start..];
    let end = rest.find('\'')?;
    Some(rest[..end].to_string())
}

fn parse_shape(header: &str) -> Result<Vec<usize>, String> {
    let key = "'shape': (";
    let start = header.find(key).ok_or("thiếu shape")? + key.len();
    let rest = &header[start..];
    let end = rest.find(')').ok_or("shape không đóng ngoặc")?;
    Ok(rest[..end]
        .split(',')
        .filter_map(|s| s.trim().parse::<usize>().ok())
        .collect())
}
