//! BaoGUI window: connect form + secret browser / editor.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use eframe::egui::{
    self, Align, Color32, Key, Layout, RichText, ScrollArea, Sense, TextEdit, Vec2,
};
use vidya::{
    apply, body, button, destructive_button, dim_label, primary_button, text_field_multiline,
    text_field_singleline, title, title_2, Mode, Theme,
};

use crate::api::{Client, SecretData};

const TOAST_SECS: u64 = 3;
const SIDEBAR_W: f32 = 260.0;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Screen {
    Connect,
    Main,
}

#[derive(Clone)]
struct KvRow {
    key: String,
    value: String,
}

struct NewDialog {
    path: String,
    body: String,
}

pub struct BaoGuiApp {
    mode: Mode,
    screen: Screen,

    // Connect form
    address: String,
    token: String,
    connect_status: String,

    // Session
    client: Option<Client>,
    mount: String,
    folder: String,
    current_path: String,

    // Sidebar
    list_keys: Vec<String>,

    // Detail
    show_detail: bool,
    path_display: String,
    meta: String,
    kv_rows: Vec<KvRow>,
    reveal_values: bool,

    // Dialogs / feedback
    new_dialog: Option<NewDialog>,
    delete_confirm: bool,
    toast: Option<(String, Instant)>,
}

impl BaoGuiApp {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let theme = Theme::dark();
        apply(&cc.egui_ctx, &theme);

        let address = std::env::var("BAO_ADDR")
            .or_else(|_| std::env::var("VAULT_ADDR"))
            .unwrap_or_else(|_| "http://127.0.0.1:8200".into());

        let token = std::env::var("BAO_TOKEN")
            .or_else(|_| std::env::var("VAULT_TOKEN"))
            .ok()
            .or_else(|| {
                let path = std::env::var("BAO_TOKEN_PATH").ok().or_else(|| {
                    std::env::var("HOME")
                        .ok()
                        .map(|h| format!("{h}/.vault-token"))
                })?;
                std::fs::read_to_string(path)
                    .ok()
                    .map(|s| s.trim().to_string())
            })
            .unwrap_or_default();

