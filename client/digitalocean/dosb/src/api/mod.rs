//! Minimal typed client for the slice of the DigitalOcean v2 API that dosb
//! needs: droplets, snapshots (images), SSH keys, and droplet actions.

mod models;

use std::thread::sleep;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use reqwest::blocking::{Client as HttpClient, RequestBuilder, Response};
use reqwest::StatusCode;
use serde::de::DeserializeOwned;
use serde_json::json;

pub use models::{Action, Droplet, Image, SshKey};

use crate::config::Config;

const API_BASE: &str = "https://api.digitalocean.com/v2";
const TOKEN_ENV: &str = "DIGITALOCEAN_ACCESS_TOKEN";
const MAX_RETRIES: u32 = 4;

pub struct Client {
    http: HttpClient,
    token: String,
}

impl Client {
    /// Build a client, reading the API token from the environment. The token is
    /// never sourced from the config file.
    pub fn from_env(_config: &Config) -> Result<Client> {
        let token = std::env::var(TOKEN_ENV).map_err(|_| {
            anyhow!(
                "the {TOKEN_ENV} environment variable is not set\n\
                 Export your DigitalOcean API token, e.g.:\n  \
                 export {TOKEN_ENV}=dop_v1_..."
            )
        })?;
        if token.trim().is_empty() {
            bail!("{TOKEN_ENV} is set but empty");
        }
        let http = HttpClient::builder()
            .user_agent(concat!("dosb/", env!("CARGO_PKG_VERSION")))
            .build()
            .context("building HTTP client")?;
        Ok(Client { http, token })
    }

    // ── HTTP plumbing ────────────────────────────────────────────────────────

    fn send(&self, op: &str, build: impl Fn() -> RequestBuilder) -> Result<Response> {
        let mut attempt = 0;
        loop {
            let resp = build()
                .bearer_auth(&self.token)
                .send()
                .with_context(|| format!("sending request to the DigitalOcean API ({op})"))?;
            let status = resp.status();

            // Retry on rate-limit / transient server errors with simple backoff.
            if (status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error())
                && attempt < MAX_RETRIES
            {
                attempt += 1;
                let backoff = Duration::from_millis(500 * 2u64.pow(attempt - 1));
                sleep(backoff);
                continue;
            }

            if status == StatusCode::UNAUTHORIZED {
                bail!(
                    "DigitalOcean API returned 401 Unauthorized while trying to {op} — \
                     check that {TOKEN_ENV} is valid and not expired"
                );
            }
            if status == StatusCode::FORBIDDEN {
                let body = resp.text().unwrap_or_default();
                bail!(
                    "DigitalOcean API error (403 Forbidden) while trying to {op}: {}\n\
                     This usually means the API token in {TOKEN_ENV} is missing a required \
                     scope for this operation. Check that the token has the scopes needed \
                     to {op}.",
                    api_message(&body)
                );
            }
            if !status.is_success() {
                let body = resp.text().unwrap_or_default();
                bail!(
                    "DigitalOcean API error ({status}) while trying to {op}: {}",
                    api_message(&body)
                );
            }
            return Ok(resp);
        }
    }

    fn get_json<T: DeserializeOwned>(&self, op: &str, path: &str) -> Result<T> {
        let url = format!("{API_BASE}{path}");
        let resp = self.send(op, || self.http.get(&url))?;
        resp.json()
            .with_context(|| format!("decoding API response ({op})"))
    }

    fn post_json<T: DeserializeOwned>(
        &self,
        op: &str,
        path: &str,
        body: serde_json::Value,
    ) -> Result<T> {
        let url = format!("{API_BASE}{path}");
        let resp = self.send(op, || self.http.post(&url).json(&body))?;
        resp.json()
            .with_context(|| format!("decoding API response ({op})"))
    }

    // ── Droplets ─────────────────────────────────────────────────────────────

    /// List droplets carrying the given tag.
    pub fn list_droplets_by_tag(&self, tag: &str) -> Result<Vec<Droplet>> {
        let mut out = Vec::new();
        let mut page = format!("/droplets?tag_name={tag}&per_page=200");
        loop {
            let resp: models::DropletsResponse =
                self.get_json("list droplets by tag", &page)?;
            out.extend(resp.droplets);
            match resp.links.next_page_path() {
                Some(next) => page = next,
                None => break,
            }
        }
        Ok(out)
    }

