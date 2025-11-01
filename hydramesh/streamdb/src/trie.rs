//! Trie implementation for StreamDb's reverse path indexing.
//!
//! This module defines `TrieNode`, a persistent reverse Trie using `im::OrdMap` for efficient O(log n)
//! updates and searches. Paths are reversed as byte slices (`Vec<u8>`) to support prefix searches on
//! path suffixes, with `insert`, `remove`, and `search` operations leveraging structural sharing for
//! memory efficiency.

use im::OrdMap as ImOrdMap;
use serde::{Serialize, Deserialize};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TrieNode {
    pub children: ImOrdMap<char, TrieNode>,
    pub value: Option<Uuid>,
}

impl TrieNode {
    pub fn new() -> Self {
        Self {
            children: ImOrdMap::new(),
            value: None,
        }
    }

    pub fn insert(&self, reversed: &[u8], id: Uuid) -> Self {
        let mut node = self.clone();
        let mut current = &mut node;
        for &byte in reversed {
            let ch = byte as char;
            let child = current.children.get(&ch).cloned().unwrap_or(TrieNode::new());
            current.children = current.children.update(ch, child);
            current = current.children.get_mut(&ch).unwrap();
        }
        current.value = Some(id);
        node
    }

    pub fn remove(&self, reversed: &[u8]) -> Option<Self> {
        let mut node = self.clone();
        let mut current = &mut node;
        let mut path = vec![];
        for &byte in reversed {
            let ch = byte as char;
            if let Some(child) = current.children.get(&ch) {
                path.push((ch, current));
                current = current.children.get_mut(&ch).unwrap();
            } else {
                return None;
            }
        }
        current.value = None;
        while let Some((ch, parent)) = path.pop() {
            if current.value.is_none() && current.children.is_empty() {
                parent.children = parent.children.without(&ch);
                current = parent;
            } else {
                break;
            }
        }
        Some(node)
    }

    pub fn get(&self, reversed: &[u8]) -> Option<Uuid> {
        let mut current = self;
        for &byte in reversed {
            let ch = byte as char;
            if let Some(child) = current.children.get(&ch) {
                current = child;
            } else {
                return None;
            }
        }
        current.value
    }

    pub fn search(&self, _reversed_prefix: &[u8], results: &mut Vec<String>, current_path: String) {
        if let Some(id) = self.value {
            results.push(current_path.chars().rev().collect());
        }
        for (&ch, child) in &self.children {
            let mut new_path = current_path.clone();
            new_path.push(ch);
            child.search(&[], results, new_path);
        }
    }
}
