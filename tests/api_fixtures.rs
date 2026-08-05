//! Integration tests against canned OpenBao/Vault HTTP fixtures (no credentials).
//!
//! Fixture JSON lives in `tests/fixtures/`. A local mockito server serves those
//! bodies so `baogui::api::Client` exercises real reqwest paths without a live
//! OpenBao instance or token.

use baogui::api::Client;
use mockito::{Matcher, Server};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::OnceLock;

const FIXTURE_TOKEN: &str = "fixture-token";

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn fixture(name: &str) -> &'static str {
    static CACHE: OnceLock<BTreeMap<String, String>> = OnceLock::new();
    let map = CACHE.get_or_init(|| {
        let mut out = BTreeMap::new();
        let dir = fixtures_dir();
        for entry in std::fs::read_dir(&dir).unwrap_or_else(|e| {
            panic!("read fixtures dir {}: {e}", dir.display());
        }) {
            let entry = entry.expect("fixture dirent");
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let name = path
                .file_stem()
                .and_then(|s| s.to_str())
                .expect("utf8 fixture name")
                .to_string();
            let body = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
            out.insert(name, body);
        }
        out
    });
    map.get(name)
        .map(String::as_str)
        .unwrap_or_else(|| panic!("missing fixture: {name}.json"))
}

fn json_header() -> (&'static str, &'static str) {
    ("content-type", "application/json")
}

fn client(server: &Server) -> Client {
    Client::new(&server.url(), FIXTURE_TOKEN).expect("client")
}

fn mount_connect_mocks(server: &mut Server) {
    server
        .mock("GET", "/v1/sys/health")
        .match_query(Matcher::Any)
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("health"))
        .create();

    server
        .mock("GET", "/v1/auth/token/lookup-self")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("lookup_self"))
        .create();

    server
        .mock("GET", "/v1/sys/mounts")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("mounts"))
        .create();
}

#[test]
fn fixtures_are_valid_json() {
    for name in [
        "health",
        "lookup_self",
        "mounts",
        "list_secrets_root",
        "list_secrets_apps",
        "read_secret_ai_api_keys",
        "read_secret_apps_baogui",
        "write_secret_ok",
        "error_permission_denied",
    ] {
        let _: serde_json::Value =
            serde_json::from_str(fixture(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
    }
}

#[test]
fn health_and_default_kv_mount_from_fixtures() {
    let mut server = Server::new();
    mount_connect_mocks(&mut server);
    let c = client(&server);

    let health = c.health().expect("health");
    assert!(health.initialized);
    assert!(!health.sealed);
    assert_eq!(health.version.as_deref(), Some("2.2.0"));
    assert_eq!(health.cluster_name.as_deref(), Some("baogui-fixture"));

    let lookup = c.lookup_self().expect("lookup_self");
    assert_eq!(
        lookup.pointer("/data/display_name").and_then(|v| v.as_str()),
        Some("token")
    );

    assert_eq!(c.default_kv_mount().expect("mount"), "secret");
}

#[test]
fn list_and_read_secrets_from_fixtures() {
    let mut server = Server::new();

    let list_root = server
        .mock("LIST", "/v1/secret/metadata")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("list_secrets_root"))
        .create();

    let list_apps = server
        .mock("LIST", "/v1/secret/metadata/apps")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("list_secrets_apps"))
        .create();

    let read_ai = server
        .mock("GET", "/v1/secret/data/ai-api-keys")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("read_secret_ai_api_keys"))
        .create();

    let c = client(&server);

    let keys = c.list_secrets("secret", "").expect("list root");
    assert!(keys.iter().any(|k| k == "ai-api-keys"));
    assert!(keys.iter().any(|k| k == "apps/"));

    let apps = c.list_secrets("secret", "apps").expect("list apps");
    assert_eq!(apps, vec!["baogui".to_string(), "staging/".to_string()]);

    let secret = c.read_secret("secret", "ai-api-keys").expect("read");
    assert_eq!(secret.version, Some(22));
    assert_eq!(secret.data.len(), 5);
    assert_eq!(
        secret.data.get("OPENAI_API_KEY").map(String::as_str),
        Some("sk-fixture-openai")
    );

    list_root.assert();
    list_apps.assert();
    read_ai.assert();
}

