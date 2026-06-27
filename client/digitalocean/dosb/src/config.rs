use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};

/// Built-in defaults applied when a value is not set in the config file.
const DEFAULT_SIZE: &str = "s-2vcpu-4gb";
const DEFAULT_TAG: &str = "ephemeral";
const DEFAULT_SNAPSHOT_PREFIX: &str = "sandbox-";
const DEFAULT_SSH_USER: &str = "root";
const DEFAULT_SSH_PORT: u16 = 22;
const DEFAULT_IDENTITY_FILE: &str = "~/.ssh/id_ed25519";

/// On-disk representation of the config file. All fields optional so we can
/// distinguish "unset" from "set", apply defaults, and report missing required
/// values with a precise error.
#[derive(Debug, Default, Deserialize, Serialize)]
pub struct ConfigFile {
    pub region: Option<String>,
    pub size: Option<String>,
    pub ssh_key_name: Option<String>,
    pub tag: Option<String>,
    pub snapshot_prefix: Option<String>,
    pub ssh_user: Option<String>,
    pub ssh_port: Option<u16>,
    pub identity_file: Option<String>,
}

/// Fully-resolved, validated config used by the commands.
#[derive(Debug, Clone)]
pub struct Config {
    pub region: String,
    pub size: String,
    pub ssh_key_name: String,
    pub tag: String,
    pub snapshot_prefix: String,
    pub ssh_user: String,
    pub ssh_port: u16,
    pub identity_file: String,
}

impl Config {
    /// Resolve the config-file path: explicit override wins, otherwise the
    /// XDG/`directories` default (`~/.config/dosb/config.toml`).
    pub fn path(override_path: Option<&Path>) -> Result<PathBuf> {
        if let Some(p) = override_path {
            return Ok(p.to_path_buf());
        }
        let dirs = directories::ProjectDirs::from("", "", "dosb")
            .ok_or_else(|| anyhow!("could not determine a config directory for dosb"))?;
        Ok(dirs.config_dir().join("config.toml"))
    }

    /// Load and validate the config, applying defaults and erroring on any
    /// still-missing required value.
    pub fn load(override_path: Option<&Path>) -> Result<Config> {
        let path = Self::path(override_path)?;
        let file = read_config_file(&path)?;

        let region = file
            .region
            .filter(|s| !s.is_empty())
            .ok_or_else(|| missing("region", &path))?;
        let ssh_key_name = file
            .ssh_key_name
            .filter(|s| !s.is_empty())
            .ok_or_else(|| missing("ssh_key_name", &path))?;

        Ok(Config {
            region,
            size: file.size.unwrap_or_else(|| DEFAULT_SIZE.to_string()),
            ssh_key_name,
            tag: file.tag.unwrap_or_else(|| DEFAULT_TAG.to_string()),
            snapshot_prefix: file
                .snapshot_prefix
                .unwrap_or_else(|| DEFAULT_SNAPSHOT_PREFIX.to_string()),
            ssh_user: file.ssh_user.unwrap_or_else(|| DEFAULT_SSH_USER.to_string()),
            ssh_port: file.ssh_port.unwrap_or(DEFAULT_SSH_PORT),
            identity_file: file
                .identity_file
                .unwrap_or_else(|| DEFAULT_IDENTITY_FILE.to_string()),
        })
    }
}

fn read_config_file(path: &Path) -> Result<ConfigFile> {
    if !path.exists() {
        return Err(anyhow!(
            "no config file found at {}\nRun `dosb init` to create one.",
            path.display()
        ));
    }
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading config file {}", path.display()))?;
    let file: ConfigFile = toml::from_str(&text)
        .with_context(|| format!("parsing config file {}", path.display()))?;
    Ok(file)
}

fn missing(key: &str, path: &Path) -> anyhow::Error {
    anyhow!(
        "required config value `{key}` is not set in {}\nSet it there or run `dosb init`.",
        path.display()
    )
}

/// Defaults exposed for the `init` command's prompts.
pub mod defaults {
    use super::*;

    pub fn size() -> &'static str {
        DEFAULT_SIZE
    }
    pub fn tag() -> &'static str {
        DEFAULT_TAG
    }
    pub fn snapshot_prefix() -> &'static str {
        DEFAULT_SNAPSHOT_PREFIX
    }
    pub fn ssh_user() -> &'static str {
        DEFAULT_SSH_USER
    }
    pub fn ssh_port() -> u16 {
        DEFAULT_SSH_PORT
    }
    pub fn identity_file() -> &'static str {
        DEFAULT_IDENTITY_FILE
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Write `contents` to a uniquely-named temp file and return its path.
    fn temp_config(contents: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        let unique = format!(
            "dosb-test-{}-{:?}.toml",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        path.push(unique);
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(contents.as_bytes()).unwrap();
        path
    }

    #[test]
    fn applies_defaults_for_unset_optional_values() {
        let path = temp_config("region = \"sfo3\"\nssh_key_name = \"laptop\"\n");
        let cfg = Config::load(Some(&path)).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(cfg.region, "sfo3");
        assert_eq!(cfg.ssh_key_name, "laptop");
        assert_eq!(cfg.size, DEFAULT_SIZE);
        assert_eq!(cfg.tag, DEFAULT_TAG);
        assert_eq!(cfg.snapshot_prefix, DEFAULT_SNAPSHOT_PREFIX);
        assert_eq!(cfg.ssh_user, DEFAULT_SSH_USER);
        assert_eq!(cfg.ssh_port, DEFAULT_SSH_PORT);
        assert_eq!(cfg.identity_file, DEFAULT_IDENTITY_FILE);
    }

    #[test]
    fn explicit_values_override_defaults() {
        let path = temp_config(
            "region = \"nyc1\"\nssh_key_name = \"laptop\"\nsize = \"s-4vcpu-8gb\"\n\
             tag = \"sandbox\"\nsnapshot_prefix = \"sbx_\"\nssh_user = \"dev\"\n\
             ssh_port = 2222\nidentity_file = \"~/.ssh/do\"\n",
        );
        let cfg = Config::load(Some(&path)).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(cfg.size, "s-4vcpu-8gb");
        assert_eq!(cfg.tag, "sandbox");
        assert_eq!(cfg.snapshot_prefix, "sbx_");
        assert_eq!(cfg.ssh_user, "dev");
        assert_eq!(cfg.ssh_port, 2222);
        assert_eq!(cfg.identity_file, "~/.ssh/do");
    }

    #[test]
    fn missing_required_region_errors() {
        let path = temp_config("ssh_key_name = \"laptop\"\n");
        let err = Config::load(Some(&path)).unwrap_err().to_string();
        std::fs::remove_file(&path).ok();
        assert!(err.contains("region"), "unexpected error: {err}");
    }

    #[test]
    fn empty_required_value_is_treated_as_missing() {
        let path = temp_config("region = \"\"\nssh_key_name = \"laptop\"\n");
        let err = Config::load(Some(&path)).unwrap_err().to_string();
        std::fs::remove_file(&path).ok();
        assert!(err.contains("region"), "unexpected error: {err}");
    }

    #[test]
    fn missing_file_points_at_init() {
        let path = PathBuf::from("/nonexistent/dosb/does-not-exist.toml");
        let err = Config::load(Some(&path)).unwrap_err().to_string();
        assert!(err.contains("dosb init"), "unexpected error: {err}");
    }
}
