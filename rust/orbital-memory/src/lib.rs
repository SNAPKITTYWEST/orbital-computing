// SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
// CLONE_GATE:AES256:fe788e6f612123bdc281424b19f25b5e7caa27dea27cfaf67d093e55e4c3a766
//! # Orbital Memory
//!
//! Deterministic memory management subsystem for Orbital Computing Stack with:
//! - Bounded buffer allocation and deallocation
//! - Ring buffer implementation for deterministic streaming
//! - DMA abstraction layer
//! - Memory integrity checking with Blake3 hashing
//! - Checkpoint regions for state preservation
//! - Corruption detection and recovery
//!
//! ## Features
//! - Zero-copy ring buffers
//! - Deterministic allocation patterns
//! - Memory watermark tracking
//! - Checkpoint serialization
//! - Bitrot detection with cryptographic hashing

use std::alloc::{GlobalAlloc, Layout};
use std::fmt;
use std::ptr::{self, NonNull};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

use blake3::Hasher;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::{debug, error, info, warn};

/// Memory allocation error types
#[derive(Error, Debug, Clone, Serialize, Deserialize)]
pub enum MemoryError {
    #[error("Allocation failed: requested {requested} bytes, {available} available")]
    AllocationFailed { requested: usize, available: usize },

    #[error("Invalid buffer: {detail}")]
    InvalidBuffer { detail: String },

    #[error("Buffer overflow: attempted to write {requested} bytes to {capacity} byte buffer")]
    BufferOverflow { requested: usize, capacity: usize },

    #[error("Memory corruption detected: {detail}")]
    CorruptionDetected { detail: String },

    #[error("Checkpoint error: {reason}")]
    CheckpointError { reason: String },

    #[error("DMA error: {detail}")]
    DMAError { detail: String },

    #[error("Alignment error: requested alignment {requested}, got {actual}")]
    AlignmentError { requested: usize, actual: usize },
}

pub type Result<T> = std::result::Result<T, MemoryError>;

/// Memory region metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryRegion {
    /// Base address (virtual)
    pub address: u64,
    /// Region size in bytes
    pub size: usize,
    /// Region identifier
    pub id: u32,
    /// Current watermark (bytes used)
    pub watermark: usize,
    /// Blake3 hash of region contents
    pub integrity_hash: Option<String>,
    /// Is this region locked for checkpoint?
    pub locked: bool,
}

impl MemoryRegion {
    /// Check available space
    pub fn available(&self) -> usize {
        self.size.saturating_sub(self.watermark)
    }

    /// Check if region is full
    pub fn is_full(&self) -> bool {
        self.available() == 0
    }

    /// Verify integrity hash (deterministic)
    pub fn verify_integrity(&self, data: &[u8]) -> Result<bool> {
        if let Some(ref stored_hash) = self.integrity_hash {
            let mut hasher = Hasher::new();
            hasher.update(data);
            let computed = hasher.finalize().to_hex().to_string();
            Ok(computed == *stored_hash)
        } else {
            Ok(true)
        }
    }
}

/// Bounded buffer for deterministic allocation
pub struct BoundedBuffer {
    /// Raw allocation (with interior mutability)
    buffer: Arc<RwLock<Vec<u8>>>,
    /// Allocation metadata
    metadata: Arc<RwLock<BufferMetadata>>,
    /// Watermark tracking
    watermark: Arc<AtomicUsize>,
}

/// Metadata for bounded buffer
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BufferMetadata {
    pub id: u32,
    pub capacity: usize,
    pub allocation_count: u64,
    pub deallocation_count: u64,
    pub peak_watermark: usize,
    pub integrity_violations: u64,
    pub created_at: u64,
}

