use std::net::{TcpStream, ToSocketAddrs};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};

use crate::api::Client;
use crate::cli::ConnectDropletArgs;
use crate::commands::common;
use crate::config::Config;
use crate::ssh_agent;
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

    let forward_socket = if args.no_forward_agent {
        None
    } else {
        prepare_github_agent(config, dry_run)
    };

    let mut ssh_args: Vec<String> = vec!["-i".into(), identity, "-p".into(), port.to_string()];
    if let Some(socket) = &forward_socket {
        // ForwardAgent=<path> forwards only the dedicated GitHub agent; the
        // default agent ($SSH_AUTH_SOCK) still authenticates us to the droplet.
        ssh_args.push("-o".into());
        ssh_args.push(format!("ForwardAgent={}", socket.display()));
    }
    ssh_args.push(format!("{user}@{ip}"));

    if dry_run {
        ui::dry_run(&format!("Would connect: ssh {}", ssh_args.join(" ")));
        return Ok(());
    }

    // Bounded readiness probe: sshd may still be coming up right after boot.
    wait_for_ssh(&ip, port, SSH_READY_TIMEOUT)?;

    ui::info(&format!("Connecting to {user}@{ip} (port {port})..."));

    // Replace this process with ssh so the user lands directly in the shell.
    let err = Command::new("ssh").args(&ssh_args).exec();

    // exec only returns on failure.
    Err(anyhow!("failed to exec ssh: {err}"))
}

/// Make sure the dedicated GitHub agent is running and holds the GitHub key,
/// returning its socket path to forward. Any problem is a warning, not an
/// error: a broken GitHub setup must never stop us from reaching the droplet.
fn prepare_github_agent(config: &Config, dry_run: bool) -> Option<PathBuf> {
    let key = ssh_agent::expand(&config.github_identity_file);
    let socket = ssh_agent::expand(&config.github_agent_socket);

    if !key.exists() {
        ui::warn(&format!(
            "GitHub key {} not found — connecting without agent forwarding. \
             Run `fleeting setup-github` to set it up.",
            key.display()
        ));
        return None;
    }

    if dry_run {
        let fpr = ssh_agent::fingerprint(&key);
        let state = fpr.and_then(|f| ssh_agent::state(&socket, &f));
        let action = match state {
            Ok(ssh_agent::AgentState::Loaded) => "use the already-loaded GitHub key".to_string(),
            Ok(ssh_agent::AgentState::Missing) => {
                format!("load {} for {}", key.display(), ssh_agent::KEY_LIFETIME)
            }
            Ok(ssh_agent::AgentState::NotRunning) => format!(
                "start an agent on {} and load {} for {}",
                socket.display(),
                key.display(),
                ssh_agent::KEY_LIFETIME
            ),
            Err(e) => format!("fail to inspect the agent ({e:#}) and connect without forwarding"),
        };
        ui::dry_run(&format!("Would {action}."));
        return Some(socket);
    }

    match ssh_agent::ensure(&socket, &key) {
        Ok(what) => {
            ui::info(&format!(
                "GitHub agent: {what}; forwarding {}",
                socket.display()
            ));
            Some(socket)
        }
        Err(e) => {
            ui::warn(&format!(
                "could not prepare the GitHub agent ({e:#}) — connecting without agent forwarding"
            ));
            None
        }
    }
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
