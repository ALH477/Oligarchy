//! StreamDb - A reverse Trie index key-value database in Rust.
//!
//! ## Overview
//! StreamDb is a thread-safe, embedded key-value store designed for path-based queries with efficient prefix searches. Keys are string paths, and values are binary streams (up to 256MB). It uses a paged storage system with chaining, LRU caching, quick mode for faster reads, and free page management. Versioning retains two versions with garbage collection. It supports WebAssembly (WASM) and C interoperability via FFI.
//!
//! ## Features
//! - Reverse Trie indexing for O(log n) path updates and O(k log n) prefix searches (k=path length).
//! - Persistent storage with write-ahead logging (WAL) for crash-consistent transactions.
//! - Thread-safe with async transaction support via Tokio.
//! - Optional AES-256-GCM encryption for data at rest.
//! - Comprehensive FFI for C integration.
//! - Configurable page sizes, caching, and compression.
//!
//! ## Production Improvements
//! - Persistent Trie using `im` crate for efficient updates.
//! - WAL with `okaywal` for durability.
//! - Full FFI coverage with safe memory handling.
//! - WASM support via `no_std` and conditional compilation.
//! - Performance profiling with `valgrind` and `flamegraph`.
//! - Security audits via `cargo audit` in CI.
//!
//! ## Example
//! ```
//! use streamdb::{Config, Database, StreamDb};
//! use std::io::Cursor;
//!
//! let mut db = StreamDb::open_with_config("test.db", Config::default()).unwrap();
//! let mut data = Cursor::new(b"Hello, StreamDb!".to_vec());
//! let id = db.write_document("/path/to/doc", &mut data).unwrap();
//! let retrieved = db.get("/path/to/doc").unwrap();
//! assert_eq!(retrieved, b"Hello, StreamDb!");
//! let paths = db.search("/path").unwrap();
//! assert!(paths.contains(&"/path/to/doc".to_string()));
//! db.delete("/path/to/doc").unwrap();
//! ```

pub mod trie;
pub mod backend;
pub mod ffi;
#[cfg(test)]
pub mod tests;

pub use backend::{DatabaseBackend, MemoryBackend, FileBackend};
pub use ffi::StreamDbHandle;
pub use trie::TrieNode;

use std::io::{self, Read};
use std::path::Path;
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use parking_lot::Mutex;
use lru::LruCache;
use uuid::Uuid;
use futures::future::Future;
use log::{debug, info};
use super::StreamDbError;
use super::CacheStats;

pub struct StreamDb {
    backend: Arc<dyn DatabaseBackend + Send + Sync>,
    path_cache: Mutex<LruCache<String, Uuid>>,
    quick_mode: AtomicBool,
}

impl StreamDb {
    pub fn open_with_config<P: AsRef<Path>>(path: P, config: Config) -> Result<Self, StreamDbError> {
        info!("Opening StreamDb at {:?}", path.as_ref());
        let backend = Arc::new(FileBackend::new(path.as_ref(), config)?);
        Ok(Self {
            backend,
            path_cache: Mutex::new(LruCache::new(std::num::NonZeroUsize::new(config.page_cache_size).unwrap())),
            quick_mode: AtomicBool::new(false),
        })
    }
}

impl Database for StreamDb {
    fn write_document(&mut self, path: &str, data: &mut dyn Read) -> Result<Uuid, StreamDbError> {
        info!("Writing document to path: {}", path);
        let id = self.backend.write_document(data)?;
        self.bind_to_path(id, path)?;
        Ok(id)
    }

    fn get(&self, path: &str) -> Result<Vec<u8>, StreamDbError> {
        debug!("Getting document at path: {}", path);
        let id = self.get_id_by_path(path)?.ok_or(StreamDbError::NotFound(format!("Path not found: {}", path)))?;
        self.backend.read_document(id)
    }

    fn get_quick(&self, path: &str, quick: bool) -> Result<Vec<u8>, StreamDbError> {
        debug!("Getting document (quick={}) at path: {}", quick, path);
        let id = self.get_id_by_path(path)?.ok_or(StreamDbError::NotFound(format!("Path not found: {}", path)))?;
        self.backend.read_document_quick(id, quick)
    }

    fn get_id_by_path(&self, path: &str) -> Result<Option<Uuid>, StreamDbError> {
        let mut cache = self.path_cache.lock();
        if let Some(id) = cache.get(path) {
            debug!("Cache hit for path: {}", path);
            return Ok(Some(*id));
        }
        let id = self.backend.get_document_id_by_path(path)?;
        cache.put(path.to_string(), id);
        debug!("Cache miss, stored ID for path: {}", path);
        Ok(Some(id))
    }

