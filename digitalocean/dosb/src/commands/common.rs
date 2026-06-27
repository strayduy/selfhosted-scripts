//! Shared helpers across commands: name generation, ephemeral-droplet
//! resolution/selection, and action/status polling.

use std::thread::sleep;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use chrono::Utc;
use dialoguer::{theme::ColorfulTheme, Select};

use crate::api::{Action, Client, Droplet, Image};
use crate::config::Config;
use crate::ui;

/// UTC timestamp suffix used in generated droplet/snapshot names, e.g.
/// `20260627T1430Z`.
pub fn timestamp() -> String {
    Utc::now().format("%Y%m%dT%H%MZ").to_string()
}

/// Build a `sandbox-<label>-<timestamp>` style name from the configured prefix.
pub fn generate_name(prefix: &str, label: Option<&str>) -> String {
    match label.map(str::trim).filter(|s| !s.is_empty()) {
        Some(label) => format!("{prefix}{label}-{}", timestamp()),
        None => format!("{prefix}{}", timestamp()),
    }
}

/// Fetch all ephemeral droplets (those carrying the configured tag).
pub fn ephemeral_droplets(client: &Client, config: &Config) -> Result<Vec<Droplet>> {
    let mut droplets = client.list_droplets_by_tag(&config.tag)?;
    droplets.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(droplets)
}

/// Resolve a droplet for an action: by explicit name/ID argument, or via an
/// interactive picker. Only ephemeral (tagged) droplets are ever considered, so
/// the safety rail holds regardless of which path is taken.
pub fn resolve_droplet(
    client: &Client,
    config: &Config,
    selector: Option<&str>,
    prompt: &str,
) -> Result<Droplet> {
    let droplets = ephemeral_droplets(client, config)?;
    if droplets.is_empty() {
        bail!(
            "no droplets tagged `{}` were found — nothing to act on",
            config.tag
        );
    }

    if let Some(sel) = selector {
        return match_one(droplets, sel, &config.tag);
    }

    let items: Vec<String> = droplets
        .iter()
        .map(|d| {
            format!(
                "{}  ({}, {}, {})",
                d.name,
                d.region.slug,
                d.status,
                d.public_ipv4().unwrap_or("no-ip")
            )
        })
        .collect();
    let idx = Select::with_theme(&ColorfulTheme::default())
        .with_prompt(prompt)
        .items(&items)
        .default(0)
        .interact()?;
    Ok(droplets.into_iter().nth(idx).expect("valid index"))
}

/// Match a selector string against a droplet's exact name or numeric ID.
fn match_one(droplets: Vec<Droplet>, selector: &str, tag: &str) -> Result<Droplet> {
    let by_id = selector.parse::<u64>().ok();
    let mut matches: Vec<Droplet> = droplets
        .into_iter()
        .filter(|d| d.name == selector || Some(d.id) == by_id)
        .collect();

    match matches.len() {
        0 => bail!(
            "no droplet tagged `{tag}` matches `{selector}`\n\
             (only ephemeral droplets can be targeted)"
        ),
        1 => Ok(matches.remove(0)),
        _ => bail!("`{selector}` matches multiple droplets — target by ID instead"),
    }
}

/// Snapshots whose name starts with the configured prefix, newest first.
pub fn sandbox_snapshots(client: &Client, config: &Config) -> Result<Vec<Image>> {
    let mut snaps: Vec<Image> = client
        .list_snapshots()?
        .into_iter()
        .filter(|img| img.name.starts_with(&config.snapshot_prefix))
        .collect();
    snaps.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(snaps)
}

/// Poll a droplet action until it completes or errors, with an overall timeout.
pub fn wait_for_action(
    client: &Client,
    droplet_id: u64,
    action: &Action,
    what: &str,
    timeout: Duration,
) -> Result<()> {
    let start = Instant::now();
    loop {
        let current = client.get_action(droplet_id, action.id)?;
        match current.status.as_str() {
            "completed" => return Ok(()),
            "errored" => bail!("{what} action errored on DigitalOcean's side"),
            _ => {}
        }
        if start.elapsed() > timeout {
            bail!("timed out waiting for {what} to complete");
        }
        sleep(Duration::from_secs(3));
    }
}

/// Poll a droplet until it reports `active` and has a public IPv4, returning the
/// fully-populated droplet.
pub fn wait_for_active(client: &Client, droplet_id: u64, timeout: Duration) -> Result<Droplet> {
    let start = Instant::now();
    loop {
        let droplet = client.get_droplet(droplet_id)?;
        if droplet.status == "active" && droplet.public_ipv4().is_some() {
            return Ok(droplet);
        }
        if start.elapsed() > timeout {
            return Err(anyhow!(
                "droplet did not become active within {}s (current status: {})",
                timeout.as_secs(),
                droplet.status
            ));
        }
        sleep(Duration::from_secs(3));
    }
}

/// Print a "none found" notice consistently.
pub fn none_found(what: &str) {
    ui::info(&format!("No {what} found."));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamp_is_compact_utc() {
        let ts = timestamp();
        // e.g. 20260627T1430Z -> 8 digits, 'T', 4 digits, 'Z'
        assert_eq!(ts.len(), 14, "unexpected timestamp: {ts}");
        assert!(ts.ends_with('Z'));
        assert_eq!(ts.as_bytes()[8], b'T');
        assert!(ts[..8].chars().all(|c| c.is_ascii_digit()));
        assert!(ts[9..13].chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn generate_name_with_label() {
        let name = generate_name("sandbox-", Some("myproject"));
        assert!(name.starts_with("sandbox-myproject-"));
        // prefix + label + '-' + 14-char timestamp
        assert_eq!(name.len(), "sandbox-myproject-".len() + 14);
    }

    #[test]
    fn generate_name_without_label() {
        let name = generate_name("sandbox-", None);
        assert!(name.starts_with("sandbox-"));
        assert!(!name["sandbox-".len()..].starts_with('-'));
        assert_eq!(name.len(), "sandbox-".len() + 14);
    }

    #[test]
    fn generate_name_treats_blank_label_as_none() {
        let blank = generate_name("sandbox-", Some("   "));
        let none = generate_name("sandbox-", None);
        assert_eq!(blank.len(), none.len());
        assert!(!blank["sandbox-".len()..].starts_with('-'));
    }

    #[test]
    fn generate_name_respects_custom_prefix() {
        let name = generate_name("sbx_", Some("x"));
        assert!(name.starts_with("sbx_x-"));
    }
}
