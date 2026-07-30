fn main() -> Result<(), String> {
    let a: Vec<String> = std::env::args().collect();
    let r = sachnoi_vieneu::enroll::enroll(
        std::path::Path::new(&a[1]), std::path::Path::new(&a[2]), std::path::Path::new(&a[3]))?;
    std::fs::write(&a[4], serde_json::to_string(&r.speaker_emb).unwrap()).map_err(|e| e.to_string())?;
    println!("da ghi {} chieu", r.speaker_emb.len());
    Ok(())
}
