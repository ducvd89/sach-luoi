//! Chạy Laya bằng Rust trên vài câu hỏi cố định rồi in xác suất, để đối chiếu với Python.
//!
//!   LAYA_DIR=<thư mục laya.onnx> ORT_DYLIB_PATH=<onnxruntime.dll> cargo run --release --example thu_laya
use std::path::Path;
use std::time::Instant;

use sachnoi_vieneu::laya::{Laya, LuaChon, TrangThai};

fn lc(v: &[&str]) -> Vec<LuaChon> {
    v.iter().map(|n| LuaChon { nhan: n.to_string(), mo_ta: n.to_string() }).collect()
}

fn main() {
    let thu_muc = std::env::var("LAYA_DIR").expect("đặt LAYA_DIR");
    let t = Instant::now();
    let mut laya = Laya::mo(Path::new(&thu_muc), 4).expect("mở Laya");
    println!("mở trong {:.1}s", t.elapsed().as_secs_f32());
    let ins = "Which character speaks the `quote` in the `passage`?";
    let ca = [
        ("Fred đưa một tay ra kéo Harry đứng lên, hồi hộp hỏi:\n“Nó có ăn không?”\nHarry đứng thẳng lên:", "“Nó có ăn không?”", vec!["Harry", "Ron", "Fred", "George", "Hermione"]),
        ("“Harry, dậy đi cưng, tới giờ đi rồi.”\nHarry quơ tay chung quanh tìm cặp kính mắt của nó.", "“Harry, dậy đi cưng, tới giờ đi rồi.”", vec!["Bà Weasley", "Ông Weasley", "Harry", "Ron"]),
    ];
    for (doan, thoai, ds) in &ca {
        let t = Instant::now();
        let p = laya.chon(ins, &TrangThai { doan, thoai: Some(thoai) }, &lc(ds)).unwrap();
        println!("người nói {:?} -> {:?} ({:.2}s)", ds, p.iter().map(|v| (v * 10000.0).round() / 10000.0).collect::<Vec<_>>(), t.elapsed().as_secs_f32());
    }
    let gi = [("Bà Weasley", "Bà Weasley nhấc cái nồi bự chảng ra khỏi bếp lò, bưng đặt lên bàn và bắt đầu múc cháo vô mấy cái chén."), ("Lục Vô Song", "Lục Vô Song vọt tới đánh một quyền vào giữa mặt y, nàng tức giận quát lớn.")];
    for (ten, doan) in &gi {
        let ins = format!("Is the character {ten} in `passage` male or female?");
        let lua = vec![
            LuaChon { nhan: "nam".into(), mo_ta: "male (nam giới)".into() },
            LuaChon { nhan: "nữ".into(), mo_ta: "female (nữ giới)".into() },
        ];
        let p = laya.chon(&ins, &TrangThai { doan, thoai: None }, &lua).unwrap();
        println!("giới tính {ten} -> P(nam)={:.4} P(nữ)={:.4}", p[0], p[1]);
    }
}