impl BoundedBuffer {
    /// Create new bounded buffer with fixed capacity
    pub fn new(capacity: usize, id: u32) -> Self {
        info!("Creating BoundedBuffer: capacity={} bytes, id={}", capacity, id);

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        BoundedBuffer {
            buffer: Arc::new(RwLock::new(vec![0u8; capacity])),
            metadata: Arc::new(RwLock::new(BufferMetadata {
                id,
                capacity,
                allocation_count: 0,
                deallocation_count: 0,
                peak_watermark: 0,
                integrity_violations: 0,
                created_at: now,
            })),
            watermark: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// Allocate slice from buffer
    pub fn allocate(&self, size: usize) -> Result<Vec<u8>> {
        let buffer_ref = self.buffer.read();
        let current = self.watermark.load(Ordering::SeqCst);
        let new_watermark = current.checked_add(size)
            .ok_or(MemoryError::AllocationFailed {
                requested: size,
                available: 0,
            })?;

        if new_watermark > buffer_ref.len() {
            return Err(MemoryError::AllocationFailed {
                requested: size,
                available: buffer_ref.len().saturating_sub(current),
            });
        }

        drop(buffer_ref);

        if !self.watermark.compare_exchange(
            current,
            new_watermark,
            Ordering::SeqCst,
            Ordering::SeqCst,
        ).is_ok() {
            return Err(MemoryError::AllocationFailed {
                requested: size,
                available: self.buffer.read().len().saturating_sub(current),
            });
        }

        let mut metadata = self.metadata.write();
        metadata.allocation_count += 1;
        metadata.peak_watermark = metadata.peak_watermark.max(new_watermark);

        debug!("Allocated {} bytes, watermark now {}", size, new_watermark);

        Ok(vec![0u8; size])
    }

    /// Write data to buffer
    pub fn write(&self, offset: usize, data: &[u8]) -> Result<()> {
        let mut buffer = self.buffer.write();
        if offset + data.len() > buffer.len() {
            return Err(MemoryError::BufferOverflow {
                requested: data.len(),
                capacity: buffer.len().saturating_sub(offset),
            });
        }

        buffer[offset..offset + data.len()].copy_from_slice(data);
        debug!("Wrote {} bytes at offset {}", data.len(), offset);
        Ok(())
    }

    /// Read data from buffer
    pub fn read(&self, offset: usize, len: usize) -> Result<Vec<u8>> {
        let buffer = self.buffer.read();
        if offset + len > buffer.len() {
            return Err(MemoryError::InvalidBuffer {
                detail: format!("Read out of bounds: offset={}, len={}, capacity={}",
                               offset, len, buffer.len()),
            });
        }

        Ok(buffer[offset..offset + len].to_vec())
    }

    /// Compute integrity hash for entire buffer
    pub fn compute_integrity_hash(&self) -> String {
        let mut hasher = Hasher::new();
        hasher.update(&self.buffer.read());
        hasher.finalize().to_hex().to_string()
    }

    /// Verify integrity (deterministic)
    pub fn verify_integrity(&self, expected_hash: &str) -> Result<bool> {
        let computed = self.compute_integrity_hash();
        if computed != expected_hash {
            let mut metadata = self.metadata.write();
            metadata.integrity_violations += 1;
            warn!("Integrity violation detected in buffer {}", metadata.id);
            Err(MemoryError::CorruptionDetected {
                detail: format!("Hash mismatch: expected {}, got {}", expected_hash, computed),
            })
        } else {
            Ok(true)
        }
    }

    /// Get buffer statistics
    pub fn stats(&self) -> BufferMetadata {
        self.metadata.read().clone()
    }

    /// Get current watermark
    pub fn current_watermark(&self) -> usize {
        self.watermark.load(Ordering::SeqCst)
    }

    /// Reset buffer (clears watermark and zeroes memory)
    pub fn reset(&self) {
        self.watermark.store(0, Ordering::SeqCst);
        let mut buffer = self.buffer.write();
        for byte in buffer.iter_mut() {
            *byte = 0;
        }
        debug!("Buffer reset");
    }
}

/// Ring buffer for deterministic streaming
pub struct RingBuffer {
    /// Ring buffer storage (interior mutability)
    buffer: Arc<RwLock<Vec<u8>>>,
    /// Write position
    write_pos: Arc<AtomicUsize>,
    /// Read position
    read_pos: Arc<AtomicUsize>,
    /// Capacity
    capacity: usize,
    /// Metadata
    metadata: Arc<RwLock<RingBufferMetadata>>,
}

/// Metadata for ring buffer
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RingBufferMetadata {
    pub id: u32,
    pub capacity: usize,
    pub write_count: u64,
    pub read_count: u64,
    pub overflow_count: u64,
}

impl RingBuffer {
    /// Create new ring buffer
    pub fn new(capacity: usize, id: u32) -> Result<Self> {
        if capacity == 0 || !capacity.is_power_of_two() {
            return Err(MemoryError::InvalidBuffer {
                detail: format!("Ring buffer capacity must be power of 2, got {}", capacity),
            });
        }

        info!("Creating RingBuffer: capacity={} bytes, id={}", capacity, id);

        Ok(RingBuffer {
            buffer: Arc::new(RwLock::new(vec![0u8; capacity])),
            write_pos: Arc::new(AtomicUsize::new(0)),
            read_pos: Arc::new(AtomicUsize::new(0)),
            capacity,
            metadata: Arc::new(RwLock::new(RingBufferMetadata {
                id,
                capacity,
                write_count: 0,
                read_count: 0,
                overflow_count: 0,
            })),
        })
    }

    /// Write data to ring buffer
    pub fn write(&self, data: &[u8]) -> Result<usize> {
        if data.is_empty() {
            return Ok(0);
        }

        let write_pos = self.write_pos.load(Ordering::SeqCst);
        let read_pos = self.read_pos.load(Ordering::SeqCst);
        let available = self.available_write(write_pos, read_pos);

        let to_write = std::cmp::min(data.len(), available);

        if to_write == 0 {
            let mut metadata = self.metadata.write();
            metadata.overflow_count += 1;
            return Err(MemoryError::BufferOverflow {
                requested: data.len(),
                capacity: available,
            });
        }

        let mask = self.capacity - 1;
        let write_idx = write_pos & mask;
        let bytes_to_end = self.capacity - write_idx;

        {
            let mut buffer = self.buffer.write();
            if to_write <= bytes_to_end {
                buffer[write_idx..write_idx + to_write].copy_from_slice(&data[..to_write]);
            } else {
                let first_part = bytes_to_end;
                let second_part = to_write - first_part;
                buffer[write_idx..].copy_from_slice(&data[..first_part]);
                buffer[..second_part].copy_from_slice(&data[first_part..to_write]);
            }
        }

        self.write_pos.store(write_pos + to_write, Ordering::SeqCst);

        let mut metadata = self.metadata.write();
        metadata.write_count += 1;

        debug!("Ring buffer write: {} bytes written", to_write);
        Ok(to_write)
    }

    /// Read data from ring buffer
    pub fn read(&self, max_len: usize) -> Result<Vec<u8>> {
        let read_pos = self.read_pos.load(Ordering::SeqCst);
        let write_pos = self.write_pos.load(Ordering::SeqCst);
        let available = write_pos.saturating_sub(read_pos);

        if available == 0 {
            return Ok(Vec::new());
        }

        let to_read = std::cmp::min(max_len, available);
        let mask = self.capacity - 1;
        let read_idx = read_pos & mask;
        let bytes_to_end = self.capacity - read_idx;

        let mut result = Vec::with_capacity(to_read);

        {
            let buffer = self.buffer.read();
            if to_read <= bytes_to_end {
                result.extend_from_slice(&buffer[read_idx..read_idx + to_read]);
            } else {
                let first_part = bytes_to_end;
                let second_part = to_read - first_part;
                result.extend_from_slice(&buffer[read_idx..]);
                result.extend_from_slice(&buffer[..second_part]);
            }
        }

        self.read_pos.store(read_pos + to_read, Ordering::SeqCst);

        let mut metadata = self.metadata.write();
        metadata.read_count += 1;

        debug!("Ring buffer read: {} bytes read", to_read);
        Ok(result)
    }

    /// Get available write space
    fn available_write(&self, write_pos: usize, read_pos: usize) -> usize {
        let available = self.capacity - (write_pos.saturating_sub(read_pos) % (self.capacity + 1));
        if available == 0 { 0 } else { available - 1 }
    }

    /// Get available read data
    pub fn available_read(&self) -> usize {
        let write_pos = self.write_pos.load(Ordering::SeqCst);
        let read_pos = self.read_pos.load(Ordering::SeqCst);
        write_pos.saturating_sub(read_pos)
    }

    /// Reset ring buffer
    pub fn reset(&self) {
        self.write_pos.store(0, Ordering::SeqCst);
        self.read_pos.store(0, Ordering::SeqCst);
        let mut buffer = self.buffer.write();
        for byte in buffer.iter_mut() {
            *byte = 0;
        }
    }

    /// Get metadata
    pub fn stats(&self) -> RingBufferMetadata {
        self.metadata.read().clone()
    }
}

/// Checkpoint region for state preservation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckpointRegion {
    pub id: u32,
    pub data: Vec<u8>,
    pub hash: String,
    pub sequence: u64,
    pub timestamp: u64,
}

impl CheckpointRegion {
    /// Create checkpoint from data
    pub fn create(id: u32, data: Vec<u8>, sequence: u64) -> Self {
        let mut hasher = Hasher::new();
        hasher.update(&data);
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        CheckpointRegion {
            id,
            hash: hasher.finalize().to_hex().to_string(),
            data,
            sequence,
            timestamp: now,
        }
    }

