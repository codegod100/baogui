//! Android NativeActivity entry for BaoGUI (shared UI from the parent crate).

use baogui::app::BaoGuiApp;

const APP_ID: &str = "org.openbao.baogui";

#[no_mangle]
fn android_main(android_app: winit::platform::android::activity::AndroidApp) {
    android_logger::init_once(
        android_logger::Config::default().with_max_level(log::LevelFilter::Info),
    );
    log::info!("baogui android_main start");
    let mut options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("BaoGUI — OpenBao")
            .with_app_id(APP_ID),
        ..Default::default()
    };
    options.android_app = Some(android_app);
    match eframe::run_native(
        APP_ID,
        options,
        Box::new(|cc| Ok(Box::new(BaoGuiApp::new(cc)))),
    ) {
        Ok(()) => log::info!("baogui run_native returned Ok"),
        Err(e) => log::error!("baogui run_native error: {e}"),
    }
    log::info!("baogui android_main end");
}
