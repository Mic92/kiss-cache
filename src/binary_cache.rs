use std::{
    ffi::OsString,
    fs,
    io::Error as IoError,
    os::unix::ffi::OsStringExt,
    path::{Path, PathBuf},
};

use crate::store_hash::StoreHash;

pub struct BinaryCache {
    pub path: PathBuf,
}

impl BinaryCache {
    pub fn new<P: Into<PathBuf>>(path: P) -> Self {
        BinaryCache { path: path.into() }
    }

    /// # Errors
    ///
    /// Returns any I/O error from opening or reading `<hash>.narinfo`.
    pub fn get_info_by_hash(&self, hash: StoreHash) -> Result<Info, IoError> {
        Info::open(&self.narinfo_path(hash))
    }

    /// `<cache>/<hash>.narinfo`, built without round-tripping through
    /// `format!` and `Path::join`, which both heap-allocate per call.
    fn narinfo_path(&self, hash: StoreHash) -> PathBuf {
        const EXT: &[u8] = b".narinfo";
        let dir = self.path.as_os_str().as_encoded_bytes();
        let mut buf = Vec::with_capacity(dir.len() + 1 + 32 + EXT.len());
        buf.extend_from_slice(dir);
        buf.push(b'/');
        buf.extend_from_slice(hash.as_str().as_bytes());
        buf.extend_from_slice(EXT);
        PathBuf::from(OsString::from_vec(buf))
    }
}

/// The subset of narinfo fields the pruner actually needs.
///
/// `Info` is held in a long-lived `Vec` sized to the closure of all GC roots,
/// which on a busy server can be hundreds of thousands of entries. Storing
/// only what we use, with references and deriver as fixed-size hashes rather
/// than owned strings, keeps that memory bounded.
#[derive(Debug, Default)]
struct Fields {
    url: Option<Box<str>>,
    file_size: Option<u64>,
    nar_size: Option<u64>,
    references: Box<[StoreHash]>,
    deriver: Option<StoreHash>,
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
                "Deriver" => fields.deriver = StoreHash::from_name(val),
                "References" => {
                    fields.references = val.split(' ').filter_map(StoreHash::from_name).collect();
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
    pub fn deriver(&self) -> Option<StoreHash> {
        self.fields.deriver
    }

    pub fn references(&self) -> impl Iterator<Item = StoreHash> {
        self.fields.references.iter().copied()
    }
}
