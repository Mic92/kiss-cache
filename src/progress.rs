//! Minimal, allocation-light progress reporting on stderr.
//!
//! Replaces indicatif: this tool only needs a single-line per-phase counter
//! with an optional human-byte tally, and indicatif's multi-bar rendering,
//! ANSI styling and tick threads cost ~85 KiB of code and five transitive
//! dependencies for a CLI that runs unattended from a systemd timer.

use std::{
    cell::Cell,
    fmt::Write as _,
    io::{IsTerminal, Write, stderr},
    time::{Duration, Instant},
};

/// Redraw at most this often. Matches indicatif's default cadence; any
/// faster is wasted formatting on a counter humans cannot read.
const REDRAW_INTERVAL: Duration = Duration::from_millis(66);

/// Per-phase progress reporter. Interior mutability so callers can share
/// a `&Phase` reference, like indicatif's `&ProgressBar`.
pub struct Phase {
    prefix: &'static str,
    pos: Cell<u64>,
    len: Cell<u64>,
    bytes: Cell<u64>,
    last_draw: Cell<Option<Instant>>,
    enabled: bool,
}

impl Phase {
    /// A live reporter that writes to stderr if it is a terminal.
    #[must_use]
    pub fn new(prefix: &'static str) -> Self {
        Phase {
            prefix,
            pos: Cell::new(0),
            len: Cell::new(0),
            bytes: Cell::new(0),
            last_draw: Cell::new(None),
            enabled: stderr().is_terminal(),
        }
    }

    /// A reporter that emits nothing. Used by tests and benchmarks.
    #[must_use]
    pub fn hidden() -> Self {
        Phase {
            prefix: "",
            pos: Cell::new(0),
            len: Cell::new(0),
            bytes: Cell::new(0),
            last_draw: Cell::new(None),
            enabled: false,
        }
    }

    pub fn set_position(&self, pos: u64) {
        self.pos.set(pos);
        self.maybe_draw();
    }

    pub fn set_length(&self, len: u64) {
        self.len.set(len);
    }

    pub fn inc_length(&self, by: u64) {
        self.len.set(self.len.get() + by);
    }

    pub fn inc(&self, by: u64) {
        self.pos.set(self.pos.get() + by);
        self.maybe_draw();
    }

    /// Record a running byte total to show alongside the counter.
    pub fn set_bytes(&self, bytes: u64) {
        self.bytes.set(bytes);
    }

    /// Print a final line for this phase and move to the next line.
    pub fn finish(&self) {
        if !self.enabled {
            return;
        }
        let mut out = stderr().lock();
        let _ = writeln!(out, "\r\x1b[2K{}", self.line());
    }

    fn maybe_draw(&self) {
        if !self.enabled {
            return;
        }
        let now = Instant::now();
        if let Some(last) = self.last_draw.get()
            && now.duration_since(last) < REDRAW_INTERVAL
        {
            return;
        }
        self.last_draw.set(Some(now));
        let mut out = stderr().lock();
        let _ = write!(out, "\r\x1b[2K{}", self.line());
        let _ = out.flush();
    }

    fn line(&self) -> String {
        let mut s = String::with_capacity(64);
        let _ = write!(s, "{} [{}/{}]", self.prefix, self.pos.get(), self.len.get());
        let bytes = self.bytes.get();
        if bytes > 0 {
            let _ = write!(s, " {}", HumanBytes(bytes));
        }
        s
    }
}

/// Format a byte count with a binary unit prefix (KiB, MiB, ...).
pub struct HumanBytes(pub u64);

impl std::fmt::Display for HumanBytes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        const UNITS: [&str; 7] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"];
        let mut n = self.0;
        let mut unit = 0;
        // Keep two binary places of fraction in `frac` (0..1024) so the
        // whole computation stays in integers; a u64 byte count never
        // exceeds EiB, so the loop terminates within UNITS.
        let mut frac = 0u64;
        while n >= 1024 && unit < UNITS.len() - 1 {
            frac = n % 1024;
            n /= 1024;
            unit += 1;
        }
        if unit == 0 {
            write!(f, "{n} {}", UNITS[0])
        } else {
            // Truncate to two decimal places: frac/1024 ≈ centi/100.
            // Truncation rather than rounding avoids carry into `n`.
            let centi = frac * 100 / 1024;
            write!(f, "{n}.{centi:02} {}", UNITS[unit])
        }
    }
}
