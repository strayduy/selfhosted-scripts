use std::path::PathBuf;

use clap::{Args, Parser, Subcommand};

/// Manage ephemeral DigitalOcean sandbox droplets.
#[derive(Debug, Parser)]
#[command(name = "dosb", version, about, long_about = None)]
pub struct Cli {
    /// Path to the config file (overrides $DOSB_CONFIG and the default location).
    #[arg(long, global = true, env = "DOSB_CONFIG")]
    pub config: Option<PathBuf>,

    /// Perform read-only lookups and validation, but make no changes; print
    /// what would happen instead.
    #[arg(long, global = true)]
    pub dry_run: bool,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Interactive first-run setup; writes the config file.
    Init(InitArgs),

    /// Create an ephemeral droplet from a sandbox snapshot.
    CreateDroplet(CreateDropletArgs),

    /// List current ephemeral droplets.
    ListDroplets(ListDropletsArgs),

    /// List available sandbox snapshots.
    ListSnapshots(ListSnapshotsArgs),

    /// Take a snapshot of an ephemeral droplet.
    TakeSnapshot(TakeSnapshotArgs),

    /// Destroy an ephemeral droplet.
    DestroyDroplet(DestroyDropletArgs),

    /// SSH into an ephemeral droplet.
    ConnectDroplet(ConnectDropletArgs),
}

#[derive(Debug, Args)]
pub struct InitArgs {
    /// Overwrite an existing config file without prompting.
    #[arg(long)]
    pub force: bool,
}

#[derive(Debug, Args)]
pub struct CreateDropletArgs {
    /// Snapshot name or ID to boot from (skips the interactive picker).
    #[arg(long)]
    pub snapshot: Option<String>,

    /// Droplet size slug (overrides the configured default).
    #[arg(long)]
    pub size: Option<String>,

    /// Full droplet name (overrides the generated name).
    #[arg(long, conflicts_with = "label")]
    pub name: Option<String>,

    /// Optional label inserted into the generated droplet name.
    #[arg(long)]
    pub label: Option<String>,
}

#[derive(Debug, Args)]
pub struct ListDropletsArgs {}

#[derive(Debug, Args)]
pub struct ListSnapshotsArgs {}

#[derive(Debug, Args)]
pub struct TakeSnapshotArgs {
    /// Droplet name or ID to snapshot (skips the interactive picker).
    pub droplet: Option<String>,

    /// Optional label inserted into the generated snapshot name.
    #[arg(long)]
    pub label: Option<String>,

    /// Skip the confirmation prompt.
    #[arg(long, short = 'y')]
    pub yes: bool,

    /// Power the droplet back on after the snapshot completes.
    #[arg(long, conflicts_with = "live")]
    pub keep_running: bool,

    /// Snapshot the running droplet without powering it off (faster, riskier).
    #[arg(long)]
    pub live: bool,
}

#[derive(Debug, Args)]
pub struct DestroyDropletArgs {
    /// Droplet name or ID to destroy (skips the interactive picker).
    pub droplet: Option<String>,
}

#[derive(Debug, Args)]
pub struct ConnectDropletArgs {
    /// Droplet name or ID to connect to (skips the interactive picker).
    pub droplet: Option<String>,

    /// SSH login user (overrides the configured default).
    #[arg(long)]
    pub user: Option<String>,

    /// SSH port (overrides the configured default).
    #[arg(long)]
    pub port: Option<u16>,

    /// SSH identity file (overrides the configured default).
    #[arg(long)]
    pub identity_file: Option<String>,
}
