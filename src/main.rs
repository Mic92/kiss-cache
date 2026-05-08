use std::{path::PathBuf, process::ExitCode};

use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use nix_cache_cut::prune::{self, Config, Progress};

const USAGE: &str = "\
Trim Nix binary caches according to GC roots

Usage: nix-cache-cut [-n|--dry-run] <CACHEDIR> [GCROOTS...]

Arguments:
  CACHEDIR    Cache directory
  GCROOTS     Garbage collector roots [default: /nix/var/nix/gcroots]

Options:
  -n, --dry-run  Do not actually delete files
  -h, --help     Print help
  -V, --version  Print version";

fn parse_args() -> Result<Config, lexopt::Error> {
    use lexopt::prelude::*;

    let mut dry_run = false;
    let mut positional: Vec<PathBuf> = Vec::new();
    let mut parser = lexopt::Parser::from_env();
    while let Some(arg) = parser.next()? {
        match arg {
            Short('n') | Long("dry-run") => dry_run = true,
            Short('h') | Long("help") => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            Short('V') | Long("version") => {
                println!("nix-cache-cut {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            Value(v) => positional.push(v.into()),
            _ => return Err(arg.unexpected()),
        }
    }

    let mut positional = positional.into_iter();
    let cache_dir = positional
        .next()
        .ok_or("missing required argument CACHEDIR")?;
    let mut gcroots: Vec<PathBuf> = positional.collect();
    if gcroots.is_empty() {
        gcroots.push("/nix/var/nix/gcroots".into());
    }

    Ok(Config {
        dry_run,
        cache_dir,
        gcroots,
    })
}

fn make_progress(dry_run: bool) -> Progress {
    let make_spinner = |color| {
        let template = format!(
            "{{spinner}} {{prefix:.bold.dim}} {{wide_bar:.{color}}} [{{pos:.bold.dim}}/{{len:.bold}}] {{msg}}"
        );
        // The template is a fixed literal; only the colour varies, and all
        // colours we pass are valid. Fall back to the default style rather
        // than crash if indicatif ever rejects one.
        ProgressStyle::with_template(&template)
            .unwrap_or_else(|_| ProgressStyle::default_bar())
            .tick_chars("⠁⠂⠄⡀⢀⠠⠐⠈ ")
    };
    let multi = MultiProgress::new();
    let bar = |prefix: String, color, length| {
        let bar = multi.add(ProgressBar::new(length));
        bar.set_prefix(prefix);
        bar.set_style(make_spinner(color));
        bar.tick();
        bar
    };
    let msg_prefix = if dry_run { "NOT " } else { "" };
    Progress {
        gcroots: bar("Scanning GCROOTS".into(), "green.dim", 0),
        scanner: bar("Scanning dependencies".into(), "green", 1),
        keep: bar("Retaining archives".into(), "yellow", 1),
        rm_narinfo: bar(format!("{msg_prefix}Deleting .narinfo files"), "red", 1),
        rm_nar: bar(format!("{msg_prefix}Deleting .nar files"), "red.dim", 1),
    }
}

fn main() -> ExitCode {
    let config = match parse_args() {
        Ok(config) => config,
        Err(e) => {
            eprintln!("error: {e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let progress = make_progress(config.dry_run);
    prune::run(&config, &progress);
    ExitCode::SUCCESS
}
