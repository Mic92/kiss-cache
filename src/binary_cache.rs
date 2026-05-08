use std::{
    collections::HashMap,
    fs::File,
    io::{BufRead, BufReader, Error as IoError},
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

    pub fn get_info_by_store_path(&mut self, path: &Path) -> Result<Info, IoError> {
        if path.starts_with("/nix/store") {
            let path = path.to_str().unwrap();
            if path.len() >= 43 {
                self.get_info_by_hash(&path["/nix/store/".len()..43])
            } else {
                panic!("Invalid store path: {path}");
            }
        } else {
            panic!("Invalid store path: {}", path.display());
        }
    }

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
