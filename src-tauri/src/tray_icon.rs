const SIZE: u32 = 32;

/// Renders a simple monochrome "activity pulse" glyph (black shape with
/// alpha transparency) suitable for use as a macOS template tray icon —
/// the OS re-tints it automatically for the light/dark menu bar, the same
/// way built-in system icons behave.
pub fn pulse_glyph() -> tauri::image::Image<'static> {
    const SEGMENTS: [(f32, f32, f32, f32); 5] = [
        (3.0, 16.0, 10.0, 16.0),
        (10.0, 16.0, 14.0, 6.0),
        (14.0, 6.0, 18.0, 26.0),
        (18.0, 26.0, 22.0, 16.0),
        (22.0, 16.0, 29.0, 16.0),
    ];
    const HALF_WIDTH: f32 = 1.3;

    let mut rgba = vec![0u8; (SIZE * SIZE * 4) as usize];

    for y in 0..SIZE {
        for x in 0..SIZE {
            let px = x as f32 + 0.5;
            let py = y as f32 + 0.5;
            let dist = SEGMENTS
                .iter()
                .map(|&(x1, y1, x2, y2)| dist_to_segment(px, py, x1, y1, x2, y2))
                .fold(f32::MAX, f32::min);

            let idx = ((y * SIZE + x) * 4) as usize;
            let alpha = if dist <= HALF_WIDTH {
                255
            } else if dist <= HALF_WIDTH + 1.0 {
                ((HALF_WIDTH + 1.0 - dist).clamp(0.0, 1.0) * 255.0) as u8
            } else {
                0
            };
            // Template images are conventionally solid black; the OS controls
            // the actual on-screen color based on menu bar appearance.
            rgba[idx + 3] = alpha;
        }
    }

    tauri::image::Image::new_owned(rgba, SIZE, SIZE)
}

fn dist_to_segment(px: f32, py: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    let (dx, dy) = (x2 - x1, y2 - y1);
    let len_sq = dx * dx + dy * dy;
    let t = if len_sq == 0.0 {
        0.0
    } else {
        (((px - x1) * dx + (py - y1) * dy) / len_sq).clamp(0.0, 1.0)
    };
    let (cx, cy) = (x1 + t * dx, y1 + t * dy);
    ((px - cx).powi(2) + (py - cy).powi(2)).sqrt()
}
