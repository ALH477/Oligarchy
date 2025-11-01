//! Tests for StreamDb.
//!
//! This module contains unit tests, integration tests, and benchmarks for StreamDb. It uses `proptest`
//! for property-based testing of Trie operations, integration tests for end-to-end workflows, and Criterion
//! for performance benchmarks comparing to `sled`. WASM-specific tests ensure compatibility in `wasm32` targets.

use super::*;
use criterion::{Criterion, criterion_group, criterion_main};
use proptest::prelude::*;
use sled;
use std::io::Cursor;

proptest! {
    #[test]
    fn prop_insert_delete_search(path in "[a-zA-Z0-9/]{1,100}", id in any::<Uuid>()) {
        let mut backend = MemoryBackend::new("test.wal").unwrap();
        backend.bind_path_to_document(&path, id).unwrap();
        prop_assert_eq!(backend.get_document_id_by_path(&path).unwrap(), id);
        let prefix = &path[0..path.len()/2];
        let results = backend.search_paths(prefix).unwrap();
        prop_assert!(results.contains(&path));
        backend.delete_paths_for_document(id).unwrap();
        prop_assert!(backend.get_document_id_by_path(&path).is_err());
    }

    #[test]
    fn prop_transaction_commit_rollback(path in "[a-zA-Z0-9/]{1,100}", data in prop::collection::vec(any::<u8>(), 1..1024), id in any::<Uuid>()) {
        let mut backend = MemoryBackend::new("test.wal").unwrap();
        backend.begin_transaction().unwrap();
        backend.bind_path_to_document(&path, id).unwrap();
        backend.write_document(&mut Cursor::new(data.clone())).unwrap();
        backend.rollback_transaction().unwrap();
        prop_assert!(backend.get_document_id_by_path(&path).is_err());
        backend.begin_transaction().unwrap();
        backend.write_document(&mut Cursor::new(data.clone())).unwrap();
        backend.commit_transaction().unwrap();
        prop_assert_eq!(backend.read_document(id).unwrap(), data);
    }
}

#[test]
fn test_backend_integration() {
    let mut backend = MemoryBackend::new("test.wal").unwrap();
    let id = backend.write_document(&mut Cursor::new(b"data")).unwrap();
    backend.bind_path_to_document("path/to/doc", id).unwrap();
    assert_eq!(backend.get_document_id_by_path("path/to/doc").unwrap(), id);
    assert_eq!(backend.read_document(id).unwrap(), b"data");
    backend.delete_paths_for_document(id).unwrap();
    assert!(backend.get_document_id_by_path("path/to/doc").is_err());
}

#[test]
fn test_file_backend_persistence() {
    let config = Config::default();
    let mut db = StreamDb::open_with_config("test.db", config).unwrap();
    let id = db.write_document("/path/to/doc", &mut Cursor::new(b"data")).unwrap();
    db.flush().unwrap();
    drop(db);
    let db = StreamDb::open_with_config("test.db", Config::default()).unwrap();
    assert_eq!(db.get("/path/to/doc").unwrap(), b"data");
    db.delete("/path/to/doc").unwrap();
}

#[cfg(target_arch = "wasm32")]
#[test]
fn test_wasm_file_backend() {
    let config = Config {
        use_mmap: false, // No mmap in WASM
        ..Config::default()
    };
    let mut db = StreamDb::open_with_config("test.wasm.db", config).unwrap();
    let id = db.write_document("/path/to/doc", &mut Cursor::new(b"data")).unwrap();
    assert_eq!(db.get("/path/to/doc").unwrap(), b"data");
    db.delete("/path/to/doc").unwrap();
    assert!(db.get("/path/to/doc").is_err());
}

fn criterion_benchmark(c: &mut Criterion) {
    c.bench_function("streamdb_insert", |b| {
        let mut db = StreamDb::open_with_config("test.db", Config::default()).unwrap();
        b.iter(|| {
            let data = vec![0u8; 1024];
            let mut cursor = Cursor::new(&data);
            db.write_document("path/to/doc", &mut cursor).unwrap();
        });
    });

    c.bench_function("sled_insert", |b| {
        let sled_db = sled::open("test_sled.db").unwrap();
        b.iter(|| {
            sled_db.insert(b"path/to/doc", vec![0u8; 1024]).unwrap();
        });
    });

    c.bench_function("streamdb_get_quick", |b| {
        let mut db = StreamDb::open_with_config("test.db", Config::default()).unwrap();
        let mut cursor = Cursor::new(vec![0u8; 1024]);
        db.write_document("path/to/doc", &mut cursor).unwrap();
        db.set_quick_mode(true);
        b.iter(|| {
            db.get_quick("path/to/doc", true).unwrap();
        });
    });
}

criterion_group!(benches, criterion_benchmark);
criterion_main!(benches);
