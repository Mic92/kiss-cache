use std::{fmt, path::Path, str};

/// The 32-character base32 prefix of a `/nix/store/<hash>-<name>` path.
///
/// Store hashes are the unit of identity for everything the pruner does:
/// narinfo files are named `<hash>.narinfo`, and References/Deriver fields
/// list paths whose only useful part is this prefix. Carrying the hash as a
/// fixed-size, stack-allocated, ASCII byte array lets the dependency scanner
/// build its visited-set without heap-allocating a `PathBuf` per reference,
/// and makes hashing and comparison a constant-size operation.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct StoreHash([u8; 32]);

impl StoreHash {
    /// Parse a `/nix/store/<hash>-<name>` path. Returns `None` for anything
    /// that does not start with `/nix/store/` followed by 32 alphanumeric
    /// bytes (e.g. `/nix/store` itself, or non-UTF-8 garbage).
    #[must_use]
    pub fn from_store_path(path: &Path) -> Option<Self> {
        let rest = path
            .strip_prefix("/nix/store")
            .ok()?
            .as_os_str()
            .as_encoded_bytes();
        Self::from_prefix(rest)
    }

    /// Parse a bare `<hash>-<name>` string (as found in narinfo References
    /// and Deriver fields).
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Self::from_prefix(name.as_bytes())
    }

    fn from_prefix(bytes: &[u8]) -> Option<Self> {
        Self::from_bytes(bytes.get(..32)?.try_into().ok()?)
    }

    /// Validate a raw 32-byte buffer as a store hash.
    #[must_use]
    pub fn from_bytes(hash: [u8; 32]) -> Option<Self> {
        hash.iter()
            .all(u8::is_ascii_alphanumeric)
            .then_some(StoreHash(hash))
    }

    #[must_use]
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        // Invariant: from_prefix only accepts ASCII alphanumerics.
        str::from_utf8(&self.0).unwrap_or_default()
    }
}

impl fmt::Display for StoreHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