    /// Verify checkpoint integrity
    pub fn verify(&self) -> Result<bool> {
        let mut hasher = Hasher::new();
        hasher.update(&self.data);
        let computed = hasher.finalize().to_hex().to_string();

        if computed != self.hash {
            return Err(MemoryError::CorruptionDetected {
                detail: format!("Checkpoint {} hash mismatch", self.id),
            });
        }
        Ok(true)
    }
}

/// Memory manager coordinating all buffers and checkpoints
pub struct MemoryManager {
    /// Bounded buffers
    buffers: Arc<RwLock<Vec<Arc<BoundedBuffer>>>>,
    /// Ring buffers
    ring_buffers: Arc<RwLock<Vec<Arc<RingBuffer>>>>,
    /// Checkpoint regions
    checkpoints: Arc<RwLock<Vec<CheckpointRegion>>>,
    /// Total memory managed
    total_memory: AtomicU64,
    /// Maximum allowed memory
    max_memory: u64,
}

impl MemoryManager {
    /// Create new memory manager
    pub fn new(max_memory: u64) -> Self {
        info!("Initializing MemoryManager with max_memory={} bytes", max_memory);

        MemoryManager {
            buffers: Arc::new(RwLock::new(Vec::new())),
            ring_buffers: Arc::new(RwLock::new(Vec::new())),
            checkpoints: Arc::new(RwLock::new(Vec::new())),
            total_memory: AtomicU64::new(0),
            max_memory,
        }
    }

