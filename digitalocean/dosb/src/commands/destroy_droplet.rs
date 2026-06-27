use anyhow::Result;
use dialoguer::{theme::ColorfulTheme, Input};

use crate::api::Client;
use crate::cli::DestroyDropletArgs;
use crate::commands::common;
use crate::config::Config;
use crate::ui;

pub fn run(
    client: &Client,
    config: &Config,
    args: &DestroyDropletArgs,
    dry_run: bool,
) -> Result<()> {
    let droplet = common::resolve_droplet(
        client,
        config,
        args.droplet.as_deref(),
        "Select a droplet to destroy",
    )?;

    if dry_run {
        ui::dry_run(&format!(
            "Would destroy droplet `{}` (id {}, {}, {}).",
            droplet.name,
            droplet.id,
            droplet.region.slug,
            droplet.public_ipv4().unwrap_or("no-ip"),
        ));
        return Ok(());
    }

    ui::warn(&format!(
        "About to PERMANENTLY destroy `{}` (id {}, {}, {})",
        droplet.name,
        droplet.id,
        droplet.region.slug,
        droplet.public_ipv4().unwrap_or("no-ip"),
    ));

    // Irreversible: require typing the exact droplet name to confirm.
    let typed: String = Input::with_theme(&ColorfulTheme::default())
        .with_prompt(format!("Type the droplet name `{}` to confirm", droplet.name))
        .allow_empty(true)
        .interact_text()?;

    if typed.trim() != droplet.name {
        ui::info("Name did not match — aborted. Nothing was destroyed.");
        return Ok(());
    }

    client.delete_droplet(droplet.id)?;
    ui::success(&format!("Destroyed `{}`.", droplet.name));
    Ok(())
}
