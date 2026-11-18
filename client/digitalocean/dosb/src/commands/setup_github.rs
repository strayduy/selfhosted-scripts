//! `dosb setup-github`: create the GitHub-only SSH key that `connect-droplet`
//! forwards (via a dedicated agent) and register it with the GitHub account
//! through the `gh` CLI. Idempotent: every step checks before acting.

use std::os::unix::fs::DirBuilderExt;
use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{anyhow, bail, Context, Result};

use crate::config::Config;
use crate::ssh_agent;
use crate::ui;

const SCOPE_HINT: &str = "gh needs the `admin:public_key` scope to manage SSH keys — run:\n  \
                          gh auth refresh -h github.com -s admin:public_key";

pub fn run(config: &Config, dry_run: bool) -> Result<()> {
    let key = ssh_agent::expand(&config.github_identity_file);
    let pubkey = ssh_agent::public_key_path(&key);
    let host = short_hostname();

    check_gh()?;

    // ── Key pair ──────────────────────────────────────────────────────────
    if key.exists() {
        ui::info(&format!("Using existing key {}", key.display()));
        if !pubkey.exists() {
            if dry_run {
                ui::dry_run(&format!(
                    "Would recreate {} from the private key",
                    pubkey.display()
                ));
            } else {
                recreate_public_key(&key, &pubkey)?;
            }
        }
    } else if dry_run {
        ui::dry_run(&format!(
            "Would generate ed25519 key {} (no passphrase)",
            key.display()
        ));
    } else {
        generate_key(&key, &format!("dosb-github@{host}"))?;
        ui::success(&format!("Generated {}", key.display()));
    }

    // ── Register with GitHub ──────────────────────────────────────────────
    let title = format!("dosb-github ({host})");
    let registered = registered_keys()?;
    let local = if pubkey.exists() {
        Some(read_key_body(&pubkey)?)
    } else {
        None
    };

    match &local {
        Some(body) if registered.iter().any(|k| k == body) => {
            ui::info("Key is already registered with your GitHub account");
        }
        _ if dry_run => {
            ui::dry_run(&format!(
                "Would register {} on GitHub as `{title}`",
                pubkey.display()
            ));
        }
        _ => {
            add_key(&pubkey, &title)?;
            ui::success(&format!("Registered key on GitHub as `{title}`"));
        }
    }

    if dry_run {
        return Ok(());
    }

    // ── Verify ────────────────────────────────────────────────────────────
    verify(&key);
    ui::info("`dosb connect-droplet` will now forward this key to droplets.");
    Ok(())
}

/// `gh` must be installed and logged in.
fn check_gh() -> Result<()> {
    let status = Command::new("gh")
        .args(["auth", "status", "--hostname", "github.com"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    match status {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            bail!("the GitHub CLI `gh` is not installed (https://cli.github.com)")
        }
        Err(e) => Err(e).context("running gh"),
        Ok(s) if !s.success() => bail!("gh is not logged in to github.com — run `gh auth login`"),
        Ok(_) => Ok(()),
    }
}

fn generate_key(key: &Path, comment: &str) -> Result<()> {
    if let Some(parent) = key.parent().filter(|p| !p.exists()) {
        // Usually ~/.ssh, which ssh expects to be private.
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    let status = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f"])
        .arg(key)
        .stdin(Stdio::null())
        .status()
        .context("running ssh-keygen")?;
    if !status.success() {
        bail!("ssh-keygen failed to create {}", key.display());
    }
    Ok(())
}

fn recreate_public_key(key: &Path, pubkey: &Path) -> Result<()> {
    let out = Command::new("ssh-keygen")
        .arg("-y")
        .arg("-f")
        .arg(key)
        .stdin(Stdio::null())
        .output()
        .context("running ssh-keygen -y")?;
    if !out.status.success() {
        bail!(
            "could not derive public key from {}: {}",
            key.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    std::fs::write(pubkey, &out.stdout).with_context(|| format!("writing {}", pubkey.display()))?;
    ui::info(&format!("Recreated {}", pubkey.display()));
    Ok(())
}

/// `<type> <base64>` of a public key file, without the comment — the form
/// GitHub's API returns.
fn read_key_body(pubkey: &Path) -> Result<String> {
    let text =
        std::fs::read_to_string(pubkey).with_context(|| format!("reading {}", pubkey.display()))?;
    key_body(&text).ok_or_else(|| anyhow!("{} is not a valid public key", pubkey.display()))
}

fn key_body(line: &str) -> Option<String> {
    let mut fields = line.split_whitespace();
    let kind = fields.next()?;
    let b64 = fields.next()?;
    Some(format!("{kind} {b64}"))
}

/// Authentication keys registered on the account, as `<type> <base64>`.
fn registered_keys() -> Result<Vec<String>> {
    let out = Command::new("gh")
        .args(["api", "--paginate", "user/keys", "--jq", ".[].key"])
        .stdin(Stdio::null())
        .output()
        .context("running gh api")?;
    if !out.status.success() {
        bail!(
            "listing your GitHub SSH keys failed: {}\n{SCOPE_HINT}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(key_body)
        .collect())
}

fn add_key(pubkey: &Path, title: &str) -> Result<()> {
    let out = Command::new("gh")
        .args(["ssh-key", "add"])
        .arg(pubkey)
        .args(["--type", "authentication", "--title", title])
        .stdin(Stdio::null())
        .output()
        .context("running gh ssh-key add")?;
    if !out.status.success() {
        bail!(
            "gh ssh-key add failed: {}\n{SCOPE_HINT}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// `ssh -T git@github.com` with only this key. GitHub always exits 1 (no
/// shell access), so success is detected from the greeting. A failure here is
/// a warning: the key is registered, and GitHub can lag a few seconds.
fn verify(key: &Path) {
    let out = Command::new("ssh")
        .args([
            "-T",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "IdentityAgent=none",
            "-i",
        ])
        .arg(key)
        .arg("git@github.com")
        .stdin(Stdio::null())
        .output();
    match out {
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            if let Some(line) = stderr
                .lines()
                .find(|l| l.contains("successfully authenticated"))
            {
                ui::success(&format!("GitHub says: {}", line.trim()));
            } else {
                ui::warn(&format!(
                    "could not confirm the key works yet (`ssh -T git@github.com`): {}",
                    stderr.trim()
                ));
            }
        }
        Err(e) => ui::warn(&format!("could not run ssh to verify the key: {e}")),
    }
}

fn short_hostname() -> String {
    Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "laptop".to_string())
}

#[cfg(test)]
mod tests {
    use super::key_body;

    #[test]
    fn key_body_strips_comment() {
        assert_eq!(
            key_body("ssh-ed25519 AAAAC3Nz dosb-github@mac\n").as_deref(),
            Some("ssh-ed25519 AAAAC3Nz")
        );
        assert_eq!(
            key_body("ssh-ed25519 AAAAC3Nz").as_deref(),
            Some("ssh-ed25519 AAAAC3Nz")
        );
        assert_eq!(key_body("garbage"), None);
    }
}