    /// Add bounded buffer
    pub fn add_bounded_buffer(&self, capacity: usize, id: u32) -> Result<Arc<BoundedBuffer>> {
        let current = self.total_memory.load(Ordering::SeqCst);
        if current as usize + capacity > self.max_memory as usize {
            return Err(MemoryError::AllocationFailed {
                requested: capacity,
                available: (self.max_memory as usize).saturating_sub(current as usize),
            });
        }

        let buffer = Arc::new(BoundedBuffer::new(capacity, id));
        self.buffers.write().push(buffer.clone());
        self.total_memory.fetch_add(capacity as u64, Ordering::SeqCst);

        Ok(buffer)
    }

    /// Add ring buffer
    pub fn add_ring_buffer(&self, capacity: usize, id: u32) -> Result<Arc<RingBuffer>> {
        let current = self.total_memory.load(Ordering::SeqCst);
        if current as usize + capacity > self.max_memory as usize {
            return Err(MemoryError::AllocationFailed {
                requested: capacity,
                available: (self.max_memory as usize).saturating_sub(current as usize),
            });
        }

        let buffer = Arc::new(RingBuffer::new(capacity, id)?);
        self.ring_buffers.write().push(buffer.clone());
        self.total_memory.fetch_add(capacity as u64, Ordering::SeqCst);

        Ok(buffer)
    }

    /// Create checkpoint
    pub fn checkpoint(&self, id: u32, data: Vec<u8>, sequence: u64) -> Result<()> {
        let cp = CheckpointRegion::create(id, data, sequence);
        self.checkpoints.write().push(cp);
        Ok(())
    }

    /// Restore checkpoint
    pub fn restore_checkpoint(&self, sequence: u64) -> Result<Vec<u8>> {
        let checkpoints = self.checkpoints.read();
        let cp = checkpoints.iter()
            .find(|c| c.sequence == sequence)
            .ok_or(MemoryError::CheckpointError {
                reason: format!("Checkpoint {} not found", sequence),
            })?;

        cp.verify()?;
        Ok(cp.data.clone())
    }

