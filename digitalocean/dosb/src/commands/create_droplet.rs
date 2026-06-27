use std::time::Duration;

use anyhow::{bail, Result};
use dialoguer::{theme::ColorfulTheme, Select};

use crate::api::{Client, Image};
use crate::cli::CreateDropletArgs;
use crate::commands::common;
use crate::config::Config;
use crate::ui;

const ACTIVE_TIMEOUT: Duration = Duration::from_secs(180);

pub fn run(
    client: &Client,
    config: &Config,
    args: &CreateDropletArgs,
    dry_run: bool,
) -> Result<()> {
    // 1. Choose the snapshot (filtered strictly to the sandbox prefix).
    let snapshot = select_snapshot(client, config, args.snapshot.as_deref())?;

    // 2. Refuse to create if the snapshot can't launch in the configured region.
    if !snapshot.regions.iter().any(|r| r == &config.region) {
        bail!(
            "snapshot `{}` is not available in region `{}` (available in: {})\n\
             Distribute the snapshot to that region or pick another.",
            snapshot.name,
            config.region,
            if snapshot.regions.is_empty() {
                "none".to_string()
            } else {
                snapshot.regions.join(", ")
            }
        );
    }

    // 3. Resolve the SSH key to inject as a safety net.
    let ssh_key_id = client.ssh_key_id_by_name(&config.ssh_key_name)?;

    // 4. Determine the droplet name and size.
    let name = match &args.name {
        Some(n) => n.clone(),
        None => common::generate_name(&config.snapshot_prefix, args.label.as_deref()),
    };
    let size = args.size.clone().unwrap_or_else(|| config.size.clone());

    if dry_run {
        ui::dry_run(&format!(
            "Would create droplet `{name}` (size {size}, region {}) from snapshot `{}` (id {}), \
             injecting SSH key `{}`, tagged `{}`.",
            config.region, snapshot.name, snapshot.id, config.ssh_key_name, config.tag
        ));
        return Ok(());
    }

    ui::info(&format!(
        "Creating droplet `{name}` ({size}, {}) from snapshot `{}`...",
        config.region, snapshot.name
    ));

    // 5. Create and block until active.
    let created = client.create_droplet(
        &name,
        &config.region,
        &size,
        snapshot.id,
        &[ssh_key_id],
        &[config.tag.as_str()],
    )?;

    ui::info("Waiting for the droplet to become active...");
    let droplet = common::wait_for_active(client, created.id, ACTIVE_TIMEOUT)?;
    let ip = droplet.public_ipv4().unwrap_or("unknown");

    ui::success(&format!("Droplet `{}` is active at {ip}", droplet.name));
    println!();
    ui::info("Connect with:");
    println!(
        "  ssh -i {} -p {} {}@{}",
        config.identity_file, config.ssh_port, config.ssh_user, ip
    );
    println!("  dosb connect-droplet {}", droplet.name);
    Ok(())
}

fn select_snapshot(
    client: &Client,
    config: &Config,
    selector: Option<&str>,
) -> Result<Image> {
    let snapshots = common::sandbox_snapshots(client, config)?;
    if snapshots.is_empty() {
        bail!(
            "no snapshots with prefix `{}` were found to create from",
            config.snapshot_prefix
        );
    }

    if let Some(sel) = selector {
        let by_id = sel.parse::<u64>().ok();
        let mut matches: Vec<Image> = snapshots
            .into_iter()
            .filter(|s| s.name == sel || Some(s.id) == by_id)
            .collect();
        return match matches.len() {
            0 => bail!("no sandbox snapshot matches `{sel}`"),
            1 => Ok(matches.remove(0)),
            _ => bail!("`{sel}` matches multiple snapshots — target by ID instead"),
        };
    }

    let items: Vec<String> = snapshots
        .iter()
        .map(|s| {
            let available = s.regions.iter().any(|r| r == &config.region);
            format!(
                "{}  ({:.0} GB, {}){}",
                s.name,
                s.size_gigabytes,
                ui::age(&s.created_at),
                if available { "" } else { "  [not in region]" }
            )
        })
        .collect();
    let idx = Select::with_theme(&ColorfulTheme::default())
        .with_prompt("Select a snapshot to create from")
        .items(&items)
        .default(0)
        .interact()?;
    Ok(snapshots.into_iter().nth(idx).expect("valid index"))
}
