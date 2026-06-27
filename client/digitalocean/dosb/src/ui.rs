//! Small presentation helpers: colored log labels (gated on TTY + NO_COLOR),
//! a minimal aligned-table renderer, and human-friendly age formatting.

use std::io::IsTerminal;

use chrono::{DateTime, Utc};

fn colors_enabled() -> bool {
    std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none()
}

fn paint(code: &str, text: &str) -> String {
    if colors_enabled() {
        format!("\x1b[{code}m{text}\x1b[0m")
    } else {
        text.to_string()
    }
}

pub fn error_label() -> String {
    paint("0;31", "[ERROR]")
}

pub fn info(msg: &str) {
    println!("{} {}", paint("0;34", "[INFO]"), msg);
}

pub fn success(msg: &str) {
    println!("{} {}", paint("0;32", "[OK]"), msg);
}

pub fn warn(msg: &str) {
    eprintln!("{} {}", paint("1;33", "[WARN]"), msg);
}

/// Notice describing a mutating action that was skipped because of `--dry-run`.
pub fn dry_run(msg: &str) {
    println!("{} {}", paint("1;35", "[DRY-RUN]"), msg);
}

/// Render rows as a left-aligned table with a header. Column widths are sized to
/// the widest cell in each column.
pub fn table(headers: &[&str], rows: &[Vec<String>]) {
    let cols = headers.len();
    let mut widths: Vec<usize> = headers.iter().map(|h| h.len()).collect();
    for row in rows {
        for (i, cell) in row.iter().enumerate().take(cols) {
            widths[i] = widths[i].max(cell.len());
        }
    }

    let render = |cells: &[String]| {
        let mut line = String::new();
        for (i, cell) in cells.iter().enumerate().take(cols) {
            if i > 0 {
                line.push_str("  ");
            }
            if i == cols - 1 {
                line.push_str(cell);
            } else {
                line.push_str(&format!("{:<width$}", cell, width = widths[i]));
            }
        }
        line
    };

    let header_cells: Vec<String> = headers.iter().map(|h| h.to_string()).collect();
    println!("{}", paint("1", &render(&header_cells)));
    for row in rows {
        println!("{}", render(row));
    }
}

/// Format a creation timestamp as a compact relative age, e.g. "3h", "2d".
pub fn age(created_at: &str) -> String {
    let parsed = DateTime::parse_from_rfc3339(created_at).map(|dt| dt.with_timezone(&Utc));
    let Ok(created) = parsed else {
        return created_at.to_string();
    };
    let secs = (Utc::now() - created).num_seconds().max(0);
    match secs {
        s if s < 60 => format!("{s}s"),
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 86_400 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86_400),
    }
}

#[cfg(test)]
mod tests {
    use super::age;
    use chrono::{Duration, Utc};

    fn ago(d: Duration) -> String {
        age(&(Utc::now() - d).to_rfc3339())
    }

    #[test]
    fn formats_relative_ages_by_unit() {
        assert_eq!(ago(Duration::seconds(5)), "5s");
        assert_eq!(ago(Duration::minutes(3)), "3m");
        assert_eq!(ago(Duration::hours(2)), "2h");
        assert_eq!(ago(Duration::days(4)), "4d");
    }

    #[test]
    fn unparseable_timestamp_is_passed_through() {
        assert_eq!(age("not-a-date"), "not-a-date");
    }
}
