use std::collections::HashMap;

fn crate_load(path: &Path) -> Result<HashMap<String, Voice>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("{e}"))?;
    let presets = json.get("presets").and_then(|v| v.as_object()).ok_or("thiếu presets")?;
    let mut ra = HashMap::new();
    for (ten, v) in presets {
        let codes = v.get("ref_codes").and_then(|x| x.as_array()).map(|h| h.iter()
            .flat_map(|r| r.as_array().map(|c| c.iter().filter_map(|x| x.as_i64()).collect::<Vec<_>>()).unwrap_or_default())
            .collect::<Vec<i64>>()).unwrap_or_default();
        ra.insert(ten.clone(), Voice {
            speaker_emb: v.get("speaker_emb").and_then(|x| x.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect()).unwrap_or_default(),
            ref_codes: codes,
            ref_frames: v.get("ref_frames").and_then(|x| x.as_u64()).unwrap_or(0) as usize,
            style: v.get("style").and_then(|x| x.as_str()).unwrap_or("doc_truyen").to_string(),
        });
    }
    Ok(ra)
}