        Self {
            mode: Mode::Dark,
            screen: Screen::Connect,
            address,
            token,
            connect_status: String::new(),
            client: None,
            mount: "secret".into(),
            folder: String::new(),
            current_path: String::new(),
            list_keys: Vec::new(),
            show_detail: false,
            path_display: String::new(),
            meta: String::new(),
            kv_rows: Vec::new(),
            reveal_values: false,
            new_dialog: None,
            delete_confirm: false,
            toast: None,
        }
    }

    fn theme(&self) -> Theme {
        match self.mode {
            Mode::Dark => Theme::dark(),
            Mode::Light => Theme::light(),
        }
    }

    fn show_toast(&mut self, msg: impl Into<String>) {
        self.toast = Some((msg.into(), Instant::now()));
    }

    fn breadcrumb(&self) -> String {
        if self.folder.is_empty() {
            "/".into()
        } else {
            format!("/{}", self.folder)
        }
    }

    fn connect(&mut self) {
        let addr = self.address.trim();
        let tok = self.token.trim();
        if addr.is_empty() || tok.is_empty() {
            self.connect_status = "Address and token are required.".into();
            return;
        }

        self.connect_status = "Connecting…".into();

        let client = match Client::new(addr, tok) {
            Ok(c) => c,
            Err(e) => {
                self.connect_status = format!("Failed: {e}");
                return;
            }
        };

        match client.health() {
            Ok(h) => {
                if h.sealed {
                    self.connect_status = "Server is sealed.".into();
                    return;
                }
                if !h.initialized {
                    self.connect_status = "Server is not initialized.".into();
                    return;
                }
            }
            Err(e) => {
                self.connect_status = format!("Health check failed: {e}");
                return;
            }
        }

        if let Err(e) = client.lookup_self() {
            self.connect_status = format!("Token invalid: {e}");
            return;
        }

        let mount = match client.default_kv_mount() {
            Ok(m) => m,
            Err(e) => {
                self.connect_status = e.to_string();
                return;
            }
        };

        self.client = Some(client);
        self.mount = mount;
        self.folder.clear();
        self.current_path.clear();
        self.path_display.clear();
        self.meta.clear();
        self.kv_rows.clear();
        self.show_detail = false;
        self.connect_status.clear();
        self.screen = Screen::Main;
        self.refresh_list();
    }

    fn disconnect(&mut self) {
        self.client = None;
        self.folder.clear();
        self.current_path.clear();
        self.list_keys.clear();
        self.kv_rows.clear();
        self.show_detail = false;
        self.new_dialog = None;
        self.delete_confirm = false;
        self.screen = Screen::Connect;
    }

    fn refresh_list(&mut self) {
        let Some(client) = self.client.clone() else {
            return;
        };
        let mount = self.mount.clone();
        let folder = self.folder.clone();
        match client.list_secrets(&mount, &folder) {
            Ok(keys) => self.list_keys = keys,
            Err(e) => {
                self.list_keys.clear();
                self.show_toast(format!("List failed: {e}"));
            }
        }
    }

    fn go_up(&mut self) {
        if self.folder.is_empty() {
            return;
        }
        if let Some(idx) = self.folder.rfind('/') {
            self.folder = self.folder[..idx].to_string();
        } else {
            self.folder.clear();
        }
        self.current_path.clear();
        self.show_detail = false;
        self.refresh_list();
    }

    fn open_list_item(&mut self, name: &str) {
        if name.ends_with('/') {
            let folder_name = name.trim_end_matches('/');
            if self.folder.is_empty() {
                self.folder = folder_name.to_string();
            } else {
                self.folder = format!("{}/{}", self.folder, folder_name);
            }
            self.current_path.clear();
            self.show_detail = false;
            self.refresh_list();
            return;
        }

        let Some(client) = self.client.clone() else {
            return;
        };
        let full = if self.folder.is_empty() {
            name.to_string()
        } else {
            format!("{}/{}", self.folder, name)
        };
        let mount = self.mount.clone();

        match client.read_secret(&mount, &full) {
            Ok(secret) => self.apply_secret(&full, &secret),
            Err(e) => self.show_toast(format!("Read failed: {e}")),
        }
    }

    fn apply_secret(&mut self, path: &str, secret: &SecretData) {
        self.current_path = path.to_string();
        self.path_display = path.to_string();
        self.kv_rows = secret
            .data
            .iter()
            .map(|(k, v)| KvRow {
                key: k.clone(),
                value: v.clone(),
            })
            .collect();
        let mut meta = String::new();
        if let Some(v) = secret.version {
            meta.push_str(&format!("version {v}"));
        }
        if let Some(t) = &secret.created_time {
            if !meta.is_empty() {
                meta.push_str(" · ");
            }
            meta.push_str(t);
        }
        self.meta = meta;
        self.show_detail = true;
    }

    fn collect_kv(&self) -> BTreeMap<String, String> {
        let mut map = BTreeMap::new();
        for row in &self.kv_rows {
            let k = row.key.trim();
            if !k.is_empty() {
                map.insert(k.to_string(), row.value.clone());
            }
        }
        map
    }

    fn save_secret(&mut self) {
        let Some(client) = self.client.clone() else {
            return;
        };
        if self.current_path.is_empty() {
            self.show_toast("No secret selected");
            return;
        }
        let data = self.collect_kv();
        let mount = self.mount.clone();
        let path = self.current_path.clone();
        match client.write_secret(&mount, &path, &data) {
            Ok(()) => {
                self.show_toast("Saved");
                self.refresh_list();
            }
            Err(e) => self.show_toast(format!("Save failed: {e}")),
        }
    }

    fn destroy_current(&mut self) {
        let Some(client) = self.client.clone() else {
            return;
        };
        let mount = self.mount.clone();
        let path = self.current_path.clone();
        match client.destroy_secret(&mount, &path) {
            Ok(()) => {
                self.show_toast("Deleted");
                self.current_path.clear();
                self.path_display.clear();
                self.meta.clear();
                self.kv_rows.clear();
                self.show_detail = false;
                self.delete_confirm = false;
                self.refresh_list();
            }
            Err(e) => self.show_toast(format!("Delete failed: {e}")),
        }
    }

    fn create_secret(&mut self) {
        let Some(dlg) = self.new_dialog.as_ref() else {
            return;
        };
        let rel = dlg.path.trim().trim_matches('/');
        if rel.is_empty() {
            self.show_toast("Path is required");
            return;
        }
        let data = parse_kv_lines(&dlg.body);
        if data.is_empty() {
            self.show_toast("Add at least one key=value line");
            return;
        }
        let Some(client) = self.client.clone() else {
            return;
        };
        let full = if self.folder.is_empty() {
            rel.to_string()
        } else {
            format!("{}/{}", self.folder, rel)
        };
        let mount = self.mount.clone();
        match client.write_secret(&mount, &full, &data) {
            Ok(()) => {
                self.show_toast(format!("Wrote {full}"));
                self.current_path = full.clone();
                self.path_display = full;
                self.new_dialog = None;
                self.refresh_list();
                // Reload so version meta is accurate
                if let Ok(secret) = client.read_secret(&mount, &self.current_path) {
                    let path = self.current_path.clone();
                    self.apply_secret(&path, &secret);
                }
            }
            Err(e) => self.show_toast(format!("Write failed: {e}")),
        }
    }

}

