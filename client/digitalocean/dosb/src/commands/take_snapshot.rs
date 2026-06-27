use std::time::Duration;

use anyhow::Result;
use dialoguer::{theme::ColorfulTheme, Confirm};

use crate::api::Client;
use crate::cli::TakeSnapshotArgs;
use crate::commands::common;
use crate::config::Config;
use crate::ui;

const POWER_TIMEOUT: Duration = Duration::from_secs(120);
const SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(1800);

pub fn run(
    client: &Client,
    config: &Config,
    args: &TakeSnapshotArgs,
    dry_run: bool,
) -> Result<()> {
    let droplet = common::resolve_droplet(
        client,
        config,
        args.droplet.as_deref(),
        "Select a droplet to snapshot",
    )?;

    let snapshot_name = common::generate_name(&config.snapshot_prefix, args.label.as_deref());

    if dry_run {
        let power = if args.live {
            "without powering it off (--live)"
        } else if args.keep_running {
            "after powering it off, then power it back on (--keep-running)"
        } else {
            "after powering it off, leaving it off"
        };
        ui::dry_run(&format!(
            "Would take snapshot `{snapshot_name}` of droplet `{}` (id {}) {power}.",
            droplet.name, droplet.id
        ));
        return Ok(());
    }

    // Confirmation: snapshotting powers the box off (unless --live), which is
    // disruptive even though it isn't destructive.
    if !args.yes {
        let prompt = if args.live {
            format!("Take a live snapshot `{snapshot_name}` of `{}`?", droplet.name)
        } else {
            format!(
                "This will power off `{}` and take a snapshot `{snapshot_name}` (a few minutes). Continue?",
                droplet.name
            )
        };
        let ok = Confirm::with_theme(&ColorfulTheme::default())
            .with_prompt(prompt)
            .default(false)
            .interact()?;
        if !ok {
            ui::info("Aborted.");
            return Ok(());
        }
    }

    // Power off unless a live snapshot was requested.
    if !args.live {
        ui::info(&format!("Powering off `{}`...", droplet.name));
        let action = client.power_off(droplet.id)?;
        common::wait_for_action(client, droplet.id, &action, "power-off", POWER_TIMEOUT)?;
        ui::success("Droplet powered off.");
    }

    ui::info(&format!(
        "Taking snapshot `{snapshot_name}` (this can take several minutes)..."
    ));
    let action = client.snapshot(droplet.id, &snapshot_name)?;
    common::wait_for_action(client, droplet.id, &action, "snapshot", SNAPSHOT_TIMEOUT)?;
    ui::success(&format!("Snapshot `{snapshot_name}` created."));

    // Power state afterward: leave off by default; power back on with --keep-running.
    if args.keep_running && !args.live {
        ui::info("Powering the droplet back on (--keep-running)...");
        let action = client.power_on(droplet.id)?;
        common::wait_for_action(client, droplet.id, &action, "power-on", POWER_TIMEOUT)?;
        ui::success("Droplet powered back on.");
    } else if !args.live {
        ui::info(&format!(
            "Droplet `{}` left powered off. Destroy it with `dosb destroy-droplet {}`.",
            droplet.name, droplet.name
        ));
    }

    Ok(())
}
