//! BaoGUI — Vidya / egui OpenBao (Vault-compatible KV) client.

use baogui::app::BaoGuiApp;

/// FreeDesktop app id — must match `org.openbao.baogui.desktop` (basename).
/// Wayland compositors use this to pick the icon / group the window.
const APP_ID: &str = "org.openbao.baogui";

fn load_icon() -> egui::IconData {
    // 128px is enough for title bars / docks; master 512 is heavy to decode.
    const PNG: &[u8] = include_bytes!("../data/share/icons/hicolor/128x128/apps/org.openbao.baogui.png");
    eframe::icon_data::from_png_bytes(PNG).unwrap_or_else(|e| {
        eprintln!("baogui: failed to load window icon: {e}");
        egui::IconData::default()
    })
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_inner_size([960.0, 640.0])
            .with_min_inner_size([480.0, 400.0])
            .with_title("BaoGUI — OpenBao")
            .with_app_id(APP_ID)
            .with_icon(load_icon()),
        ..Default::default()
    };
    eframe::run_native(
        APP_ID,
        options,
        Box::new(|cc| Ok(Box::new(BaoGuiApp::new(cc)))),
    )
}
