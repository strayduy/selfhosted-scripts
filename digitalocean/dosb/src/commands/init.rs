use std::path::Path;

use anyhow::{Context, Result};
use dialoguer::{theme::ColorfulTheme, Confirm, Input};

use crate::cli::InitArgs;
use crate::config::{defaults, Config, ConfigFile};
use crate::ui;

pub fn run(args: &InitArgs, config_override: Option<&Path>) -> Result<()> {
    let path = Config::path(config_override)?;
    let theme = ColorfulTheme::default();

    if path.exists() && !args.force {
        let overwrite = Confirm::with_theme(&theme)
            .with_prompt(format!("{} already exists — overwrite?", path.display()))
            .default(false)
            .interact()?;
        if !overwrite {
            ui::info("Leaving existing config untouched.");
            return Ok(());
        }
    }

    ui::info("Setting up dosb. Required values have no default and must be entered.");

    let region: String = Input::with_theme(&theme)
        .with_prompt("DigitalOcean region slug (e.g. sfo3) [required]")
        .validate_with(non_empty)
        .interact_text()?;

    let ssh_key_name: String = Input::with_theme(&theme)
        .with_prompt("DO-registered SSH key name to inject [required]")
        .validate_with(non_empty)
        .interact_text()?;

    let size: String = Input::with_theme(&theme)
        .with_prompt("Default droplet size slug")
        .default(defaults::size().to_string())
        .interact_text()?;

    let tag: String = Input::with_theme(&theme)
        .with_prompt("Tag applied to ephemeral droplets")
        .default(defaults::tag().to_string())
        .interact_text()?;

    let snapshot_prefix: String = Input::with_theme(&theme)
        .with_prompt("Snapshot/droplet name prefix")
        .default(defaults::snapshot_prefix().to_string())
        .interact_text()?;

    let ssh_user: String = Input::with_theme(&theme)
        .with_prompt("SSH login user")
        .default(defaults::ssh_user().to_string())
        .interact_text()?;

    let ssh_port: u16 = Input::with_theme(&theme)
        .with_prompt("SSH port")
        .default(defaults::ssh_port())
        .interact_text()?;

    let identity_file: String = Input::with_theme(&theme)
        .with_prompt("SSH identity file")
        .default(defaults::identity_file().to_string())
        .interact_text()?;

    let file = ConfigFile {
        region: Some(region),
        size: Some(size),
        ssh_key_name: Some(ssh_key_name),
        tag: Some(tag),
        snapshot_prefix: Some(snapshot_prefix),
        ssh_user: Some(ssh_user),
        ssh_port: Some(ssh_port),
        identity_file: Some(identity_file),
    };

    let toml = toml::to_string_pretty(&file).context("serializing config")?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating config directory {}", parent.display()))?;
    }
    std::fs::write(&path, toml).with_context(|| format!("writing config {}", path.display()))?;

    ui::success(&format!("Wrote config to {}", path.display()));
    ui::info("Remember to export your API token: export DIGITALOCEAN_ACCESS_TOKEN=...");
    Ok(())
}

// dialoguer's `validate_with` passes the value as `&String`; keep that signature.
#[allow(clippy::ptr_arg)]
fn non_empty(input: &String) -> Result<(), String> {
    if input.trim().is_empty() {
        return Err("a value is required".to_string());
    }
    Ok(())
}