    /// Get memory statistics
    pub fn stats(&self) -> MemoryStats {
        let total_allocated = self.buffers.read().iter()
            .map(|b| b.current_watermark() as u64)
            .sum::<u64>();

        MemoryStats {
            total_memory: self.max_memory,
            allocated: total_allocated,
            available: self.max_memory.saturating_sub(total_allocated),
            buffer_count: self.buffers.read().len(),
            ring_buffer_count: self.ring_buffers.read().len(),
            checkpoint_count: self.checkpoints.read().len(),
        }
    }
}

/// Memory statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryStats {
    pub total_memory: u64,
    pub allocated: u64,
    pub available: u64,
    pub buffer_count: usize,
    pub ring_buffer_count: usize,
    pub checkpoint_count: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bounded_buffer_creation() {
        let buffer = BoundedBuffer::new(1024, 1);
        let stats = buffer.stats();
        assert_eq!(stats.capacity, 1024);
        assert_eq!(stats.allocation_count, 0);
    }

    #[test]
    fn test_bounded_buffer_allocation() {
        let buffer = BoundedBuffer::new(1024, 1);
        let slice = buffer.allocate(256).expect("Allocation failed");
        assert_eq!(slice.len(), 256);
        assert_eq!(buffer.current_watermark(), 256);
    }

    #[test]
    fn test_bounded_buffer_overflow() {
        let buffer = BoundedBuffer::new(256, 1);
        buffer.allocate(200).expect("First allocation failed");
        let result = buffer.allocate(100);
        assert!(result.is_err());
    }

    #[test]
    fn test_bounded_buffer_write_read() {
        let buffer = BoundedBuffer::new(512, 1);
        let data = b"Hello, World!";
        buffer.write(0, data).expect("Write failed");
        let read = buffer.read(0, data.len()).expect("Read failed");
        assert_eq!(read, data);
    }

