use anyhow::Result;

use crate::api::Client;
use crate::cli::ListDropletsArgs;
use crate::commands::common;
use crate::config::Config;
use crate::ui;

pub fn run(client: &Client, config: &Config, _args: &ListDropletsArgs) -> Result<()> {
    let droplets = common::ephemeral_droplets(client, config)?;
    if droplets.is_empty() {
        common::none_found(&format!("droplets tagged `{}`", config.tag));
        return Ok(());
    }

    let rows: Vec<Vec<String>> = droplets
        .iter()
        .map(|d| {
            vec![
                d.name.clone(),
                d.id.to_string(),
                d.region.slug.clone(),
                d.size_slug.clone(),
                d.public_ipv4().unwrap_or("-").to_string(),
                d.status.clone(),
                ui::age(&d.created_at),
            ]
        })
        .collect();

    ui::table(
        &["NAME", "ID", "REGION", "SIZE", "PUBLIC IP", "STATUS", "AGE"],
        &rows,
    );
    Ok(())
}
