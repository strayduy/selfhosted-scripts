//! Helpers for the dedicated GitHub ssh-agent that `connect-droplet` forwards.
//!
//! The agent listens on its own socket (config `github_agent_socket`) and only
//! ever holds the GitHub key (config `github_identity_file`), so a forwarded
//! connection lets the droplet reach GitHub and nothing else. The user's
//! regular agent (`$SSH_AUTH_SOCK`) is left alone and still authenticates the
//! SSH connection to the droplet itself.

use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{anyhow, bail, Context, Result};

/// How long the key stays loaded after `ssh-add`. The key has no passphrase,
/// so this mainly ensures it isn't sitting in an agent for days.
pub const KEY_LIFETIME: &str = "8h";

/// Expand a leading `~` in a config path.
pub fn expand(path: &str) -> PathBuf {
    PathBuf::from(shellexpand::tilde(path).into_owned())
}

/// Path of the public half of a private key (`<key>.pub`).
pub fn public_key_path(private: &Path) -> PathBuf {
    let mut s = private.as_os_str().to_owned();
    s.push(".pub");
    PathBuf::from(s)
}

/// State of the dedicated agent, derived from `ssh-add -l`'s exit status.
#[derive(Debug, PartialEq, Eq)]
pub enum AgentState {
    /// Agent is running and holds our key.
    Loaded,
    /// Agent is running but does not hold our key (exit 1, or other keys only).
    Missing,
    /// No agent answers on the socket (exit 2).
    NotRunning,
}

/// SHA256 fingerprint of a key, e.g. `SHA256:abc...`.
pub fn fingerprint(key: &Path) -> Result<String> {
    let out = Command::new("ssh-keygen")
        .arg("-lf")
        .arg(key)
        .output()
        .context("running ssh-keygen (is OpenSSH installed?)")?;
    if !out.status.success() {
        bail!(
            "ssh-keygen -lf {} failed: {}",
            key.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    parse_fingerprint(&String::from_utf8_lossy(&out.stdout))
        .ok_or_else(|| anyhow!("could not parse fingerprint of {}", key.display()))
}

/// Second whitespace-separated field of `ssh-keygen -l` / `ssh-add -l` output:
/// `256 SHA256:abc... comment (ED25519)`.
fn parse_fingerprint(line: &str) -> Option<String> {
    line.split_whitespace().nth(1).map(str::to_string)
}

/// Query the agent on `socket` for whether it holds the key with `fpr`.
pub fn state(socket: &Path, fpr: &str) -> Result<AgentState> {
    let out = Command::new("ssh-add")
        .arg("-l")
        .env("SSH_AUTH_SOCK", socket)
        .stdin(Stdio::null())
        .output()
        .context("running ssh-add")?;
    match out.status.code() {
        Some(0) => {
            let listed = String::from_utf8_lossy(&out.stdout);
            let has_key = listed
                .lines()
                .filter_map(parse_fingerprint)
                .any(|f| f == fpr);
            Ok(if has_key {
                AgentState::Loaded
            } else {
                AgentState::Missing
            })
        }
        Some(1) => Ok(AgentState::Missing),
        _ => Ok(AgentState::NotRunning),
    }
}

/// Start a new agent on `socket`, removing a stale socket left over from an
/// agent that no longer runs (e.g. after a reboot).
pub fn start(socket: &Path) -> Result<()> {
    if let Ok(meta) = std::fs::symlink_metadata(socket) {
        if !meta.file_type().is_socket() {
            bail!(
                "{} exists but is not a socket — refusing to remove it",
                socket.display()
            );
        }
        std::fs::remove_file(socket)
            .with_context(|| format!("removing stale agent socket {}", socket.display()))?;
    }
    if let Some(parent) = socket.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }

    // ssh-agent forks into the background (redirecting its own stdio to
    // /dev/null) and prints shell `export` lines we don't need.
    let out = Command::new("ssh-agent")
        .arg("-a")
        .arg(socket)
        .stdin(Stdio::null())
        .output()
        .context("running ssh-agent")?;
    if !out.status.success() {
        bail!(
            "ssh-agent -a {} failed: {}",
            socket.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// Load `key` into the agent on `socket` with a bounded lifetime.
pub fn add_key(socket: &Path, key: &Path) -> Result<()> {
    let out = Command::new("ssh-add")
        .arg("-q")
        .arg("-t")
        .arg(KEY_LIFETIME)
        .arg(key)
        .env("SSH_AUTH_SOCK", socket)
        .stdin(Stdio::null())
        .output()
        .context("running ssh-add")?;
    if !out.status.success() {
        bail!(
            "ssh-add {} failed: {}",
            key.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// Make sure the agent on `socket` is running and holds `key`. Returns a
/// short description of what was done, for logging.
pub fn ensure(socket: &Path, key: &Path) -> Result<&'static str> {
    let fpr = fingerprint(key)?;
    match state(socket, &fpr)? {
        AgentState::Loaded => Ok("GitHub key already loaded"),
        AgentState::Missing => {
            add_key(socket, key)?;
            Ok("loaded GitHub key into the dedicated agent")
        }
        AgentState::NotRunning => {
            start(socket)?;
            add_key(socket, key)?;
            Ok("started the dedicated agent and loaded the GitHub key")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_fingerprint_field() {
        let line = "256 SHA256:AbC123+/xyz fleeting-github@mac (ED25519)";
        assert_eq!(
            parse_fingerprint(line).as_deref(),
            Some("SHA256:AbC123+/xyz")
        );
        assert_eq!(parse_fingerprint(""), None);
    }

    #[test]
    fn public_key_path_appends_pub() {
        assert_eq!(
            public_key_path(Path::new("/home/u/.ssh/github_ed25519")),
            PathBuf::from("/home/u/.ssh/github_ed25519.pub")
        );
    }
}
