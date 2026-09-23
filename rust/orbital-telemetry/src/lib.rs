// SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
// CLONE_GATE:AES256:fe788e6f612123bdc281424b19f25b5e7caa27dea27cfaf67d093e55e4c3a766
//! # Orbital Telemetry
//!
//! Telemetry frame parsing, validation, and replay buffer:
//! - Frame parsing with structure validation
//! - Sequence number validation
//! - Timestamp validation
//! - CRC/checksum verification
//! - Duplicate detection
//! - Malformed frame rejection
//! - Replay buffer for recovery
//! - Deterministic frame processing

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use blake3::Hasher;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::{debug, warn};

/// Telemetry errors
#[derive(Error, Debug, Clone, Serialize, Deserialize)]
pub enum TelemetryError {
    #[error("Malformed frame: {reason}")]
    MalformedFrame { reason: String },

    #[error("Sequence violation: expected {expected}, got {actual}")]
    SequenceViolation { expected: u64, actual: u64 },

    #[error("Timestamp invalid: {detail}")]
    InvalidTimestamp { detail: String },

    #[error("CRC mismatch: expected {expected}, got {actual}")]
    CRCMismatch { expected: u32, actual: u32 },

    #[error("Duplicate frame detected: sequence {sequence}")]
    DuplicateFrame { sequence: u64 },

    #[error("Replay buffer full")]
    ReplayBufferFull,

    #[error("Frame not in replay buffer: {sequence}")]
    FrameNotInBuffer { sequence: u64 },
}

pub type Result<T> = std::result::Result<T, TelemetryError>;

/// Telemetry frame
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryFrame {
    /// Sequence number (monotonically increasing)
    pub sequence: u64,
    /// Timestamp (seconds since UNIX_EPOCH)
    pub timestamp: u64,
    /// Payload data
    pub payload: Vec<u8>,
    /// CRC32 checksum
    pub checksum: u32,
    /// Blake3 hash of entire frame
    pub hash: String,
}

impl TelemetryFrame {
    /// Create new frame
    pub fn new(sequence: u64, timestamp: u64, payload: Vec<u8>) -> Self {
        let checksum = Self::compute_crc32(&payload);
        let hash = Self::compute_blake3(sequence, timestamp, &payload, checksum);

        TelemetryFrame {
            sequence,
            timestamp,
            payload,
            checksum,
            hash,
        }
    }