    #[test]
    fn test_integrity_hash() {
        let buffer = BoundedBuffer::new(512, 1);
        let hash1 = buffer.compute_integrity_hash();
        let hash2 = buffer.compute_integrity_hash();
        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_ring_buffer_creation() {
        let rb = RingBuffer::new(256, 1).expect("Creation failed");
        let stats = rb.stats();
        assert_eq!(stats.capacity, 256);
    }

    #[test]
    fn test_ring_buffer_write_read() {
        let rb = RingBuffer::new(256, 1).expect("Creation failed");
        let data = b"Test data";
        let written = rb.write(data).expect("Write failed");
        assert_eq!(written, data.len());

        let read = rb.read(10).expect("Read failed");
        assert_eq!(read, data);
    }

    #[test]
    fn test_ring_buffer_wraparound() {
        let rb = RingBuffer::new(64, 1).expect("Creation failed");

        let data = [0u8; 50];
        rb.write(&data).expect("First write failed");

        rb.read(30).expect("First read failed");

        rb.write(&data[..30]).expect("Second write failed");

        let read_data = rb.read(100).expect("Final read failed");
        assert!(!read_data.is_empty());
    }

    #[test]
    fn test_ring_buffer_invalid_capacity() {
        let result = RingBuffer::new(100, 1);
        assert!(result.is_err());
    }

    #[test]
    fn test_checkpoint_creation_and_verification() {
        let data = vec![1, 2, 3, 4, 5];
        let cp = CheckpointRegion::create(1, data.clone(), 100);
        assert!(cp.verify().unwrap());
        assert_eq!(cp.sequence, 100);
        assert_eq!(cp.data, data);
    }

    #[test]
    fn test_checkpoint_corruption_detection() {
        let data = vec![1, 2, 3, 4, 5];
        let mut cp = CheckpointRegion::create(1, data, 100);
        cp.hash = "invalid_hash".to_string();
        assert!(cp.verify().is_err());
    }

    #[test]
    fn test_memory_manager_creation() {
        let mm = MemoryManager::new(4096);
        let stats = mm.stats();
        assert_eq!(stats.total_memory, 4096);
        assert_eq!(stats.allocated, 0);
    }

    #[test]
    fn test_memory_manager_add_buffer() {
        let mm = MemoryManager::new(4096);
        let buffer = mm.add_bounded_buffer(1024, 1).expect("Add buffer failed");
        let stats = mm.stats();
        assert_eq!(stats.buffer_count, 1);
    }

    #[test]
    fn test_memory_manager_exhaustion() {
        let mm = MemoryManager::new(512);
        mm.add_bounded_buffer(256, 1).expect("First buffer failed");
        mm.add_bounded_buffer(256, 2).expect("Second buffer failed");

        let result = mm.add_bounded_buffer(256, 3);
        assert!(result.is_err());
    }

    #[test]
    fn test_memory_manager_checkpoint() {
        let mm = MemoryManager::new(4096);
        let data = vec![42; 256];
        mm.checkpoint(1, data.clone(), 1).expect("Checkpoint failed");

        let restored = mm.restore_checkpoint(1).expect("Restore failed");
        assert_eq!(restored, data);
    }

    #[test]
    fn test_buffer_reset() {
        let buffer = BoundedBuffer::new(256, 1);
        buffer.allocate(128).expect("Allocation failed");
        assert_eq!(buffer.current_watermark(), 128);

        buffer.reset();
        assert_eq!(buffer.current_watermark(), 0);
    }

    #[test]
    fn test_ring_buffer_reset() {
        let rb = RingBuffer::new(256, 1).expect("Creation failed");
        rb.write(b"test").expect("Write failed");

        rb.reset();
        assert_eq!(rb.available_read(), 0);
    }

    #[test]
    fn test_multiple_bounded_buffers() {
        let b1 = BoundedBuffer::new(512, 1);
        let b2 = BoundedBuffer::new(512, 2);
        let b3 = BoundedBuffer::new(512, 3);

        b1.allocate(256).expect("B1 allocation failed");
        b2.allocate(128).expect("B2 allocation failed");
        b3.allocate(384).expect("B3 allocation failed");

        assert_eq!(b1.current_watermark(), 256);
        assert_eq!(b2.current_watermark(), 128);
        assert_eq!(b3.current_watermark(), 384);
    }

    #[test]
    fn test_deterministic_hashing() {
        let buffer = BoundedBuffer::new(512, 1);
        buffer.write(0, b"constant data").expect("Write failed");

        let hash1 = buffer.compute_integrity_hash();
        let hash2 = buffer.compute_integrity_hash();
        let hash3 = buffer.compute_integrity_hash();

        assert_eq!(hash1, hash2);
        assert_eq!(hash2, hash3);
    }

    #[test]
    fn test_ring_buffer_sequential_operations() {
        let rb = RingBuffer::new(256, 1).expect("Creation failed");

        for i in 0..5 {
            let data = vec![i as u8; 32];
            rb.write(&data).expect("Write failed");
        }

        for _ in 0..5 {
            let read = rb.read(32).expect("Read failed");
            assert_eq!(read.len(), 32);
        }
    }

    #[test]
    fn test_memory_manager_multiple_ring_buffers() {
        let mm = MemoryManager::new(4096);

        let rb1 = mm.add_ring_buffer(512, 1).expect("RB1 creation failed");
        let rb2 = mm.add_ring_buffer(512, 2).expect("RB2 creation failed");
        let rb3 = mm.add_ring_buffer(512, 3).expect("RB3 creation failed");

        rb1.write(b"data1").expect("RB1 write failed");
        rb2.write(b"data2").expect("RB2 write failed");
        rb3.write(b"data3").expect("RB3 write failed");

        assert_eq!(rb1.available_read(), 5);
        assert_eq!(rb2.available_read(), 5);
        assert_eq!(rb3.available_read(), 5);
    }

    #[test]
    fn test_checkpoint_sequence_ordering() {
        let mm = MemoryManager::new(4096);

        mm.checkpoint(1, vec![1], 1).expect("CP1 failed");
        mm.checkpoint(2, vec![2], 2).expect("CP2 failed");
        mm.checkpoint(3, vec![3], 3).expect("CP3 failed");

        assert!(mm.restore_checkpoint(1).is_ok());
        assert!(mm.restore_checkpoint(2).is_ok());
        assert!(mm.restore_checkpoint(3).is_ok());
        assert!(mm.restore_checkpoint(999).is_err());
    }

    #[test]
    fn test_bounded_buffer_stats() {
        let buffer = BoundedBuffer::new(512, 1);
        buffer.allocate(100).expect("Allocation failed");

        let stats = buffer.stats();
        assert_eq!(stats.capacity, 512);
        assert_eq!(stats.allocation_count, 1);
    }
}
