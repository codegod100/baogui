//! BaoGUI library — shared by desktop binary and Android APK.

pub mod api;
pub mod app;
#[cfg(not(target_os = "android"))]
pub mod oidc;
