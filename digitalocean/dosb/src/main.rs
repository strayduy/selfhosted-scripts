mod api;
mod cli;
mod commands;
mod config;
mod ui;

use anyhow::Result;
use clap::Parser;

use crate::cli::{Cli, Command};

fn main() {
    if let Err(err) = run() {
        // Surface the full error chain on a single, clearly-marked line.
        eprintln!("{} {:#}", ui::error_label(), err);
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();

    // `init` is special: it does not require an existing config or an API token.
    if let Command::Init(args) = &cli.command {
        return commands::init::run(args, cli.config.as_deref());
    }

    // Every other command needs a loaded config and an API client.
    let config = config::Config::load(cli.config.as_deref())?;
    let client = api::Client::from_env(&config)?;

    let dry_run = cli.dry_run;
    if dry_run {
        ui::warn("Dry-run mode: no changes will be made.");
    }

    match &cli.command {
        Command::Init(_) => unreachable!("handled above"),
        Command::CreateDroplet(args) => {
            commands::create_droplet::run(&client, &config, args, dry_run)
        }
        Command::ListDroplets(args) => commands::list_droplets::run(&client, &config, args),
        Command::ListSnapshots(args) => commands::list_snapshots::run(&client, &config, args),
        Command::TakeSnapshot(args) => {
            commands::take_snapshot::run(&client, &config, args, dry_run)
        }
        Command::DestroyDroplet(args) => {
            commands::destroy_droplet::run(&client, &config, args, dry_run)
        }
        Command::ConnectDroplet(args) => {
            commands::connect_droplet::run(&client, &config, args, dry_run)
        }
    }
}
