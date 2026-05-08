use std::{
    fs,
    io::{Error as IoError, ErrorKind},
    path::{Path, PathBuf},
};

pub struct BinaryCache {
    pub path: PathBuf,
}

impl BinaryCache {
    pub fn new<P: Into<PathBuf>>(path: P) -> Self {
        BinaryCache { path: path.into() }
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` if `path` is not a `/nix/store/<hash>-<name>`
    /// path, or any I/O error from reading the corresponding `.narinfo`.
    pub fn get_info_by_store_path(&mut self, path: &Path) -> Result<Info, IoError> {
        // Extract the 32-char base32 hash from /nix/store/<hash>-<name>.
        let hash = path
            .strip_prefix("/nix/store")
            .ok()
            .and_then(|rest| rest.to_str())
            .filter(|rest| rest.len() >= 32)
            .map(|rest| &rest[..32])
            .filter(|hash| hash.bytes().all(|b| b.is_ascii_alphanumeric()));
        let Some(hash) = hash else {
            return Err(IoError::new(
                ErrorKind::InvalidInput,
                format!("not a store path: {}", path.display()),
            ));
        };
        self.get_info_by_hash(hash)
    }

    /// # Errors
    ///
    /// Returns any I/O error from opening or reading `<hash>.narinfo`.
    pub fn get_info_by_hash(&mut self, hash: &str) -> Result<Info, IoError> {
        Info::open(&self.path.join(format!("{hash}.narinfo")))
    }
}

/// The subset of narinfo fields the pruner actually needs.
///
/// `Info` is held in a long-lived `Vec` sized to the closure of all GC roots,
/// which on a busy server can be hundreds of thousands of entries. Storing
/// only what we use, in compact owned strings rather than a per-file
/// `HashMap<String, String>`, keeps that memory bounded.
#[derive(Debug, Default)]
struct Fields {
    url: Option<Box<str>>,
    file_size: Option<u64>,
    nar_size: Option<u64>,
    // References and Deriver are 32-char hash prefixes of /nix/store paths;
    // store the full strings so callers can join them onto /nix/store.
    references: Box<[Box<str>]>,
    deriver: Option<Box<str>>,
}

#[derive(Debug)]
pub struct Info {
    pub path: PathBuf,
    fields: Fields,
}

impl Info {
    /// # Errors
    ///
    /// Returns any I/O error from opening or reading the file.
    pub fn open(path: &Path) -> Result<Self, IoError> {
        // narinfo files are ~500 bytes. Reading the whole thing once and
        // borrowing slices out of it is far cheaper than BufRead::lines(),
        // which allocates a fresh String per line.
        let buf = fs::read_to_string(path)?;

        let mut fields = Fields::default();
        for line in buf.lines() {
            let Some((key, val)) = line.split_once(": ") else {
                continue;
            };
            let val = val.trim_end();
            match key {
                "URL" => fields.url = Some(val.into()),
                "FileSize" => fields.file_size = val.parse().ok(),
                "NarSize" => fields.nar_size = val.parse().ok(),
                "Deriver" if !val.is_empty() => fields.deriver = Some(val.into()),
                "References" => {
                    fields.references = val
                        .split(' ')
                        .filter(|s| !s.is_empty())
                        .map(Into::into)
                        .collect();
                }
                _ => {}
            }
        }

        Ok(Info {
            path: path.into(),
            fields,
        })
    }

    #[must_use]
    pub fn url(&self) -> Option<&str> {
        self.fields.url.as_deref()
    }

    #[must_use]
    pub fn file_size(&self) -> u64 {
        self.fields.file_size.unwrap_or(0)
    }

    #[must_use]
    pub fn nar_size(&self) -> u64 {
        self.fields.nar_size.unwrap_or(0)
    }

    #[must_use]
    pub fn deriver(&self) -> Option<&str> {
        self.fields.deriver.as_deref()
    }

    pub fn references(&self) -> impl Iterator<Item = &str> {
        self.fields.references.iter().map(AsRef::as_ref)
    }
}
