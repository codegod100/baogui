//! BaoGUI window: connect form + secret browser / editor.

use std::collections::BTreeMap;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use eframe::egui::{self, Align, Key, Layout, RichText, ScrollArea, TextEdit, Vec2};
use vidya::{
    apply, body, button, card, central_page, data_table, destructive_button, dim_label,
    icon_button, primary_button, table_text, text_field_multiline, text_field_singleline, title,
    title_2, Col, ColKind, Icon, Theme,
};

use crate::api::{Client, SecretData};

const TOAST_SECS: u64 = 3;
const SIDEBAR_W: f32 = 260.0;
const SEARCH_DEBOUNCE: Duration = Duration::from_millis(400);

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

#[derive(Clone)]
struct SearchHit {
    path: String,
    key: String,
    value: String,
}

struct SearchResultMsg {
    cache_key: String,
    hits: Result<Vec<SearchHit>, String>,
}

pub struct BaoGuiApp {
    screen: Screen,

    // Connect form
    address: String,
    token: String,
    connect_status: String,
    /// When false, a stored token is used and the token field is hidden.
    show_token_field: bool,
    /// Fire one auto-connect with the stored token on first Connect-screen frame.
    pending_auto_connect: bool,

    // Session
    client: Option<Client>,
    mount: String,
    folder: String,
    current_path: String,

    // Sidebar
    list_keys: Vec<String>,
    list_filter: String,

    // Search results (mount-wide; Path / Key / Value table)
    search_hits: Vec<SearchHit>,
    /// Cache key: `mount\\0filter` for the last computed `search_hits`.
    search_cache_key: String,
    /// Debounced search: run after typing pauses so we never block the UI thread.
    search_debounce: Option<Instant>,
    /// Filter string the current debounce timer is waiting on.
    search_debounce_for: Option<String>,
    search_rx: Option<mpsc::Receiver<SearchResultMsg>>,

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

    /// Sidebar click is deferred to the start of the next frame so we never
    /// run blocking HTTP mid-layout (which can leave the detail pane blank).
    pending_open: Option<String>,
}

impl BaoGuiApp {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let theme = Theme::dark();
        apply(&cc.egui_ctx, &theme);

        let address = std::env::var("BAO_ADDR")
            .or_else(|_| std::env::var("VAULT_ADDR"))
            .unwrap_or_else(|_| "http://127.0.0.1:8200".into());

        let token = load_stored_token();
        let has_stored = !token.is_empty();

