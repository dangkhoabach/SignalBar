const SIZE: u32 = 32;

// Apple system colors (System green/yellow/red/gray).
pub const COLOR_OK: [u8; 3] = [52, 199, 89];
pub const COLOR_WARNING: [u8; 3] = [255, 204, 0];
pub const COLOR_DOWN: [u8; 3] = [255, 59, 48];
pub const COLOR_EMPTY: [u8; 3] = [142, 142, 147];

/// Renders a small filled, lightly anti-aliased circle as an RGBA buffer,
/// used as the menu bar tray icon so status is shown as a colored dot
/// instead of a color emoji title.
pub fn dot_icon(color: [u8; 3]) -> tauri::image::Image<'static> {
    let radius = (SIZE as f32 / 2.0) - 3.0;
    let center = SIZE as f32 / 2.0;
    let mut rgba = vec![0u8; (SIZE * SIZE * 4) as usize];

    for y in 0..SIZE {
        for x in 0..SIZE {
            let dx = x as f32 + 0.5 - center;
            let dy = y as f32 + 0.5 - center;
            let dist = (dx * dx + dy * dy).sqrt();
            let idx = ((y * SIZE + x) * 4) as usize;
            let alpha = if dist <= radius {
                255
            } else if dist <= radius + 1.0 {
                ((radius + 1.0 - dist).clamp(0.0, 1.0) * 255.0) as u8
            } else {
                0
            };
            rgba[idx] = color[0];
            rgba[idx + 1] = color[1];
            rgba[idx + 2] = color[2];
            rgba[idx + 3] = alpha;
        }
    }

    tauri::image::Image::new_owned(rgba, SIZE, SIZE)
}