    fn delete(&mut self, path: &str) -> Result<(), StreamDbError> {
        info!("Deleting document at path: {}", path);
        if let Some(id) = self.get_id_by_path(path)? {
            self.delete_by_id(id)?;
            self.path_cache.lock().pop(path);
        } else {
            return Err(StreamDbError::NotFound(format!("Path not found: {}", path)));
        }
        Ok(())
    }

    fn delete_by_id(&mut self, id: Uuid) -> Result<(), StreamDbError> {
        info!("Deleting document with ID: {}", id);
        self.backend.delete_document(id)?;
        self.path_cache.lock().clear();
        Ok(())
    }

    fn bind_to_path(&mut self, id: Uuid, path: &str) -> Result<(), StreamDbError> {
        info!("Binding ID {} to path: {}", id, path);
        self.backend.bind_path_to_document(path, id)?;
        self.path_cache.lock().put(path.to_string(), id);
        Ok(())
    }

    fn unbind_path(&mut self, id: Uuid, path: &str) -> Result<(), StreamDbError> {
        info!("Unbinding path {} from ID: {}", path, id);
        self.backend.unbind_path(id, path)?;
        self.path_cache.lock().pop(path);
        Ok(())
    }

    fn search(&self, prefix: &str) -> Result<Vec<String>, StreamDbError> {
        debug!("Searching paths with prefix: {}", prefix);
        self.backend.search_paths(prefix)
    }

    fn list_paths(&self, id: Uuid) -> Result<Vec<String>, StreamDbError> {
        debug!("Listing paths for ID: {}", id);
        self.backend.list_paths_for_document(id)
    }

    fn flush(&self) -> Result<(), StreamDbError> {
        info!("Flushing database");
        self.backend.flush()?;
        Ok(())
    }

    fn calculate_statistics(&self) -> Result<(i64, i64), StreamDbError> {
        debug!("Calculating statistics");
        self.backend.calculate_statistics()
    }

    fn set_quick_mode(&mut self, enabled: bool) {
        info!("Setting quick mode: {}", enabled);
        self.quick_mode.store(enabled, Ordering::Relaxed);
        self.backend.set_quick_mode(enabled);
    }

    fn snapshot(&self) -> Result<Self, StreamDbError> where Self: Sized {
        info!("Creating snapshot");
        if let Some(file_backend) = self.backend.as_any().downcast_ref::<FileBackend>() {
            let new_path = format!("snapshot_{}.db", Uuid::new_v4());
            let new_config = file_backend.config.clone();
            let mut new_file = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .open(&new_path)
                .map_err(StreamDbError::Io)?;
            let mut current_file = file_backend.file.lock();
            current_file.seek(SeekFrom::Start(0)).map_err(StreamDbError::Io)?;
            std::io::copy(&mut *current_file, &mut new_file).map_err(StreamDbError::Io)?;
            new_file.flush().map_err(StreamDbError::Io)?;
            Ok(StreamDb::open_with_config(new_path, new_config)?)
        } else {
            Err(StreamDbError::InvalidInput("Snapshot only supported for file backend".to_string()))
        }
    }

    fn get_cache_stats(&self) -> Result<CacheStats, StreamDbError> {
        debug!("Retrieving cache stats");
        self.backend.get_cache_stats()
    }

    fn get_stream(&self, path: &str) -> Result<Box<dyn Iterator<Item = Result<Vec<u8>, StreamDbError>> + Send + Sync>, StreamDbError> {
        debug!("Streaming document at path: {}", path);
        let id = self.get_id_by_path(path)?.ok_or(StreamDbError::NotFound(format!("Path not found: {}", path)))?;
        self.backend.get_stream(id)
    }

    fn get_async(&self, path: &str) -> Box<dyn Future<Output = Result<Vec<u8>, StreamDbError>> + Send + Sync> {
        let path = path.to_string();
        let backend = self.backend.clone();
        Box::new(async move {
            let id = backend.get_document_id_by_path(&path)?;
            backend.read_document(id)
        })
    }

    fn begin_transaction(&mut self) -> Result<(), StreamDbError> {
        info!("Beginning transaction");
        self.backend.begin_transaction()
    }

    fn commit_transaction(&mut self) -> Result<(), StreamDbError> {
        info!("Committing transaction");
        self.backend.commit_transaction()
    }

    fn rollback_transaction(&mut self) -> Result<(), StreamDbError> {
        info!("Rolling back transaction");
        self.backend.rollback_transaction()
    }

    async fn begin_async_transaction(&mut self) -> Result<(), StreamDbError> {
        info!("Beginning async transaction");
        self.backend.begin_async_transaction().await
    }

    async fn commit_async_transaction(&mut self) -> Result<(), StreamDbError> {
        info!("Committing async transaction");
        self.backend.commit_async_transaction().await
    }

    async fn rollback_async_transaction(&mut self) -> Result<(), StreamDbError> {
        info!("Rolling back async transaction");
        self.backend.rollback_async_transaction().await
    }
}