        Self {
            screen: Screen::Connect,
            address,
            token,
            connect_status: if has_stored {
                "Connecting with stored token…".into()
            } else {
                String::new()
            },
            // Only ask for a token when we don't have one (or after a failed auto-try).
            show_token_field: !has_stored,
            pending_auto_connect: has_stored,
            client: None,
            mount: "secret".into(),
            folder: String::new(),
            current_path: String::new(),
            list_keys: Vec::new(),
            list_filter: String::new(),
            search_hits: Vec::new(),
            search_cache_key: String::new(),
            search_debounce: None,
            search_debounce_for: None,
            search_rx: None,
            show_detail: false,
            path_display: String::new(),
            meta: String::new(),
            kv_rows: Vec::new(),
            reveal_values: false,
            new_dialog: None,
            delete_confirm: false,
            toast: None,
            pending_open: None,
        }
    }

    fn theme(&self) -> Theme {
        Theme::dark()
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
        if addr.is_empty() {
            self.connect_status = "Server address is required.".into();
            self.show_token_field = self.show_token_field || tok.is_empty();
            return;
        }
        if tok.is_empty() {
            self.connect_status = "Token is required.".into();
            self.show_token_field = true;
            return;
        }

        self.connect_status = "Connecting…".into();

        let client = match Client::new(addr, tok) {
            Ok(c) => c,
            Err(e) => {
                self.connect_failed(format!("Failed: {e}"), true);
                return;
            }
        };

        match client.health() {
            Ok(h) => {
                if h.sealed {
                    self.connect_failed("Server is sealed.".into(), false);
                    return;
                }
                if !h.initialized {
                    self.connect_failed("Server is not initialized.".into(), false);
                    return;
                }
            }
            Err(e) => {
                self.connect_failed(format!("Health check failed: {e}"), false);
                return;
            }
        }

        if let Err(e) = client.lookup_self() {
            self.connect_failed(format!("Token invalid: {e}"), true);
            return;
        }

        let mount = match client.default_kv_mount() {
            Ok(m) => m,
            Err(e) => {
                // Mounts often need a privileged token — surface the field so
                // the user can paste a root/admin token.
                self.connect_failed(e.to_string(), true);
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
        self.show_token_field = false;
        self.screen = Screen::Main;
        self.refresh_list();
    }

    fn connect_failed(&mut self, message: String, need_token: bool) {
        self.connect_status = message;
        if need_token {
            self.show_token_field = true;
        }
    }

    fn disconnect(&mut self) {
        self.client = None;
        self.folder.clear();
        self.current_path.clear();
        self.list_keys.clear();
        self.list_filter.clear();
        self.clear_search();
        self.kv_rows.clear();
        self.show_detail = false;
        self.new_dialog = None;
        self.delete_confirm = false;
        self.screen = Screen::Connect;
        // Keep token if still stored; hide field until a retry fails.
        let stored = load_stored_token();
        if !stored.is_empty() {
            self.token = stored;
            self.show_token_field = false;
            self.connect_status.clear();
        } else {
            self.show_token_field = true;
        }
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
        self.invalidate_search();
    }

    fn search_cache_key(mount: &str, filter: &str) -> String {
        format!("{mount}\0{filter}")
    }

    fn wanted_search_key(&self) -> Option<String> {
        let filter = self.list_filter.trim().to_lowercase();
        if filter.is_empty() {
            None
        } else {
            Some(Self::search_cache_key(&self.mount, &filter))
        }
    }

    fn clear_search(&mut self) {
        self.search_hits.clear();
        self.search_cache_key.clear();
        self.search_debounce = None;
        self.search_debounce_for = None;
        self.search_rx = None;
    }

    fn invalidate_search(&mut self) {
        self.search_cache_key.clear();
        self.search_debounce = None;
        self.search_debounce_for = None;
        self.search_rx = None;
    }

    fn poll_search(&mut self) {
        let Some(rx) = &self.search_rx else {
            return;
        };
        if let Ok(msg) = rx.try_recv() {
            if self.wanted_search_key().as_deref() == Some(msg.cache_key.as_str()) {
                match msg.hits {
                    Ok(hits) => self.search_hits = hits,
                    Err(e) => {
                        self.search_hits.clear();
                        self.show_toast(format!("Search failed: {e}"));
                    }
                }
                self.search_cache_key = msg.cache_key;
            }
            self.search_rx = None;
        }
    }

    fn spawn_search(&mut self, cache_key: String) {
        let Some(client) = self.client.clone() else {
            self.search_cache_key = cache_key;
            return;
        };
        let mount = self.mount.clone();
        let filter = cache_key
            .split_once('\0')
            .map(|(_, f)| f.to_string())
            .unwrap_or_default();
        let (tx, rx) = mpsc::channel();
        self.search_rx = Some(rx);
        std::thread::spawn(move || {
            let hits = compute_search_hits(&client, &mount, &filter).map_err(|e| e.to_string());
            let _ = tx.send(SearchResultMsg { cache_key, hits });
        });
    }

    /// Debounce keystrokes and run mount-wide search off the UI thread.
    fn tick_search(&mut self, ctx: &egui::Context) {
        self.poll_search();

        let Some(wanted_key) = self.wanted_search_key() else {
            self.clear_search();
            return;
        };

        if self.search_cache_key == wanted_key {
            self.search_debounce = None;
            self.search_debounce_for = None;
            return;
        }

        if self.search_rx.is_some() {
            ctx.request_repaint();
            return;
        }

        if self.search_debounce_for.as_deref() != Some(wanted_key.as_str()) {
            self.search_debounce_for = Some(wanted_key.clone());
            let deadline = Instant::now() + SEARCH_DEBOUNCE;
            self.search_debounce = Some(deadline);
            ctx.request_repaint_after(SEARCH_DEBOUNCE);
            return;
        }

        let Some(deadline) = self.search_debounce else {
            return;
        };
        if Instant::now() < deadline {
            ctx.request_repaint_after(deadline.saturating_duration_since(Instant::now()));
            return;
        }

        self.search_debounce = None;
        self.search_debounce_for = None;
        self.spawn_search(wanted_key);
        ctx.request_repaint();
    }

    fn search_busy(&self) -> bool {
        self.wanted_search_key()
            .is_some_and(|key| key != self.search_cache_key)
    }

    /// Open a secret by full mount-relative path (navigates folder + loads detail).
    fn open_secret_at_path(&mut self, path: &str) {
        let path = path.trim_matches('/');
        if path.is_empty() {
            return;
        }
        if let Some(idx) = path.rfind('/') {
            self.folder = path[..idx].to_string();
        } else {
            self.folder.clear();
        }
        self.list_filter.clear();
        self.clear_search();
        self.refresh_list();

        let Some(client) = self.client.clone() else {
            return;
        };
        let mount = self.mount.clone();
        match client.read_secret(&mount, path) {
            Ok(secret) => self.apply_secret(path, &secret),
            Err(e) => self.show_toast(format!("Read failed: {e}")),
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
        self.list_filter.clear();
        self.show_detail = false;
        self.refresh_list();
    }

    fn enter_folder(&mut self, folder_name: &str) {
        let folder_name = folder_name.trim_matches('/');
        if folder_name.is_empty() {
            return;
        }
        if self.folder.is_empty() {
            self.folder = folder_name.to_string();
        } else {
            self.folder = format!("{}/{}", self.folder, folder_name);
        }
        self.current_path.clear();
        self.list_filter.clear();
        self.show_detail = false;
        self.refresh_list();
    }

    fn open_list_item(&mut self, name: &str) {
        // Folders are listed with a trailing slash by KV LIST.
        if name.ends_with('/') {
            self.enter_folder(name);
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

        // Prefer reading a leaf secret. If that 404s, treat the name as a folder
        // prefix (some servers omit the trailing slash on intermediate paths).
        match client.read_secret(&mount, &full) {
            Ok(secret) => {
                // Ambiguous path: empty body *and* LIST returns children → folder.
                if secret.data.is_empty() {
                    if let Ok(children) = client.list_secrets(&mount, &full) {
                        if !children.is_empty() {
                            self.enter_folder(&full);
                            return;
                        }
                    }
                }
                self.apply_secret(&full, &secret);
            }
            Err(e) => {
                let is_missing = matches!(
                    e,
                    crate::api::ApiError::Status { code: 404, .. }
                );
                if is_missing {
                    match client.list_secrets(&mount, &full) {
                        Ok(children) if !children.is_empty() => {
                            self.enter_folder(&full);
                            return;
                        }
                        Ok(_) => self.show_toast(format!("Not found: {full}")),
                        Err(list_err) => {
                            self.show_toast(format!("Read failed: {e}; list: {list_err}"))
                        }
                    }
                } else {
                    self.show_toast(format!("Read failed: {e}"));
                }
            }
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
        let n = self.kv_rows.len();
        let mut meta = format!("{n} key{}", if n == 1 { "" } else { "s" });
        if let Some(v) = secret.version {
            meta.push_str(&format!(" · version {v}"));
        }
        if let Some(t) = &secret.created_time {
            meta.push_str(" · ");
            meta.push_str(t);
        }
        self.meta = meta;
        self.show_detail = true;
        eprintln!(
            "baogui: opened {path} — {n} field(s): {:?}",
            self.kv_rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>()
        );
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

        // Auto-connect once with stored token before painting Connect UI.
        if self.pending_auto_connect && self.screen == Screen::Connect {
            self.pending_auto_connect = false;
            self.connect();
            if self.screen == Screen::Connect {
                // Failed — token field becomes visible (set in connect_failed).
                ctx.request_repaint();
            }
        }

        // Resolve sidebar opens *before* painting so the detail pane sees data.
        if let Some(name) = self.pending_open.take() {
            self.open_list_item(&name);
            ctx.request_repaint();
        }

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
                });
            });

        central_page(ctx, th, "connect", |g| {
            g.section(|ui| {
                ui.vertical_centered(|ui| {
                    ui.add_space(th.spacing.xl * 1.5);
                    title(ui, th, "BaoGUI");
                    dim_label(ui, th, "Simple OpenBao secrets client");
                    ui.add_space(th.spacing.lg);

                    let max_w = 420.0_f32;
                    let form_w = ui.available_width().min(max_w);
                    ui.set_max_width(form_w);

                    card(ui, th, |ui| {
                        dim_label(ui, th, "Server address");
                        ui.add_space(th.spacing.xs);
                        text_field_singleline(ui, th, &mut self.address);

                        if self.show_token_field {
                            ui.add_space(th.spacing.md);
                            dim_label(ui, th, "Token");
                            ui.add_space(th.spacing.xs);
                            let tw = ui.available_width().max(1.0);
                            ui.add(
                                TextEdit::singleline(&mut self.token)
                                    .password(true)
                                    .margin(th.text_edit_margin())
                                    .min_size(Vec2::new(0.0, th.spacing.control_height))
                                    .desired_width(tw),
                            );
                        } else if !self.token.is_empty() {
                            ui.add_space(th.spacing.md);
                            dim_label(ui, th, "Token: using stored credential");
                            ui.add_space(th.spacing.xs);
                            if button(ui, th, "Use a different token").clicked() {
                                self.show_token_field = true;
                                self.token.clear();
                                self.connect_status.clear();
                            }
                        }
                    });

                    ui.add_space(th.spacing.lg);
                    let can_connect = !self.address.trim().is_empty()
                        && (self.show_token_field && !self.token.trim().is_empty()
                            || !self.show_token_field && !self.token.is_empty());
                    if primary_button(ui, th, "Connect").clicked()
                        || (ui.input(|i| i.key_pressed(Key::Enter)) && can_connect)
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
                        "Uses BAO_ADDR / BAO_TOKEN / ~/.vault-token when set.\nCompatible with Vault-style KV v2 mounts.",
                    );
                });
            });
        });
    }

    fn ui_main(&mut self, ctx: &egui::Context, th: &Theme) {
        egui::TopBottomPanel::top("main_header")
            .frame(th.header_frame())
            .show(ctx, |ui| {
                let mut disconnect = false;
                let mut refresh = false;
                let mut new_secret = false;
                ui.horizontal(|ui| {
                    if button(ui, th, "Disconnect").clicked() {
                        disconnect = true;
                    }
                    ui.add_space(th.spacing.sm);
                    title_2(ui, th, "BaoGUI");
                    dim_label(ui, th, &format!("· {}/", self.mount));
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if button(ui, th, "New").clicked() {
                            new_secret = true;
                        }
                        if button(ui, th, "Refresh").clicked() {
                            refresh = true;
                        }
                    });
                });
                if disconnect {
                    self.disconnect();
                    return;
                }
                if refresh {
                    self.refresh_list();
                }
                if new_secret {
                    self.new_dialog = Some(NewDialog {
                        path: String::new(),
                        body: "key=value\n".into(),
                    });
                }
            });

        // Global search before panels so the table + sidebar share one hit list.
        self.tick_search(ctx);

        let filter = self.list_filter.trim().to_lowercase();
        let searching = !filter.is_empty();
        let search_busy = self.search_busy();
        let visible: Vec<String> = if searching {
            let mut paths: Vec<String> = self
                .search_hits
                .iter()
                .map(|h| h.path.clone())
                .collect();
            paths.sort();
            paths.dedup();
            paths
        } else {
            self.list_keys.clone()
        };

        egui::SidePanel::left("sidebar")
            .resizable(true)
            .default_width(SIDEBAR_W)
            .width_range(200.0..=420.0)
            .frame(
                egui::Frame::new()
                    .fill(th.palette.view_bg)
                    .inner_margin(egui::Margin::symmetric(
                        th.spacing.md as i8,
                        th.spacing.sm as i8,
                    ))
                    .stroke(egui::Stroke::new(1.0_f32, th.palette.border_soft)),
            )
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    dim_label(ui, th, &format!("Mount: {}/", self.mount));
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        ui.add_enabled_ui(!self.folder.is_empty() && !searching, |ui| {
                            if button(ui, th, "Up").clicked() {
                                self.go_up();
                            }
                        });
                    });
                });
                ui.add_space(th.spacing.xs);
                ui.label(
                    RichText::new(if searching {
                        "Search".to_string()
                    } else {
                        self.breadcrumb()
                    })
                    .size(th.type_scale.title_2)
                    .strong()
                    .color(th.palette.text)
                    .monospace(),
                );
                ui.add_space(th.spacing.sm);
                ui.separator();
                ui.add_space(th.spacing.xs);

                let sw = ui.available_width().max(1.0);
                ui.add(
                    TextEdit::singleline(&mut self.list_filter)
                        .hint_text("Search all secrets…")
                        .margin(th.text_edit_margin())
                        .desired_width(sw)
                        .min_size(Vec2::new(0.0, th.spacing.control_height)),
                );
                ui.add_space(th.spacing.xs);

                ScrollArea::vertical()
                    .id_salt("sidebar_list")
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        if searching {
                            if visible.is_empty() {
                                dim_label(
                                    ui,
                                    th,
                                    if search_busy {
                                        "(searching…)"
                                    } else {
                                        "(no matches)"
                                    },
                                );
                                return;
                            }
                            let mut clicked: Option<String> = None;
                            for path in &visible {
                                let selected = self.current_path == *path;
                                let row_w = ui.available_width().max(1.0);
                                let resp = ui.add_sized(
                                    [row_w, th.spacing.control_height],
                                    egui::SelectableLabel::new(
                                        selected,
                                        RichText::new(path)
                                            .size(th.type_scale.body)
                                            .monospace()
                                            .color(if selected {
                                                th.palette.accent
                                            } else {
                                                th.palette.text
                                            }),
                                    ),
                                );
                                if resp.clicked() {
                                    clicked = Some(path.clone());
                                }
                            }
                            if let Some(path) = clicked {
                                self.open_secret_at_path(&path);
                                ui.ctx().request_repaint();
                            }
                            return;
                        }

                        if self.list_keys.is_empty() {
                            dim_label(ui, th, "(empty)");
                            return;
                        }

                        let mut clicked: Option<String> = None;
                        for key in &visible {
                            let is_folder = key.ends_with('/');
                            let display = key.trim_end_matches('/').to_string();
                            let selected = !is_folder
                                && (self.current_path == *key
                                    || self.current_path.ends_with(&format!("/{key}"))
                                    || self.current_path == display);

                            let row_w = ui.available_width().max(1.0);
                            let text = if is_folder {
                                format!("▸  {display}")
                            } else {
                                display.clone()
                            };
                            let resp = ui.add_sized(
                                [row_w, th.spacing.control_height],
                                egui::SelectableLabel::new(
                                    selected,
                                    RichText::new(text)
                                        .size(th.type_scale.body)
                                        .monospace()
                                        .color(if selected {
                                            th.palette.accent
                                        } else {
                                            th.palette.text
                                        }),
                                ),
                            );
                            if resp.clicked() {
                                clicked = Some(key.clone());
                            }
                        }
                        if let Some(name) = clicked {
                            self.pending_open = Some(name);
                            ui.ctx().request_repaint();
                        }
                    });
            });

        let searching = !self.list_filter.trim().is_empty();

        egui::CentralPanel::default()
            .frame(th.page_frame())
            .show(ctx, |ui| {
                if searching {
                    self.ui_search_results(ui, ctx, th);
                    return;
                }

                if !self.show_detail {
                    ui.vertical_centered(|ui| {
                        ui.add_space(ui.available_height() * 0.28);
                        title(ui, th, "No secret selected");
                        dim_label(
                            ui,
                            th,
                            "Choose a secret from the list, or create a new one.",
                        );
                    });
                    return;
                }

                // ── Header ──────────────────────────────────────────
                ui.horizontal(|ui| {
                    ui.vertical(|ui| {
                        ui.label(
                            RichText::new(&self.path_display)
                                .size(th.type_scale.title_2)
                                .strong()
                                .color(th.palette.text)
                                .monospace(),
                        );
                        if !self.meta.is_empty() {
                            dim_label(ui, th, &self.meta);
                        }
                    });
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if icon_button(ui, th, Icon::Copy, "Copy path").clicked() {
                            ctx.copy_text(self.path_display.clone());
                            self.show_toast("Path copied");
                        }
                    });
                });

                ui.add_space(th.spacing.md);
                let mut reveal_clicked = false;
                let mut delete_clicked = false;
                let mut save_clicked = false;
                let mut add_key = false;
                let reveal_label = if self.reveal_values {
                    "Hide values"
                } else {
                    "Show values"
                };
                ui.horizontal(|ui| {
                    if button(ui, th, reveal_label).clicked() {
                        reveal_clicked = true;
                    }
                    if button(ui, th, "Add key").clicked() {
                        add_key = true;
                    }
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if destructive_button(ui, th, "Delete").clicked() {
                            delete_clicked = true;
                        }
                        if primary_button(ui, th, "Save").clicked() {
                            save_clicked = true;
                        }
                    });
                });
                if reveal_clicked {
                    self.reveal_values = !self.reveal_values;
                }
                if add_key {
                    self.kv_rows.push(KvRow {
                        key: String::new(),
                        value: String::new(),
                    });
                }
                if save_clicked {
                    self.save_secret();
                }
                if delete_clicked {
                    self.delete_confirm = true;
                }

                ui.add_space(th.spacing.md);
                ui.separator();
                ui.add_space(th.spacing.sm);

                if self.kv_rows.is_empty() {
                    dim_label(ui, th, "No key/value pairs in this secret.");
                    return;
                }

                // Column headers
                let full_w = ui.available_width().max(1.0);
                let ctrl_h = th.spacing.control_height;
                let act_w = ctrl_h * 2.0 + th.spacing.sm; // copy icon + remove
                let key_w = (full_w * 0.32).clamp(140.0, 280.0);
                let val_w = (full_w - key_w - act_w - th.spacing.md).max(80.0);
                let row_h = ctrl_h + 4.0;

                ui.horizontal(|ui| {
                    ui.add_space(4.0);
                    ui.add_sized(
                        [key_w, 16.0],
                        egui::Label::new(
                            RichText::new("Key")
                                .size(th.type_scale.caption)
                                .color(th.palette.text_secondary),
                        ),
                    );
                    ui.add_sized(
                        [val_w, 16.0],
                        egui::Label::new(
                            RichText::new("Value")
                                .size(th.type_scale.caption)
                                .color(th.palette.text_secondary),
                        ),
                    );
                });
                ui.add_space(th.spacing.xs);

                let n = self.kv_rows.len();
                let reveal = self.reveal_values;
                let mut remove_idx: Option<usize> = None;
                let mut copy_val: Option<String> = None;

                ScrollArea::vertical()
                    .id_salt("kv_list")
                    .auto_shrink([false, false])
                    .show_rows(ui, row_h, n, |ui, row_range| {
                        for i in row_range {
                            let row = &mut self.kv_rows[i];
                            ui.horizontal(|ui| {
                                ui.spacing_mut().item_spacing.x = th.spacing.sm;
                                ui.set_height(row_h);
                                ui.add_sized(
                                    [key_w, ctrl_h],
                                    TextEdit::singleline(&mut row.key)
                                        .id_salt(("k", i))
                                        .font(egui::TextStyle::Monospace)
                                        .hint_text("key")
                                        .margin(th.text_edit_margin()),
                                );
                                ui.add_sized(
                                    [val_w, ctrl_h],
                                    TextEdit::singleline(&mut row.value)
                                        .id_salt(("v", i))
                                        .password(!reveal)
                                        .font(egui::TextStyle::Monospace)
                                        .hint_text("value")
                                        .margin(th.text_edit_margin()),
                                );
                                if icon_button(ui, th, Icon::Copy, "Copy value").clicked() {
                                    copy_val = Some(row.value.clone());
                                }
                                if ui
                                    .add_sized([ctrl_h, ctrl_h], egui::Button::new("×"))
                                    .on_hover_text("Remove key")
                                    .clicked()
                                {
                                    remove_idx = Some(i);
                                }
                            });
                        }
                    });

                if let Some(i) = remove_idx {
                    self.kv_rows.remove(i);
                }
                if let Some(v) = copy_val {
                    ctx.copy_text(v);
                    self.show_toast("Value copied");
                }
            });
    }

    fn ui_search_results(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, th: &Theme) {
        let n = self.search_hits.len();
        ui.horizontal(|ui| {
            ui.vertical(|ui| {
                title_2(ui, th, "Search results");
                dim_label(
                    ui,
                    th,
                    &format!(
                        "{n} matching key/value pair{} across {}/",
                        if n == 1 { "" } else { "s" },
                        self.mount
                    ),
                );
            });
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let reveal_label = if self.reveal_values {
                    "Hide values"
                } else {
                    "Show values"
                };
                if button(ui, th, reveal_label).clicked() {
                    self.reveal_values = !self.reveal_values;
                }
            });
        });

        ui.add_space(th.spacing.md);
        ui.separator();
        ui.add_space(th.spacing.sm);

        if n == 0 {
            dim_label(
                ui,
                th,
                if self.search_busy() {
                    "Searching…"
                } else {
                    "No matching keys or values in this mount."
                },
            );
            return;
        }

        let hits = self.search_hits.clone();
        let reveal = self.reveal_values;
        let cols = [
            Col {
                header: "Path",
                kind: ColKind::Flex,
            },
            Col {
                header: "Key",
                kind: ColKind::Flex,
            },
            Col {
                header: "Value",
                kind: ColKind::Flex,
            },
        ];

        let mut open_path: Option<String> = None;
        let mut copy_val: Option<String> = None;

        ScrollArea::vertical()
            .id_salt("search_hits")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                data_table(ui, th, "search_hits_table", &cols, |ui, i| {
                    let hit = &hits[i];
                    let path_resp = ui.add(
                        egui::Label::new(
                            RichText::new(&hit.path)
                                .size(th.type_scale.body)
                                .monospace()
                                .color(th.palette.accent),
                        )
                        .sense(egui::Sense::click()),
                    );
                    if path_resp.clicked() {
                        open_path = Some(hit.path.clone());
                    }
                    if path_resp.hovered() {
                        ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
                    }
                    path_resp.on_hover_text("Open secret");

                    table_text(ui, th, &hit.key, true);

                    let shown = if reveal {
                        hit.value.as_str()
                    } else {
                        "••••••••"
                    };
                    let val_resp = ui.add(
                        egui::Label::new(
                            RichText::new(shown)
                                .size(th.type_scale.body)
                                .monospace()
                                .color(th.palette.text),
                        )
                        .sense(egui::Sense::click()),
                    );
                    if val_resp.clicked() {
                        copy_val = Some(hit.value.clone());
                    }
                    val_resp.on_hover_text("Copy value");
                }, n);
            });

        if let Some(path) = open_path {
            self.open_secret_at_path(&path);
            ctx.request_repaint();
        }
        if let Some(v) = copy_val {
            ctx.copy_text(v);
            self.show_toast("Value copied");
        }
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
                    .stroke(egui::Stroke::new(1.0_f32, th.palette.border))
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