    pub fn get_droplet(&self, id: u64) -> Result<Droplet> {
        let resp: models::DropletResponse =
            self.get_json("get droplet", &format!("/droplets/{id}"))?;
        Ok(resp.droplet)
    }

    /// Create a droplet. Returns the created droplet (still booting).
    pub fn create_droplet(
        &self,
        name: &str,
        region: &str,
        size: &str,
        image_id: u64,
        ssh_key_ids: &[u64],
        tags: &[&str],
    ) -> Result<Droplet> {
        let body = json!({
            "name": name,
            "region": region,
            "size": size,
            "image": image_id,
            "ssh_keys": ssh_key_ids,
            "tags": tags,
            "backups": false,
            "ipv6": false,
            "monitoring": false,
        });
        let resp: models::DropletResponse =
            self.post_json("create droplet", "/droplets", body)?;
        Ok(resp.droplet)
    }

    pub fn delete_droplet(&self, id: u64) -> Result<()> {
        let url = format!("{API_BASE}/droplets/{id}");
        self.send("delete droplet", || self.http.delete(&url))?;
        Ok(())
    }

    // ── Droplet actions ──────────────────────────────────────────────────────

    pub fn power_off(&self, id: u64) -> Result<Action> {
        self.droplet_action(id, json!({ "type": "power_off" }))
    }

    pub fn power_on(&self, id: u64) -> Result<Action> {
        self.droplet_action(id, json!({ "type": "power_on" }))
    }

    /// Take a named snapshot of the droplet. Returns the in-progress action.
    pub fn snapshot(&self, id: u64, name: &str) -> Result<Action> {
        self.droplet_action(id, json!({ "type": "snapshot", "name": name }))
    }

    fn droplet_action(&self, id: u64, body: serde_json::Value) -> Result<Action> {
        let resp: models::ActionResponse =
            self.post_json("perform droplet action", &format!("/droplets/{id}/actions"), body)?;
        Ok(resp.action)
    }

    pub fn get_action(&self, droplet_id: u64, action_id: u64) -> Result<Action> {
        let resp: models::ActionResponse = self.get_json(
            "get droplet action",
            &format!("/droplets/{droplet_id}/actions/{action_id}"),
        )?;
        Ok(resp.action)
    }

    // ── Snapshots (images) ───────────────────────────────────────────────────

    /// List private snapshot images owned by the account.
    pub fn list_snapshots(&self) -> Result<Vec<Image>> {
        let mut out = Vec::new();
        let mut page = String::from("/images?private=true&type=snapshot&per_page=200");
        loop {
            let resp: models::ImagesResponse = self.get_json("list snapshots", &page)?;
            out.extend(resp.images);
            match resp.links.next_page_path() {
                Some(next) => page = next,
                None => break,
            }
        }
        Ok(out)
    }

    // ── SSH keys ─────────────────────────────────────────────────────────────

    pub fn list_ssh_keys(&self) -> Result<Vec<SshKey>> {
        let resp: models::SshKeysResponse =
            self.get_json("list SSH keys", "/account/keys?per_page=200")?;
        Ok(resp.ssh_keys)
    }

    /// Resolve a DO-registered SSH key by its name to its numeric ID.
    pub fn ssh_key_id_by_name(&self, name: &str) -> Result<u64> {
        let keys = self.list_ssh_keys()?;
        keys.into_iter()
            .find(|k| k.name == name)
            .map(|k| k.id)
            .ok_or_else(|| anyhow!("no DigitalOcean SSH key named `{name}` was found"))
    }
}

/// Pull a human-readable `message` out of a DO error body, falling back to the
/// raw body if it isn't the expected shape.
fn api_message(body: &str) -> String {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("message").and_then(|m| m.as_str()).map(String::from))
        .unwrap_or_else(|| body.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::api_message;

    #[test]
    fn extracts_message_field_from_error_body() {
        let body = r#"{"id":"not_found","message":"The resource you requested could not be found."}"#;
        assert_eq!(
            api_message(body),
            "The resource you requested could not be found."
        );
    }

    #[test]
    fn falls_back_to_raw_body_when_not_json() {
        assert_eq!(api_message("  upstream timeout  "), "upstream timeout");
    }

    #[test]
    fn falls_back_when_json_lacks_message() {
        let body = r#"{"id":"unprocessable_entity"}"#;
        assert_eq!(api_message(body), body);
    }
}
