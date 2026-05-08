use std::{
    collections::HashMap,
    fs::File,
    io::{BufRead, BufReader, Error as IoError, ErrorKind},
    path::{Path, PathBuf},
    rc::Rc,
};

pub struct BinaryCache {
    pub path: PathBuf,
    cached_infos: HashMap<PathBuf, Info>,
}

impl BinaryCache {
    pub fn new<P: Into<PathBuf>>(path: P) -> Self {
        BinaryCache {
            path: path.into(),
            cached_infos: HashMap::new(),
        }
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
        let path = self.path.join(format!("{hash}.narinfo"));
        if let Some(info) = self.cached_infos.get(&path) {
            // cache hit
            return Ok(info.clone());
        }

        // cache miss, read
        let info = Info::open(&path)?;
        self.cached_infos.insert(path, info.clone());
        Ok(info)
    }
}

#[derive(Clone, Debug)]
pub struct Info {
    pub path: PathBuf,
    pub fields: Rc<HashMap<String, String>>,
}

impl Info {
    /// # Errors
    ///
    /// Returns any I/O error from opening or reading the file.
    pub fn open(path: &Path) -> Result<Self, IoError> {
        let f = File::open(path)?;
        let r = BufReader::new(f);

        let mut fields = HashMap::new();
        for line in r.lines() {
            let line = line?;
            if let Some(pos) = line.find(": ") {
                let key = line[..pos].to_string();
                let val = line[pos + 2..].trim_end().to_string();
                fields.insert(key, val);
            }
        }

        Ok(Info {
            path: path.into(),
            fields: Rc::new(fields),
        })
    }

    #[must_use]
    pub fn deriver(&self) -> Option<&str> {
        let deriver = self.fields.get("Deriver").map_or("", |s| s.as_str());
        if deriver.is_empty() {
            None
        } else {
            Some(deriver)
        }
    }

    pub fn references(&self) -> impl Iterator<Item = &str> {
        self.fields
            .get("References")
            .map_or("", |s| s.as_str())
            .split(' ')
            .filter(|s| !s.is_empty())
    }
}