fn compute_search_hits(
    client: &Client,
    mount: &str,
    filter: &str,
) -> Result<Vec<SearchHit>, crate::api::ApiError> {
    let filter = filter.to_lowercase();
    let paths = client.list_all_secret_paths(mount)?;
    let mut hits = Vec::new();

    for full in paths {
        let path_match = full.to_lowercase().contains(&filter);
        let secret = match client.read_secret(mount, &full) {
            Ok(s) => s,
            Err(_) => continue,
        };
        for (k, v) in &secret.data {
            let key_match = k.to_lowercase().contains(&filter);
            let val_match = v.to_lowercase().contains(&filter);
            if path_match || key_match || val_match {
                hits.push(SearchHit {
                    path: full.clone(),
                    key: k.clone(),
                    value: v.clone(),
                });
            }
        }
    }
    hits.sort_by(|a, b| (&a.path, &a.key).cmp(&(&b.path, &b.key)));
    Ok(hits)
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

/// Prefer env tokens, then common token files (`~/.vault-token`, `~/.bao-token`).
fn load_stored_token() -> String {
    if let Ok(t) = std::env::var("BAO_TOKEN").or_else(|_| std::env::var("VAULT_TOKEN")) {
        let t = t.trim().to_string();
        if !t.is_empty() {
            return t;
        }
    }

    let home = std::env::var("HOME").ok();
    let candidates: Vec<std::path::PathBuf> = [
        std::env::var("BAO_TOKEN_PATH").ok().map(std::path::PathBuf::from),
        home.as_ref().map(|h| std::path::PathBuf::from(h).join(".vault-token")),
        home.as_ref().map(|h| std::path::PathBuf::from(h).join(".bao-token")),
    ]
    .into_iter()
    .flatten()
    .collect();

    for path in candidates {
        if let Ok(s) = std::fs::read_to_string(&path) {
            let t = s.trim().to_string();
            if !t.is_empty() {
                return t;
            }
        }
    }
    String::new()
}
