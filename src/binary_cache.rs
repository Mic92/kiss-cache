use std::{ffi::OsString, fs, io::Error as IoError, os::unix::ffi::OsStringExt, path::PathBuf};

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
    pub fn get_info_by_hash(&self, hash: StoreHash) -> Result<NarInfo, IoError> {
        // narinfo files are ~500 bytes. Reading the whole thing once and
        // borrowing slices out of it is far cheaper than BufRead::lines(),
        // which allocates a fresh String per line.
        let buf = fs::read_to_string(self.narinfo_path(hash))?;
        Ok(NarInfo::parse(&buf))
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
/// Held in a long-lived `Vec` sized to the closure of all GC roots, which on
/// a busy server can be hundreds of thousands of entries. Storing only what
/// we use, with references and deriver as fixed-size hashes rather than
/// owned strings, keeps that memory bounded.
#[derive(Debug, Default, Clone)]
pub struct NarInfo {
    pub url: Option<Box<str>>,
    pub file_size: u64,
    pub nar_size: u64,
    pub references: Box<[StoreHash]>,
    pub deriver: Option<StoreHash>,
}

impl NarInfo {
    fn parse(buf: &str) -> Self {
        let mut info = NarInfo::default();
        for line in buf.lines() {
            let Some((key, val)) = line.split_once(": ") else {
                continue;
            };
            let val = val.trim_end();
            match key {
                "URL" => info.url = Some(val.into()),
                "FileSize" => info.file_size = val.parse().unwrap_or(0),
                "NarSize" => info.nar_size = val.parse().unwrap_or(0),
                "Deriver" => info.deriver = StoreHash::from_name(val),
                "References" => {
                    info.references = val.split(' ').filter_map(StoreHash::from_name).collect();
                }
                _ => {}
            }
        }
        info
    }
}
