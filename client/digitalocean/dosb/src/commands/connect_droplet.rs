use std::net::{TcpStream, ToSocketAddrs};
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};

use crate::api::Client;
use crate::cli::ConnectDropletArgs;
use crate::commands::common;
use crate::config::Config;
use crate::ui;

const SSH_READY_TIMEOUT: Duration = Duration::from_secs(30);

pub fn run(
    client: &Client,
    config: &Config,
    args: &ConnectDropletArgs,
    dry_run: bool,
) -> Result<()> {
    let droplet = common::resolve_droplet(
        client,
        config,
        args.droplet.as_deref(),
        "Select a droplet to connect to",
    )?;

    let ip = droplet
        .public_ipv4()
        .ok_or_else(|| anyhow!("droplet `{}` has no public IPv4 address yet", droplet.name))?
        .to_string();

    let user = args.user.clone().unwrap_or_else(|| config.ssh_user.clone());
    let port = args.port.unwrap_or(config.ssh_port);
    let identity_raw = args
        .identity_file
        .clone()
        .unwrap_or_else(|| config.identity_file.clone());
    let identity = shellexpand::tilde(&identity_raw).into_owned();

    if dry_run {
        ui::dry_run(&format!(
            "Would connect: ssh -i {identity} -p {port} {user}@{ip}"
        ));
        return Ok(());
    }

    // Bounded readiness probe: sshd may still be coming up right after boot.
    wait_for_ssh(&ip, port, SSH_READY_TIMEOUT)?;

    ui::info(&format!("Connecting to {user}@{ip} (port {port})..."));

    // Replace this process with ssh so the user lands directly in the shell.
    let err = Command::new("ssh")
        .arg("-i")
        .arg(&identity)
        .arg("-p")
        .arg(port.to_string())
        .arg(format!("{user}@{ip}"))
        .exec();

    // exec only returns on failure.
    Err(anyhow!("failed to exec ssh: {err}"))
}

/// Poll the TCP port until it accepts a connection or the timeout elapses.
fn wait_for_ssh(ip: &str, port: u16, timeout: Duration) -> Result<()> {
    let addr = (ip, port)
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| anyhow!("could not resolve {ip}:{port}"))?;

    let start = Instant::now();
    let mut announced = false;
    loop {
        match TcpStream::connect_timeout(&addr, Duration::from_secs(3)) {
            Ok(_) => return Ok(()),
            Err(_) if start.elapsed() < timeout => {
                if !announced {
                    ui::info("Waiting for SSH to become reachable...");
                    announced = true;
                }
                sleep(Duration::from_secs(2));
            }
            Err(e) => bail!("SSH port {port} on {ip} not reachable within {}s: {e}", timeout.as_secs()),
        }
    }
}