    /// Compute CRC32 (simple checksum)
    fn compute_crc32(data: &[u8]) -> u32 {
        let mut crc: u32 = 0xFFFFFFFF;
        for byte in data {
            crc ^= *byte as u32;
            for _ in 0..8 {
                crc = if (crc & 1) != 0 {
                    (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >> 1
                };
            }
        }
        crc ^ 0xFFFFFFFF
    }

    /// Compute Blake3 hash
    fn compute_blake3(sequence: u64, timestamp: u64, payload: &[u8], checksum: u32) -> String {
        let mut hasher = Hasher::new();
        hasher.update(sequence.to_le_bytes().as_slice());
        hasher.update(timestamp.to_le_bytes().as_slice());
        hasher.update(payload);
        hasher.update(checksum.to_le_bytes().as_slice());
        hasher.finalize().to_hex().to_string()
    }

    /// Verify frame integrity
    pub fn verify(&self) -> Result<()> {
        let computed_crc = Self::compute_crc32(&self.payload);
        if computed_crc != self.checksum {
            return Err(TelemetryError::CRCMismatch {
                expected: self.checksum,
                actual: computed_crc,
            });
        }

        let computed_hash = Self::compute_blake3(self.sequence, self.timestamp, &self.payload, self.checksum);
        if computed_hash != self.hash {
            return Err(TelemetryError::MalformedFrame {
                reason: "Hash mismatch".to_string(),
            });
        }

        Ok(())
    }

    /// Get frame size
    pub fn size(&self) -> usize {
        8 + 8 + self.payload.len() + 4 + 64 // sequence + timestamp + payload + checksum + hash
    }
}

/// Telemetry processor
pub struct TelemetryProcessor {
    /// Expected next sequence number
    next_sequence: Arc<AtomicU64>,
    /// Last seen timestamps (for monotonicity check)
    last_timestamp: Arc<AtomicU64>,
    /// Seen sequences (for duplicate detection)
    seen_sequences: Arc<RwLock<Vec<u64>>>,
    /// Frame count
    frame_count: Arc<AtomicU64>,
    /// Error count
    error_count: Arc<AtomicU64>,
}

impl TelemetryProcessor {
    /// Create new processor
    pub fn new() -> Self {
        TelemetryProcessor {
            next_sequence: Arc::new(AtomicU64::new(0)),
            last_timestamp: Arc::new(AtomicU64::new(0)),
            seen_sequences: Arc::new(RwLock::new(Vec::new())),
            frame_count: Arc::new(AtomicU64::new(0)),
            error_count: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Parse and validate frame
    pub fn process_frame(&self, frame: &TelemetryFrame) -> Result<()> {
        // Verify frame integrity
        frame.verify()?;

        // Check sequence
        let expected = self.next_sequence.load(Ordering::SeqCst);
        if frame.sequence != expected {
            self.error_count.fetch_add(1, Ordering::SeqCst);
            return Err(TelemetryError::SequenceViolation {
                expected,
                actual: frame.sequence,
            });
        }

        // Check timestamp monotonicity
        let last_ts = self.last_timestamp.load(Ordering::SeqCst);
        if frame.timestamp < last_ts {
            self.error_count.fetch_add(1, Ordering::SeqCst);
            return Err(TelemetryError::InvalidTimestamp {
                detail: format!("Timestamp went backwards: {} < {}", frame.timestamp, last_ts),
            });
        }

        // Check for duplicates
        if self.seen_sequences.read().contains(&frame.sequence) {
            self.error_count.fetch_add(1, Ordering::SeqCst);
            return Err(TelemetryError::DuplicateFrame {
                sequence: frame.sequence,
            });
        }

        // Update state
        self.next_sequence.store(frame.sequence + 1, Ordering::SeqCst);
        self.last_timestamp.store(frame.timestamp, Ordering::SeqCst);
        self.seen_sequences.write().push(frame.sequence);
        self.frame_count.fetch_add(1, Ordering::SeqCst);

        debug!("Frame processed: sequence={}", frame.sequence);
        Ok(())
    }

    /// Get statistics
    pub fn stats(&self) -> TelemetryStats {
        TelemetryStats {
            frames_processed: self.frame_count.load(Ordering::SeqCst),
            errors: self.error_count.load(Ordering::SeqCst),
            next_sequence: self.next_sequence.load(Ordering::SeqCst),
            sequences_seen: self.seen_sequences.read().len(),
        }
    }
}

impl Default for TelemetryProcessor {
    fn default() -> Self {
        Self::new()
    }
}

/// Replay buffer for frame recovery
pub struct ReplayBuffer {
    /// Buffered frames
    buffer: Arc<RwLock<VecDeque<TelemetryFrame>>>,
    /// Maximum buffer size
    max_size: usize,
    /// Total frames stored
    total_stored: Arc<AtomicU64>,
}

impl ReplayBuffer {
    /// Create new replay buffer
    pub fn new(max_size: usize) -> Self {
        ReplayBuffer {
            buffer: Arc::new(RwLock::new(VecDeque::with_capacity(max_size))),
            max_size,
            total_stored: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Add frame to buffer
    pub fn add(&self, frame: TelemetryFrame) -> Result<()> {
        let mut buf = self.buffer.write();

        if buf.len() >= self.max_size {
            return Err(TelemetryError::ReplayBufferFull);
        }

        buf.push_back(frame);
        self.total_stored.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    /// Get frame by sequence
    pub fn get(&self, sequence: u64) -> Result<TelemetryFrame> {
        let buf = self.buffer.read();

        buf.iter()
            .find(|f| f.sequence == sequence)
            .cloned()
            .ok_or(TelemetryError::FrameNotInBuffer { sequence })
    }

    /// Replay from sequence
    pub fn replay_from(&self, start_sequence: u64) -> Result<Vec<TelemetryFrame>> {
        let buf = self.buffer.read();

        let frames: Vec<_> = buf.iter()
            .filter(|f| f.sequence >= start_sequence)
            .cloned()
            .collect();

        if frames.is_empty() {
            return Err(TelemetryError::FrameNotInBuffer {
                sequence: start_sequence,
            });
        }

        Ok(frames)
    }

    /// Clear buffer
    pub fn clear(&self) {
        self.buffer.write().clear();
    }

    /// Get buffer statistics
    pub fn stats(&self) -> ReplayBufferStats {
        let buf = self.buffer.read();
        ReplayBufferStats {
            current_size: buf.len(),
            max_size: self.max_size,
            total_stored: self.total_stored.load(Ordering::SeqCst),
        }
    }
}

/// Telemetry statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryStats {
    pub frames_processed: u64,
    pub errors: u64,
    pub next_sequence: u64,
    pub sequences_seen: usize,
}

/// Replay buffer statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplayBufferStats {
    pub current_size: usize,
    pub max_size: usize,
    pub total_stored: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_frame_creation() {
        let frame = TelemetryFrame::new(0, 100, vec![1, 2, 3, 4]);
        assert_eq!(frame.sequence, 0);
        assert_eq!(frame.timestamp, 100);
    }

    #[test]
    fn test_frame_verification() {
        let frame = TelemetryFrame::new(0, 100, vec![1, 2, 3, 4]);
        assert!(frame.verify().is_ok());
    }

    #[test]
    fn test_crc_mismatch() {
        let mut frame = TelemetryFrame::new(0, 100, vec![1, 2, 3, 4]);
        frame.checksum ^= 0xFFFFFFFF;
        assert!(frame.verify().is_err());
    }

    #[test]
    fn test_processor_creation() {
        let processor = TelemetryProcessor::new();
        let stats = processor.stats();
        assert_eq!(stats.frames_processed, 0);
    }

    #[test]
    fn test_process_valid_frame() {
        let processor = TelemetryProcessor::new();
        let frame = TelemetryFrame::new(0, 100, vec![1, 2, 3]);
        assert!(processor.process_frame(&frame).is_ok());
    }

    #[test]
    fn test_sequence_violation() {
        let processor = TelemetryProcessor::new();
        let frame = TelemetryFrame::new(5, 100, vec![1, 2, 3]);
        assert!(processor.process_frame(&frame).is_err());
    }

    #[test]
    fn test_duplicate_detection() {
        let processor = TelemetryProcessor::new();
        let frame1 = TelemetryFrame::new(0, 100, vec![1, 2, 3]);
        let frame2 = TelemetryFrame::new(0, 101, vec![4, 5, 6]);

        assert!(processor.process_frame(&frame1).is_ok());
        assert!(processor.process_frame(&frame2).is_err());
    }

    #[test]
    fn test_timestamp_monotonicity() {
        let processor = TelemetryProcessor::new();
        let frame1 = TelemetryFrame::new(0, 100, vec![1, 2, 3]);
        let frame2 = TelemetryFrame::new(1, 99, vec![4, 5, 6]);

        assert!(processor.process_frame(&frame1).is_ok());
        assert!(processor.process_frame(&frame2).is_err());
    }

    #[test]
    fn test_sequence_ordering() {
        let processor = TelemetryProcessor::new();

        for i in 0..10 {
            let frame = TelemetryFrame::new(i, 100 + i, vec![i as u8]);
            assert!(processor.process_frame(&frame).is_ok());
        }

        let stats = processor.stats();
        assert_eq!(stats.frames_processed, 10);
    }

    #[test]
    fn test_replay_buffer_creation() {
        let buffer = ReplayBuffer::new(100);
        let stats = buffer.stats();
        assert_eq!(stats.current_size, 0);
        assert_eq!(stats.max_size, 100);
    }

    #[test]
    fn test_replay_buffer_add() {
        let buffer = ReplayBuffer::new(100);
        let frame = TelemetryFrame::new(0, 100, vec![1, 2, 3]);
        assert!(buffer.add(frame).is_ok());
    }

    #[test]
    fn test_replay_buffer_full() {
        let buffer = ReplayBuffer::new(2);
        buffer.add(TelemetryFrame::new(0, 100, vec![1])).ok();
        buffer.add(TelemetryFrame::new(1, 101, vec![2])).ok();

        let result = buffer.add(TelemetryFrame::new(2, 102, vec![3]));
        assert!(result.is_err());
    }

    #[test]
    fn test_replay_buffer_get() {
        let buffer = ReplayBuffer::new(100);
        let frame = TelemetryFrame::new(5, 100, vec![1, 2, 3]);
        buffer.add(frame.clone()).ok();

        let retrieved = buffer.get(5).unwrap();
        assert_eq!(retrieved.sequence, 5);
    }

    #[test]
    fn test_replay_from_sequence() {
        let buffer = ReplayBuffer::new(100);

        for i in 0..5 {
            let frame = TelemetryFrame::new(i, 100 + i, vec![i as u8]);
            buffer.add(frame).ok();
        }

        let frames = buffer.replay_from(2).unwrap();
        assert_eq!(frames.len(), 3);
        assert_eq!(frames[0].sequence, 2);
    }

    #[test]
    fn test_frame_size() {
        let frame = TelemetryFrame::new(0, 100, vec![1, 2, 3, 4, 5]);
        let size = frame.size();
        assert!(size > 0);
    }

    #[test]
    fn test_deterministic_hashing() {
        let frame1 = TelemetryFrame::new(0, 100, vec![1, 2, 3]);
        let frame2 = TelemetryFrame::new(0, 100, vec![1, 2, 3]);

        assert_eq!(frame1.hash, frame2.hash);
    }

    #[test]
    fn test_processor_stats() {
        let processor = TelemetryProcessor::new();

        for i in 0..7 {
            let frame = TelemetryFrame::new(i, 100 + i, vec![i as u8]);
            processor.process_frame(&frame).ok();
        }

        let stats = processor.stats();
        assert_eq!(stats.frames_processed, 7);
        assert_eq!(stats.next_sequence, 7);
    }

    #[test]
    fn test_large_payload() {
        let large_payload = vec![0xFF; 10000];
        let frame = TelemetryFrame::new(0, 100, large_payload);
        assert!(frame.verify().is_ok());
    }

    #[test]
    fn test_replay_buffer_clear() {
        let buffer = ReplayBuffer::new(100);
        buffer.add(TelemetryFrame::new(0, 100, vec![1])).ok();
        buffer.clear();

        let stats = buffer.stats();
        assert_eq!(stats.current_size, 0);
    }

    #[test]
    fn test_multiple_processors() {
        let p1 = TelemetryProcessor::new();
        let p2 = TelemetryProcessor::new();

        p1.process_frame(&TelemetryFrame::new(0, 100, vec![1])).ok();
        p2.process_frame(&TelemetryFrame::new(0, 100, vec![2])).ok();

        assert_eq!(p1.stats().frames_processed, 1);
        assert_eq!(p2.stats().frames_processed, 1);
    }
}