#[test]
fn list_secrets_falls_back_to_get_list_query() {
    let mut server = Server::new();

    // LIST unsupported → client retries GET ?list=true
    server
        .mock("LIST", "/v1/secret/metadata")
        .with_status(405)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("error_permission_denied"))
        .create();

    let get_list = server
        .mock("GET", "/v1/secret/metadata")
        .match_query(Matcher::UrlEncoded("list".into(), "true".into()))
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("list_secrets_root"))
        .create();

    let c = client(&server);
    let keys = c.list_secrets("secret", "").expect("list via GET");
    assert!(keys.contains(&"ai-api-keys".to_string()));
    get_list.assert();
}

#[test]
fn write_and_destroy_secret_from_fixtures() {
    let mut server = Server::new();

    let write = server
        .mock("POST", "/v1/secret/data/apps/baogui")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .match_header("content-type", Matcher::Regex("application/json.*".into()))
        .match_body(Matcher::PartialJsonString(
            r#"{"data":{"LOG_LEVEL":"info"}}"#.into(),
        ))
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("write_secret_ok"))
        .create();

    let destroy = server
        .mock("DELETE", "/v1/secret/metadata/apps/baogui")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(204)
        .create();

    let c = client(&server);
    let mut data = BTreeMap::new();
    data.insert("LOG_LEVEL".into(), "info".into());
    c.write_secret("secret", "apps/baogui", &data)
        .expect("write");
    c.destroy_secret("secret", "apps/baogui")
        .expect("destroy");

    write.assert();
    destroy.assert();
}

#[test]
fn permission_denied_surfaces_error_message() {
    let mut server = Server::new();
    server
        .mock("GET", "/v1/secret/data/forbidden")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(403)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("error_permission_denied"))
        .create();

    let c = client(&server);
    let err = c
        .read_secret("secret", "forbidden")
        .expect_err("should fail");
    let msg = err.to_string();
    assert!(
        msg.contains("permission denied"),
        "unexpected error: {msg}"
    );
}

#[test]
fn search_reads_fixture_secrets() {
    let mut server = Server::new();

    server
        .mock("LIST", "/v1/secret/metadata")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("list_secrets_root"))
        .create();

    // Folder recursion for apps/
    server
        .mock("LIST", "/v1/secret/metadata/apps")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("list_secrets_apps"))
        .create();

    // staging/ is empty in this fixture set
    server
        .mock("LIST", "/v1/secret/metadata/apps/staging")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(404)
        .with_body(r#"{"errors":["not found"]}"#)
        .create();
    server
        .mock("GET", "/v1/secret/metadata/apps/staging")
        .match_query(Matcher::UrlEncoded("list".into(), "true".into()))
        .with_status(404)
        .with_body(r#"{"errors":["not found"]}"#)
        .create();

    // database/ folder — treat as empty
    server
        .mock("LIST", "/v1/secret/metadata/database")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(404)
        .with_body(r#"{"errors":["not found"]}"#)
        .create();
    server
        .mock("GET", "/v1/secret/metadata/database")
        .match_query(Matcher::UrlEncoded("list".into(), "true".into()))
        .with_status(404)
        .with_body(r#"{"errors":["not found"]}"#)
        .create();

    server
        .mock("GET", "/v1/secret/data/ai-api-keys")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("read_secret_ai_api_keys"))
        .create();

    server
        .mock("GET", "/v1/secret/data/apps/baogui")
        .match_header("X-Vault-Token", FIXTURE_TOKEN)
        .with_status(200)
        .with_header(json_header().0, json_header().1)
        .with_body(fixture("read_secret_apps_baogui"))
        .create();

    let c = client(&server);
    let mut index = baogui::api::SearchIndex::default();
    let hits = c
        .search_secrets("secret", "openai", &mut index)
        .expect("search");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].path, "ai-api-keys");
    assert_eq!(hits[0].key, "OPENAI_API_KEY");

    let hits = c
        .search_secrets("secret", "postgres", &mut index)
        .expect("search db url");
    assert!(hits.iter().any(|h| h.path == "apps/baogui" && h.key == "DATABASE_URL"));
}
