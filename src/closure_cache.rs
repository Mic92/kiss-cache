//! Persistent cache of parsed narinfo metadata, keyed by store hash.
//!
//! A narinfo's URL, sizes, References, and Deriver are immutable for a given
//! store hash; they never change once the file is written. Caching them on
//! disk lets later runs skip reopening and reparsing the .narinfo for every
//! hash already seen, which is the dominant cost of the dependency scan.
//!
//! The cache is trusted without verification: if a narinfo is deleted out of
//! band, the cached entry keeps its archive alive for one more run before the
//! sweep notices. That direction of error is safe (it never deletes something
//! that is still reachable). The cache file is rewritten atomically after
//! every scan from the full set of reachable infos, so deleted hashes age out
//! once they leave the closure.

use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

use rustc_hash::FxHashMap;

use crate::{binary_cache::NarInfo, store_hash::StoreHash};

const MAGIC: &[u8; 8] = b"NCCCLOS\x01";

pub type Map = FxHashMap<StoreHash, NarInfo>;

/// Default location: alongside the cache, where it benefits from the same
/// disk and is removed when the cache is.
#[must_use]
pub fn default_path(cache_dir: &Path) -> PathBuf {
    cache_dir.join(".kiss-cache.closures")
}

/// Load the persistent cache. Any parse or I/O error yields an empty map;
/// the cache is purely an optimization and never required for correctness.
#[must_use]
pub fn load(path: &Path) -> Map {
    try_load(path).unwrap_or_default()
}

fn try_load(path: &Path) -> Option<Map> {
    let buf = fs::read(path).ok()?;
    let mut r = buf.as_slice();
    if read_n::<8>(&mut r)? != *MAGIC {
        return None;
    }
    let mut map = Map::default();
    while !r.is_empty() {
        let hash = StoreHash::from_bytes(read_n::<32>(&mut r)?)?;
        let url_len = usize::from(u16::from_le_bytes(read_n::<2>(&mut r)?));
        let url = if url_len == 0 {
            None
        } else {
            Some(str::from_utf8(take(&mut r, url_len)?).ok()?.into())
        };
        let file_size = u64::from_le_bytes(read_n::<8>(&mut r)?);
        let nar_size = u64::from_le_bytes(read_n::<8>(&mut r)?);
        let deriver = match read_n::<1>(&mut r)?[0] {
            0 => None,
            _ => StoreHash::from_bytes(read_n::<32>(&mut r)?),
        };
        let n_refs = usize::from(u16::from_le_bytes(read_n::<2>(&mut r)?));
        let mut references = Vec::with_capacity(n_refs);
        for _ in 0..n_refs {
            references.push(StoreHash::from_bytes(read_n::<32>(&mut r)?)?);
        }
        map.insert(
            hash,
            NarInfo {
                url,
                file_size,
                nar_size,
                references: references.into(),
                deriver,
            },
        );
    }
    Some(map)
}

/// Atomically rewrite the cache from the full set of reachable infos.
///
/// # Errors
///
/// Returns any I/O error from writing or renaming the temporary file.
pub fn save<'a>(
    path: &Path,
    infos: impl Iterator<Item = (StoreHash, &'a NarInfo)>,
) -> io::Result<()> {
    let tmp = path.with_extension("closures.tmp");
    let mut buf = Vec::new();
    buf.extend_from_slice(MAGIC);
    for (hash, info) in infos {
        buf.extend_from_slice(hash.as_bytes());
        let url = info.url.as_deref().unwrap_or("");
        // narinfo URLs are nar/<hash>.nar.<compression>, well under u16.
        let url_len = u16::try_from(url.len()).unwrap_or(0);
        buf.extend_from_slice(&url_len.to_le_bytes());
        buf.extend_from_slice(&url.as_bytes()[..usize::from(url_len)]);
        buf.extend_from_slice(&info.file_size.to_le_bytes());
        buf.extend_from_slice(&info.nar_size.to_le_bytes());
        match info.deriver {
            Some(d) => {
                buf.push(1);
                buf.extend_from_slice(d.as_bytes());
            }
            None => buf.push(0),
        }
        let n = u16::try_from(info.references.len()).unwrap_or(u16::MAX);
        buf.extend_from_slice(&n.to_le_bytes());
        for r in info.references.iter().take(usize::from(n)) {
            buf.extend_from_slice(r.as_bytes());
        }
    }
    fs::File::create(&tmp)?.write_all(&buf)?;
    fs::rename(&tmp, path)
}

fn read_n<const N: usize>(r: &mut &[u8]) -> Option<[u8; N]> {
    let mut out = [0u8; N];
    r.read_exact(&mut out).ok()?;
    Some(out)
}

fn take<'a>(r: &mut &'a [u8], n: usize) -> Option<&'a [u8]> {
    if r.len() < n {
        return None;
    }
    let (head, tail) = r.split_at(n);
    *r = tail;
    Some(head)
}
