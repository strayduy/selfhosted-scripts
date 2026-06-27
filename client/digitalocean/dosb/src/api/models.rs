//! Typed models for DigitalOcean API responses. Only the fields dosb uses are
//! deserialized; the rest are ignored.

use serde::Deserialize;

// ── Droplets ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct Droplet {
    pub id: u64,
    pub name: String,
    pub status: String,
    pub created_at: String,
    pub region: Region,
    pub size_slug: String,
    #[serde(default)]
    pub networks: Networks,
}

impl Droplet {
    /// First public IPv4 address, if the droplet has one yet.
    pub fn public_ipv4(&self) -> Option<&str> {
        self.networks
            .v4
            .iter()
            .find(|n| n.kind == "public")
            .map(|n| n.ip_address.as_str())
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Region {
    pub slug: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Networks {
    #[serde(default)]
    pub v4: Vec<Network>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Network {
    pub ip_address: String,
    #[serde(rename = "type")]
    pub kind: String,
}

#[derive(Debug, Deserialize)]
pub struct DropletResponse {
    pub droplet: Droplet,
}

#[derive(Debug, Deserialize)]
pub struct DropletsResponse {
    pub droplets: Vec<Droplet>,
    #[serde(default)]
    pub links: Links,
}

// ── Actions ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct Action {
    pub id: u64,
    /// One of: in-progress, completed, errored.
    pub status: String,
}

#[derive(Debug, Deserialize)]
pub struct ActionResponse {
    pub action: Action,
}

// ── Images / snapshots ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct Image {
    pub id: u64,
    pub name: String,
    pub created_at: String,
    #[serde(default)]
    pub regions: Vec<String>,
    /// Size of the image on disk, in gigabytes.
    #[serde(default)]
    pub size_gigabytes: f64,
}

#[derive(Debug, Deserialize)]
pub struct ImagesResponse {
    pub images: Vec<Image>,
    #[serde(default)]
    pub links: Links,
}

// ── SSH keys ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct SshKey {
    pub id: u64,
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct SshKeysResponse {
    pub ssh_keys: Vec<SshKey>,
}

// ── Pagination ───────────────────────────────────────────────────────────────

#[derive(Debug, Default, Deserialize)]
pub struct Links {
    #[serde(default)]
    pub pages: Option<Pages>,
}

#[derive(Debug, Deserialize)]
pub struct Pages {
    #[serde(default)]
    pub next: Option<String>,
}

impl Links {
    /// Return the path+query of the next page (stripping the API base), if any.
    pub fn next_page_path(&self) -> Option<String> {
        let next = self.pages.as_ref()?.next.as_ref()?;
        // The API returns absolute URLs; our client prepends the base, so strip it.
        match next.split_once("/v2") {
            Some((_, rest)) => Some(rest.to_string()),
            None => Some(next.clone()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn links_with(next: Option<&str>) -> Links {
        Links {
            pages: Some(Pages {
                next: next.map(String::from),
            }),
        }
    }

    #[test]
    fn next_page_strips_base_to_path() {
        let links = links_with(Some(
            "https://api.digitalocean.com/v2/droplets?tag_name=ephemeral&page=2&per_page=200",
        ));
        assert_eq!(
            links.next_page_path().as_deref(),
            Some("/droplets?tag_name=ephemeral&page=2&per_page=200")
        );
    }

    #[test]
    fn no_pages_means_no_next() {
        assert_eq!(Links::default().next_page_path(), None);
    }

    #[test]
    fn pages_without_next_means_no_next() {
        assert_eq!(links_with(None).next_page_path(), None);
    }

    #[test]
    fn droplet_public_ipv4_prefers_public_network() {
        let json = serde_json::json!({
            "id": 1,
            "name": "sandbox-x-20260627T1430Z",
            "status": "active",
            "created_at": "2026-06-27T14:30:00Z",
            "region": { "slug": "sfo3" },
            "size_slug": "s-2vcpu-4gb",
            "networks": { "v4": [
                { "ip_address": "10.0.0.5", "type": "private" },
                { "ip_address": "203.0.113.7", "type": "public" }
            ]}
        });
        let droplet: Droplet = serde_json::from_value(json).unwrap();
        assert_eq!(droplet.public_ipv4(), Some("203.0.113.7"));
    }

    #[test]
    fn droplet_without_public_ip_returns_none() {
        let json = serde_json::json!({
            "id": 1,
            "name": "sandbox-x",
            "status": "new",
            "created_at": "2026-06-27T14:30:00Z",
            "region": { "slug": "sfo3" },
            "size_slug": "s-1vcpu-1gb",
            "networks": { "v4": [] }
        });
        let droplet: Droplet = serde_json::from_value(json).unwrap();
        assert_eq!(droplet.public_ipv4(), None);
    }
}