impl eframe::App for BaoGuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let th = self.theme();
        apply(ctx, &th);

        if let Some((_, at)) = &self.toast {
            if at.elapsed() > Duration::from_secs(TOAST_SECS) {
                self.toast = None;
            }
        }

        match self.screen {
            Screen::Connect => self.ui_connect(ctx, &th),
            Screen::Main => self.ui_main(ctx, &th),
        }

        self.ui_modals(ctx, &th);
        self.ui_toast(ctx, &th);
    }
}

impl BaoGuiApp {
    fn ui_connect(&mut self, ctx: &egui::Context, th: &Theme) {
        egui::TopBottomPanel::top("connect_header")
            .frame(th.header_frame())
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    title(ui, th, "BaoGUI");
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let dark = self.mode == Mode::Dark;
                        if button(ui, th, if dark { "Light" } else { "Dark" }).clicked() {
                            self.mode = if dark { Mode::Light } else { Mode::Dark };
                        }
                    });
                });
            });

        egui::CentralPanel::default()
            .frame(th.page_frame())
            .show(ctx, |ui| {
                ui.vertical_centered(|ui| {
                    ui.add_space(th.spacing.xl * 1.5);
                    title(ui, th, "BaoGUI");
                    dim_label(ui, th, "Simple OpenBao secrets client");
                    ui.add_space(th.spacing.lg);

                    let max_w = 420.0_f32;
                    let form_w = ui.available_width().min(max_w);
                    ui.set_max_width(form_w);

                    th.card_frame().show(ui, |ui| {
                        ui.set_min_width(form_w - th.spacing.md * 2.0);
                        dim_label(ui, th, "Server address");
                        ui.add_space(th.spacing.xs);
                        text_field_singleline(ui, th, &mut self.address);
                        ui.add_space(th.spacing.md);

                        dim_label(ui, th, "Token");
                        ui.add_space(th.spacing.xs);
                        ui.add(
                            TextEdit::singleline(&mut self.token)
                                .password(true)
                                .margin(th.text_edit_margin())
                                .min_size(Vec2::new(0.0, th.spacing.control_height))
                                .desired_width(f32::INFINITY),
                        );
                    });

                    ui.add_space(th.spacing.lg);
                    if primary_button(ui, th, "Connect").clicked()
                        || (ui.input(|i| i.key_pressed(Key::Enter))
                            && !self.address.trim().is_empty()
                            && !self.token.trim().is_empty())
                    {
                        self.connect();
                    }

                    if !self.connect_status.is_empty() {
                        ui.add_space(th.spacing.sm);
                        ui.label(
                            RichText::new(&self.connect_status)
                                .size(th.type_scale.caption)
                                .color(if self.connect_status.starts_with("Connecting") {
                                    th.palette.text_secondary
                                } else {
                                    th.palette.destructive
                                }),
                        );
                    }

                    ui.add_space(th.spacing.lg);
                    dim_label(
                        ui,
                        th,
                        "Uses BAO_ADDR / BAO_TOKEN when set.\nCompatible with Vault-style KV v2 mounts.",
                    );
                });
            });
    }

    fn ui_main(&mut self, ctx: &egui::Context, th: &Theme) {
        egui::TopBottomPanel::top("main_header")
            .frame(th.header_frame())
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    if button(ui, th, "Disconnect").clicked() {
                        self.disconnect();
                        return;
                    }
                    ui.add_space(th.spacing.sm);
                    title_2(ui, th, "OpenBao");
                    dim_label(ui, th, &format!("· {}/", self.mount));

                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let dark = self.mode == Mode::Dark;
                        if button(ui, th, if dark { "Light" } else { "Dark" }).clicked() {
                            self.mode = if dark { Mode::Light } else { Mode::Dark };
                        }
                        if button(ui, th, "New").clicked() {
                            self.new_dialog = Some(NewDialog {
                                path: String::new(),
                                body: "key=value\n".into(),
                            });
                        }
                        if button(ui, th, "Refresh").clicked() {
                            self.refresh_list();
                        }
                    });
                });
            });

        egui::SidePanel::left("sidebar")
            .exact_width(SIDEBAR_W)
            .resizable(true)
            .default_width(SIDEBAR_W)
            .frame(
                egui::Frame::new()
                    .fill(th.palette.view_bg)
                    .inner_margin(egui::Margin::same(th.spacing.md as i8))
                    .stroke(egui::Stroke::new(1.0, th.palette.border_soft)),
            )
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    dim_label(ui, th, &format!("Mount: {}/", self.mount));
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let can_up = !self.folder.is_empty();
                        ui.add_enabled_ui(can_up, |ui| {
                            if button(ui, th, "↑").clicked() {
                                self.go_up();
                            }
                        });
                    });
                });
                ui.add_space(th.spacing.xs);
                title_2(ui, th, &self.breadcrumb());
                ui.add_space(th.spacing.sm);
                ui.separator();
                ui.add_space(th.spacing.sm);

                ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        if self.list_keys.is_empty() {
                            dim_label(ui, th, "(empty)");
                            return;
                        }

                        let mut clicked: Option<String> = None;
                        for key in &self.list_keys {
                            let is_folder = key.ends_with('/');
                            let label = if is_folder {
                                format!("📁  {key}")
                            } else {
                                format!("🔑  {key}")
                            };
                            let selected = !is_folder
                                && self.current_path.ends_with(key.as_str())
                                && (self.folder.is_empty()
                                    || self.current_path.starts_with(&self.folder));

                            let resp = ui
                                .add(
                                    egui::Button::new(
                                        RichText::new(label)
                                            .size(th.type_scale.body)
                                            .color(if selected {
                                                th.palette.accent
                                            } else {
                                                th.palette.text
                                            }),
                                    )
                                    .fill(if selected {
                                        th.palette.accent.gamma_multiply(0.2)
                                    } else {
                                        Color32::TRANSPARENT
                                    })
                                    .stroke(egui::Stroke::NONE)
                                    .min_size(Vec2::new(ui.available_width(), th.spacing.control_height))
                                    .sense(Sense::click()),
                                );
                            if resp.clicked() {
                                clicked = Some(key.clone());
                            }
                        }
                        if let Some(name) = clicked {
                            self.open_list_item(&name);
                        }
                    });
            });

        egui::CentralPanel::default()
            .frame(th.page_frame())
            .show(ctx, |ui| {
                if !self.show_detail {
                    ui.vertical_centered(|ui| {
                        ui.add_space(ui.available_height() * 0.25);
                        title(ui, th, "No secret selected");
                        dim_label(
                            ui,
                            th,
                            "Choose a secret from the list, or create a new one.",
                        );
                    });
                    return;
                }

                ui.horizontal(|ui| {
                    ui.add(
                        TextEdit::singleline(&mut self.path_display)
                            .interactive(false)
                            .margin(th.text_edit_margin())
                            .desired_width(ui.available_width() - 90.0)
                            .font(egui::TextStyle::Monospace),
                    );
                    if button(ui, th, "Copy").clicked() {
                        ctx.copy_text(self.path_display.clone());
                        self.show_toast("Path copied");
                    }
                });

                if !self.meta.is_empty() {
                    dim_label(ui, th, &self.meta);
                }

                ui.add_space(th.spacing.sm);
                ui.horizontal(|ui| {
                    let label = if self.reveal_values {
                        "Hide values"
                    } else {
                        "Show values"
                    };
                    if button(ui, th, label).clicked() {
                        self.reveal_values = !self.reveal_values;
                    }
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if destructive_button(ui, th, "Delete").clicked() {
                            self.delete_confirm = true;
                        }
                        if primary_button(ui, th, "Save").clicked() {
                            self.save_secret();
                        }
                    });
                });

                ui.add_space(th.spacing.sm);
                ui.separator();
                ui.add_space(th.spacing.sm);

                ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        if self.kv_rows.is_empty() {
                            dim_label(ui, th, "No key/value pairs");
                        }

                        let mut remove_idx: Option<usize> = None;
                        let mut copy_val: Option<String> = None;
                        let reveal = self.reveal_values;

                        for (i, row) in self.kv_rows.iter_mut().enumerate() {
                            th.card_frame().show(ui, |ui| {
                                ui.horizontal(|ui| {
                                    ui.add(
                                        TextEdit::singleline(&mut row.key)
                                            .margin(th.text_edit_margin())
                                            .desired_width(140.0)
                                            .font(egui::TextStyle::Monospace)
                                            .hint_text("key"),
                                    );
                                    ui.add(
                                        TextEdit::singleline(&mut row.value)
                                            .password(!reveal)
                                            .margin(th.text_edit_margin())
                                            .desired_width(
                                                (ui.available_width() - 120.0).max(80.0),
                                            )
                                            .font(egui::TextStyle::Monospace)
                                            .hint_text("value"),
                                    );
                                    if button(ui, th, "Copy").clicked() {
                                        copy_val = Some(row.value.clone());
                                    }
                                    if button(ui, th, "✕").clicked() {
                                        remove_idx = Some(i);
                                    }
                                });
                            });
                            ui.add_space(th.spacing.xs);
                        }

                        if let Some(i) = remove_idx {
                            self.kv_rows.remove(i);
                        }
                        if let Some(v) = copy_val {
                            ctx.copy_text(v);
                            self.show_toast("Value copied");
                        }

                        ui.add_space(th.spacing.sm);
                        if button(ui, th, "Add key").clicked() {
                            self.kv_rows.push(KvRow {
                                key: String::new(),
                                value: String::new(),
                            });
                        }
                    });
            });
    }

    fn ui_modals(&mut self, ctx: &egui::Context, th: &Theme) {
        // New secret dialog
        if self.new_dialog.is_some() {
            let mut open = true;
            let mut create = false;
            let mut cancel = false;

            egui::Window::new("New secret")
                .collapsible(false)
                .resizable(true)
                .default_width(420.0)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .open(&mut open)
                .show(ctx, |ui| {
                    body(
                        ui,
                        th,
                        "Path relative to current folder. Key=value pairs, one per line.",
                    );
                    ui.add_space(th.spacing.md);

                    if let Some(dlg) = self.new_dialog.as_mut() {
                        dim_label(ui, th, "Path");
                        text_field_singleline(ui, th, &mut dlg.path);
                        ui.add_space(th.spacing.sm);
                        dim_label(ui, th, "Data");
                        text_field_multiline(ui, th, &mut dlg.body, 6);
                    }

                    ui.add_space(th.spacing.md);
                    ui.horizontal(|ui| {
                        if button(ui, th, "Cancel").clicked() {
                            cancel = true;
                        }
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if primary_button(ui, th, "Create").clicked() {
                                create = true;
                            }
                        });
                    });
                });

            if !open || cancel {
                self.new_dialog = None;
            } else if create {
                self.create_secret();
            }
        }

        // Delete confirm
        if self.delete_confirm {
            let path = self.current_path.clone();
            let mut open = true;
            let mut do_delete = false;
            let mut cancel = false;

            egui::Window::new("Delete secret?")
                .collapsible(false)
                .resizable(false)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .open(&mut open)
                .show(ctx, |ui| {
                    body(
                        ui,
                        th,
                        &format!(
                            "Permanently delete “{path}” and all versions? This cannot be undone."
                        ),
                    );
                    ui.add_space(th.spacing.md);
                    ui.horizontal(|ui| {
                        if button(ui, th, "Cancel").clicked() {
                            cancel = true;
                        }
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if destructive_button(ui, th, "Delete").clicked() {
                                do_delete = true;
                            }
                        });
                    });
                });

            if !open || cancel {
                self.delete_confirm = false;
            } else if do_delete {
                self.destroy_current();
            }
        }
    }

    fn ui_toast(&self, ctx: &egui::Context, th: &Theme) {
        let Some((msg, _)) = &self.toast else {
            return;
        };
        egui::Area::new(egui::Id::new("toast"))
            .anchor(egui::Align2::CENTER_BOTTOM, [0.0, -24.0])
            .order(egui::Order::Foreground)
            .show(ctx, |ui| {
                egui::Frame::new()
                    .fill(th.palette.popover_bg)
                    .stroke(egui::Stroke::new(1.0, th.palette.border))
                    .corner_radius(th.spacing.radius_md)
                    .inner_margin(egui::Margin::symmetric(
                        th.spacing.lg as i8,
                        th.spacing.md as i8,
                    ))
                    .shadow(egui::Shadow {
                        offset: [0, 4],
                        blur: 12,
                        spread: 0,
                        color: th.palette.shade,
                    })
                    .show(ui, |ui| {
                        ui.label(
                            RichText::new(msg)
                                .size(th.type_scale.body)
                                .color(th.palette.text),
                        );
                    });
            });
    }
}

fn parse_kv_lines(text: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            let k = k.trim();
            if !k.is_empty() {
                map.insert(k.to_string(), v.trim().to_string());
            }
        }
    }
    map
}
