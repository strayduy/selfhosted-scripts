use anyhow::Result;

use crate::api::Client;
use crate::cli::ListSnapshotsArgs;
use crate::commands::common;
use crate::config::Config;
use crate::ui;

pub fn run(client: &Client, config: &Config, _args: &ListSnapshotsArgs) -> Result<()> {
    let snapshots = common::sandbox_snapshots(client, config)?;
    if snapshots.is_empty() {
        common::none_found(&format!(
            "snapshots with prefix `{}`",
            config.snapshot_prefix
        ));
        return Ok(());
    }

    let rows: Vec<Vec<String>> = snapshots
        .iter()
        .map(|s| {
            let available = s.regions.iter().any(|r| r == &config.region);
            let regions = if s.regions.is_empty() {
                "-".to_string()
            } else {
                s.regions.join(",")
            };
            vec![
                s.name.clone(),
                s.id.to_string(),
                format!("{:.0}", s.size_gigabytes),
                regions,
                if available { "yes" } else { "NO" }.to_string(),
                ui::age(&s.created_at),
            ]
        })
        .collect();

    ui::table(
        &[
            "NAME",
            "ID",
            "GB",
            "REGIONS",
            // Whether the snapshot can launch in the configured region.
            "IN-REGION",
            "AGE",
        ],
        &rows,
    );
    Ok(())
}
