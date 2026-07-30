fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (wav, rate) = sachnoi_vieneu::enroll::read_wav(std::path::Path::new(&a[1])).unwrap();
    let cut = (8.0 * rate as f32) as usize;
    let wav = &wav[..cut.min(wav.len())];
    let at16 = sachnoi_vieneu::fbank::resample_to_16k(wav, rate);
    let f = sachnoi_vieneu::fbank::speaker_fbank(&at16);
    let frames = f.len() / 80;
    let mean = f.iter().sum::<f32>() / f.len() as f32;
    let std = (f.iter().map(|v| (v-mean)*(v-mean)).sum::<f32>() / f.len() as f32).sqrt();
    println!("RUST    frames={frames} mean={mean:.6} std={std:.6}");
    for i in [0usize, 400] {
        println!("  frame {i}: {:?}", f[i*80..i*80+6].iter().map(|v| (v*1000.0).round()/1000.0).collect::<Vec<_>>());
    }
}
