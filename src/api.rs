//! Minimal OpenBao / Vault-compatible HTTP client for KV v2.

use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct Client {
    base_url: String,
    token: String,
    http: reqwest::blocking::Client,
}

#[derive(Debug)]
pub enum ApiError {
    Http(reqwest::Error),
    Status { code: u16, message: String },
    Parse(String),
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Http(e) => write!(f, "network error: {e}"),
            ApiError::Status { code, message } => write!(f, "HTTP {code}: {message}"),
            ApiError::Parse(e) => write!(f, "parse error: {e}"),
        }
    }
}

impl From<reqwest::Error> for ApiError {
    fn from(e: reqwest::Error) -> Self {
        ApiError::Http(e)
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Health {
    pub initialized: bool,
    pub sealed: bool,
    #[allow(dead_code)]
    pub version: Option<String>,
    #[allow(dead_code)]
    pub cluster_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SecretData {
    pub data: BTreeMap<String, String>,
    pub version: Option<u64>,
    pub created_time: Option<String>,
}

impl Client {
    pub fn new(address: &str, token: &str) -> Result<Self, ApiError> {
        let base_url = address.trim_end_matches('/').to_string();
        let http = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(15))
            .build()?;
        Ok(Self {
            base_url,
            token: token.trim().to_string(),
            http,
        })
    }

    fn url(&self, path: &str) -> String {
        let path = path.trim_start_matches('/');
        format!("{}/v1/{}", self.base_url, path)
    }

    fn request(
        &self,
        method: reqwest::Method,
        path: &str,
    ) -> reqwest::blocking::RequestBuilder {
        self.http
            .request(method, self.url(path))
            .header("X-Vault-Token", &self.token)
            .header("X-Vault-Request", "true")
    }

    fn send(&self, builder: reqwest::blocking::RequestBuilder) -> Result<Value, ApiError> {
        let response = builder.send()?;
        let status = response.status();
        let body = response.text().unwrap_or_default();

        if !status.is_success() {
            let message = extract_error_message(&body).unwrap_or_else(|| {
                if body.is_empty() {
                    status.canonical_reason().unwrap_or("error").to_string()
                } else {
                    body.chars().take(300).collect()
                }
            });
            return Err(ApiError::Status {
                code: status.as_u16(),
                message,
            });
        }

        if body.trim().is_empty() {
            return Ok(Value::Null);
        }

        serde_json::from_str(&body).map_err(|e| ApiError::Parse(e.to_string()))
    }

    /// Check server health (works with or without a valid token on many installs).
    pub fn health(&self) -> Result<Health, ApiError> {
        // sys/health returns non-2xx when sealed; still parse the body.
        let response = self
            .http
            .get(self.url("sys/health"))
            .header("X-Vault-Token", &self.token)
            .query(&[("standbyok", "true"), ("sealedcode", "200"), ("uninitcode", "200")])
            .send()?;

        let body = response.text().unwrap_or_default();
        serde_json::from_str(&body).map_err(|e| ApiError::Parse(format!("{e}: {body}")))
    }

    /// Validate the current token.
    pub fn lookup_self(&self) -> Result<Value, ApiError> {
        self.send(self.request(reqwest::Method::GET, "auth/token/lookup-self"))
    }

    /// List enabled secret engines; returns (path, type) pairs.
    pub fn list_mounts(&self) -> Result<Vec<(String, String)>, ApiError> {
        let value = self.send(self.request(reqwest::Method::GET, "sys/mounts"))?;
        let data = value
            .get("data")
            .cloned()
            .unwrap_or(value);

        let mut mounts = Vec::new();
        if let Some(obj) = data.as_object() {
            for (path, info) in obj {
                let engine_type = info
                    .get("type")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                mounts.push((path.trim_end_matches('/').to_string(), engine_type));
            }
        }
        mounts.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(mounts)
    }

    /// Prefer a KV v2 mount named "secret", else first kv mount.
    pub fn default_kv_mount(&self) -> Result<String, ApiError> {
        let mounts = self.list_mounts()?;
        let kv: Vec<_> = mounts
            .into_iter()
            .filter(|(_, t)| t == "kv" || t.starts_with("kv-"))
            .collect();

        if let Some((path, _)) = kv.iter().find(|(p, _)| p == "secret") {
            return Ok(path.clone());
        }
        kv.into_iter()
            .next()
            .map(|(p, _)| p)
            .ok_or_else(|| ApiError::Parse("no KV secrets engine found".into()))
    }

    /// LIST keys under a KV v2 mount path (folders end with `/`).
    pub fn list_secrets(&self, mount: &str, path: &str) -> Result<Vec<String>, ApiError> {
        let api_path = if path.is_empty() {
            format!("{}/metadata", mount.trim_end_matches('/'))
        } else {
            format!(
                "{}/metadata/{}",
                mount.trim_end_matches('/'),
                path.trim_matches('/')
            )
        };

        // OpenBao/Vault accept LIST or GET ?list=true. Prefer LIST; fall back on
        // 404/405 *or* an empty keys array with a successful alternate form.
        let value = match self.send(
            self.request(reqwest::Method::from_bytes(b"LIST").unwrap(), &api_path),
        ) {
            Ok(v) => v,
            Err(ApiError::Status { code, .. }) if code == 404 || code == 405 => {
                let builder = self
                    .request(reqwest::Method::GET, &api_path)
                    .query(&[("list", "true")]);
                match self.send(builder) {
                    Ok(v) => v,
                    Err(ApiError::Status { code: 404, .. }) => return Ok(Vec::new()),
                    Err(e) => return Err(e),
                }
            }
            Err(e) => return Err(e),
        };

        Ok(extract_list_keys(&value))
    }

    pub fn read_secret(&self, mount: &str, path: &str) -> Result<SecretData, ApiError> {
        let api_path = format!(
            "{}/data/{}",
            mount.trim_end_matches('/'),
            path.trim_matches('/')
        );
        let value = self.send(self.request(reqwest::Method::GET, &api_path))?;

        let data_map = value
            .pointer("/data/data")
            .and_then(|v| v.as_object())
            .cloned()
            .unwrap_or_default();

        let mut data = BTreeMap::new();
        for (k, v) in data_map {
            data.insert(k, value_to_string(&v));
        }

        let version = value
            .pointer("/data/metadata/version")
            .and_then(|v| v.as_u64());
        let created_time = value
            .pointer("/data/metadata/created_time")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        Ok(SecretData {
            data,
            version,
            created_time,
        })
    }

    pub fn write_secret(
        &self,
        mount: &str,
        path: &str,
        data: &BTreeMap<String, String>,
    ) -> Result<(), ApiError> {
        let api_path = format!(
            "{}/data/{}",
            mount.trim_end_matches('/'),
            path.trim_matches('/')
        );

        let mut map = Map::new();
        for (k, v) in data {
            map.insert(k.clone(), Value::String(v.clone()));
        }

        let body = json!({ "data": map });
        self.send(
            self.request(reqwest::Method::POST, &api_path)
                .json(&body),
        )?;
        Ok(())
    }

    /// Soft-delete the latest version of a secret (KV v2).
    #[allow(dead_code)]
    pub fn delete_secret(&self, mount: &str, path: &str) -> Result<(), ApiError> {
        let api_path = format!(
            "{}/data/{}",
            mount.trim_end_matches('/'),
            path.trim_matches('/')
        );
        self.send(self.request(reqwest::Method::DELETE, &api_path))?;
        Ok(())
    }

    /// Permanently remove key + all versions.
    pub fn destroy_secret(&self, mount: &str, path: &str) -> Result<(), ApiError> {
        let api_path = format!(
            "{}/metadata/{}",
            mount.trim_end_matches('/'),
            path.trim_matches('/')
        );
        self.send(self.request(reqwest::Method::DELETE, &api_path))?;
        Ok(())
    }
}

fn value_to_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

fn extract_list_keys(value: &Value) -> Vec<String> {
    // Standard: { "data": { "keys": ["a", "b/"] } }
    // Some proxies flatten one level; accept a few shapes.
    let arr = value
        .pointer("/data/keys")
        .or_else(|| value.pointer("/keys"))
        .and_then(|v| v.as_array());

    let mut keys: Vec<String> = arr
        .map(|a| {
            a.iter()
                .filter_map(|k| k.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();
    keys.sort();
    keys.dedup();
    keys
}

fn extract_error_message(body: &str) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    if let Some(errors) = value.get("errors").and_then(|e| e.as_array()) {
        let msgs: Vec<String> = errors
            .iter()
            .filter_map(|e| e.as_str().map(|s| s.to_string()))
            .collect();
        if !msgs.is_empty() {
            return Some(msgs.join("; "));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn extract_list_keys_standard() {
        let v = json!({"data": {"keys": ["ai-api-keys", "foo/"]}});
        assert_eq!(
            extract_list_keys(&v),
            vec!["ai-api-keys".to_string(), "foo/".to_string()]
        );
    }

    #[test]
    fn secret_data_pointer_shape() {
        let value = json!({
            "data": {
                "data": {
                    "ANNA_API_KEY": "x",
                    "ATLAS_API_KEY": "y"
                },
                "metadata": {
                    "version": 22,
                    "created_time": "2026-07-31T00:00:00Z"
                }
            }
        });
        let data_map = value
            .pointer("/data/data")
            .and_then(|v| v.as_object())
            .unwrap();
        assert_eq!(data_map.len(), 2);
        assert!(data_map.contains_key("ANNA_API_KEY"));
    }
}

#[cfg(test)]
mod live_tests {
    use super::*;

    /// `BAO_ADDR` + token required. Run: `cargo test live_read -- --ignored --nocapture`
    #[test]
    #[ignore = "live OpenBao network"]
    fn live_read_ai_api_keys() {
        let addr = std::env::var("BAO_ADDR").unwrap_or_else(|_| "https://openbao.boxd.sh".into());
        let token = std::env::var("BAO_TOKEN").unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap();
            std::fs::read_to_string(format!("{home}/.vault-token"))
                .expect("token")
                .trim()
                .to_string()
        });
        let c = Client::new(&addr, &token).unwrap();
        let keys = c.list_secrets("secret", "").expect("list");
        assert!(
            keys.iter().any(|k| k.trim_end_matches('/') == "ai-api-keys"),
            "keys={keys:?}"
        );
        let s = c.read_secret("secret", "ai-api-keys").expect("read");
        assert!(
            s.data.len() >= 5,
            "expected many fields, got {} {:?}",
            s.data.len(),
            s.data.keys().collect::<Vec<_>>()
        );
        eprintln!(
            "OK {} fields: {:?}",
            s.data.len(),
            s.data.keys().collect::<Vec<_>>()
        );
    }
}
