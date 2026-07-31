//! BaoGUI — Vidya / egui OpenBao (Vault-compatible KV) client.

mod api;
mod app;

use app::BaoGuiApp;

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_inner_size([960.0, 640.0])
            .with_min_inner_size([480.0, 400.0])
            .with_title("BaoGUI — OpenBao"),
        ..Default::default()
    };
    eframe::run_native(
        "baogui",
        options,
        Box::new(|cc| Ok(Box::new(BaoGuiApp::new(cc)))),
    )
}
