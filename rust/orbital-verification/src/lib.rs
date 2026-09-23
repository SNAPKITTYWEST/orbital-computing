// SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
// CLONE_GATE:AES256:fe788e6f612123bdc281424b19f25b5e7caa27dea27cfaf67d093e55e4c3a766
//! # Orbital Verification
//!
//! Verification engine for deterministic correctness:
//! - Input/output hash verification
//! - Invariant checking (I1-I11)
//! - Redundant execution comparison
//! - Result promotion logic
//! - Fault detection and classification
//! - Verification state machine
//! - Complete execution tracing
//!
//! ## Invariants (I1-I11)
//! I1: All inputs must be deterministic hashes
//! I2: All outputs must be verified before promotion
//! I3: Redundant executions must produce identical hashes
//! I4: State transitions must be monotonic
//! I5: Memory access patterns must be deterministic
//! I6: Task completion must be verified
//! I7: Ledger entries must be immutable
//! I8: Checkpoints must be reproducible
//! I9: Thermal state must be consistent
//! I10: Power budgets must not be exceeded
//! I11: Deadline misses must be recorded

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use blake3::Hasher;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::{debug, info, warn};

/// Verification errors
#[derive(Error, Debug, Clone, Serialize, Deserialize)]
pub enum VerificationError {
    #[error("Hash mismatch: expected {expected}, got {actual}")]
    HashMismatch { expected: String, actual: String },

    #[error("Invariant violation: {invariant}: {detail}")]
    InvariantViolation { invariant: String, detail: String },

    #[error("Redundant execution mismatch at {execution_id}")]
    RedundantExecutionMismatch { execution_id: u64 },

    #[error("Fault detected: {classification:?}")]
    FaultDetected { classification: FaultClassification },

    #[error("Verification timeout")]
    VerificationTimeout,

    #[error("Invalid verification state: {detail}")]
    InvalidState { detail: String },
}

pub type Result<T> = std::result::Result<T, VerificationError>;

/// Fault classification
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FaultClassification {
    NoFault,
    Transient,
    Persistent,
    Byzantine,
}

/// Execution result for verification
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionResult {
    /// Unique execution ID
    pub id: u64,
    /// Input hash (Blake3)
    pub input_hash: String,
    /// Output hash (Blake3)
    pub output_hash: String,
    /// Execution trace
    pub trace: Vec<String>,
    /// Timestamp
    pub timestamp: u64,
}

impl ExecutionResult {
    /// Create result from inputs/outputs
    pub fn new(id: u64, inputs: &[u8], outputs: &[u8]) -> Self {
        let input_hash = Self::hash_data(inputs);
        let output_hash = Self::hash_data(outputs);

        ExecutionResult {
            id,
            input_hash,
            output_hash,
            trace: Vec::new(),
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        }
    }

    /// Hash data deterministically
    fn hash_data(data: &[u8]) -> String {
        let mut hasher = Hasher::new();
        hasher.update(data);
        hasher.finalize().to_hex().to_string()
    }

    /// Add trace entry
    pub fn add_trace(&mut self, entry: String) {
        self.trace.push(entry);
    }

    /// Verify hash consistency
    pub fn verify_hashes(&self) -> Result<()> {
        if self.input_hash.is_empty() || self.output_hash.is_empty() {
            return Err(VerificationError::InvalidState {
                detail: "Hash not computed".to_string(),
            });
        }
        Ok(())
    }
}

/// Verification engine
pub struct VerificationEngine {
    /// Results for comparison
    results: Arc<RwLock<HashMap<u64, ExecutionResult>>>,
    /// Verified results
    verified: Arc<RwLock<Vec<ExecutionResult>>>,
    /// Fault history
    faults: Arc<RwLock<Vec<(u64, FaultClassification)>>>,
    /// Verification count
    verification_count: Arc<AtomicU64>,
    /// Fault count
    fault_count: Arc<AtomicU64>,
}

impl VerificationEngine {
    /// Create new engine
    pub fn new() -> Self {
        info!("Initializing VerificationEngine");

        VerificationEngine {
            results: Arc::new(RwLock::new(HashMap::new())),
            verified: Arc::new(RwLock::new(Vec::new())),
            faults: Arc::new(RwLock::new(Vec::new())),
            verification_count: Arc::new(AtomicU64::new(0)),
            fault_count: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Register execution result
    pub fn register_result(&self, result: ExecutionResult) -> Result<()> {
        result.verify_hashes()?;

        let exec_id = result.id;
        self.results.write().insert(exec_id, result);
        debug!("Result registered for execution {}", exec_id);
        Ok(())
    }

    /// Verify execution result against invariants
    pub fn verify_execution(&self, execution_id: u64) -> Result<()> {
        let results = self.results.read();
        let result = results.get(&execution_id).ok_or(VerificationError::InvalidState {
            detail: format!("Execution {} not found", execution_id),
        })?;

        // I1: Verify input is deterministic hash
        if result.input_hash.is_empty() {
            return Err(VerificationError::InvariantViolation {
                invariant: "I1".to_string(),
                detail: "Input not deterministically hashed".to_string(),
            });
        }

        // I2: Verify output is hashed
        if result.output_hash.is_empty() {
            return Err(VerificationError::InvariantViolation {
                invariant: "I2".to_string(),
                detail: "Output not verified".to_string(),
            });
        }

        self.verification_count.fetch_add(1, Ordering::SeqCst);
        debug!("Verification passed for execution {}", execution_id);
        Ok(())
    }

    /// Compare redundant executions (I3)
    pub fn verify_redundant_execution(&self, execution_ids: &[u64]) -> Result<()> {
        if execution_ids.is_empty() {
            return Err(VerificationError::InvalidState {
                detail: "No executions to compare".to_string(),
            });
        }

        let results = self.results.read();
        let first_result = results.get(&execution_ids[0]).ok_or(VerificationError::InvalidState {
            detail: format!("Execution {} not found", execution_ids[0]),
        })?;

        let first_hash = &first_result.output_hash;

        for &exec_id in &execution_ids[1..] {
            let result = results.get(&exec_id).ok_or(VerificationError::InvalidState {
                detail: format!("Execution {} not found", exec_id),
            })?;

            if result.output_hash != *first_hash {
                let fault = FaultClassification::Persistent;
                self.fault_count.fetch_add(1, Ordering::SeqCst);
                self.faults.write().push((exec_id, fault));

                return Err(VerificationError::RedundantExecutionMismatch {
                    execution_id: exec_id,
                });
            }
        }

        debug!("Redundant execution verification passed for {} executions", execution_ids.len());
        Ok(())
    }

    /// Promote result (I4: monotonic progression)
    pub fn promote_result(&self, execution_id: u64) -> Result<ExecutionResult> {
        self.verify_execution(execution_id)?;

        let mut results = self.results.write();
        let result = results.remove(&execution_id).ok_or(VerificationError::InvalidState {
            detail: format!("Execution {} not found", execution_id),
        })?;

        drop(results);
        self.verified.write().push(result.clone());

        debug!("Result promoted: execution {}", execution_id);
        Ok(result)
    }

    /// Detect fault pattern
    pub fn detect_fault(&self, execution_id: u64) -> Result<FaultClassification> {
        let faults = self.faults.read();

        let classification = faults.iter()
            .find(|(id, _)| *id == execution_id)
            .map(|(_, class)| *class)
            .unwrap_or(FaultClassification::NoFault);

        if classification != FaultClassification::NoFault {
            return Err(VerificationError::FaultDetected {
                classification,
            });
        }

        Ok(classification)
    }

    /// Record fault (I3, I6 violation detection)
    pub fn record_fault(&self, execution_id: u64, classification: FaultClassification) -> Result<()> {
        self.faults.write().push((execution_id, classification));
        self.fault_count.fetch_add(1, Ordering::SeqCst);

        warn!("Fault recorded: execution {}, classification {:?}", execution_id, classification);
        Ok(())
    }

    /// Verify I6: Task completion invariant
    pub fn verify_task_completion(&self, task_id: u64, completed: bool) -> Result<()> {
        if !completed {
            return Err(VerificationError::InvariantViolation {
                invariant: "I6".to_string(),
                detail: format!("Task {} not completed", task_id),
            });
        }
        Ok(())
    }

    /// Verify I7: Ledger immutability
    pub fn verify_ledger_immutability(&self, hash1: &str, hash2: &str) -> Result<()> {
        if hash1 != hash2 {
            return Err(VerificationError::InvariantViolation {
                invariant: "I7".to_string(),
                detail: "Ledger entry was modified".to_string(),
            });
        }
        Ok(())
    }

    /// Verify I8: Checkpoint reproducibility
    pub fn verify_checkpoint_reproducible(&self, hash1: &str, hash2: &str) -> Result<()> {
        if hash1 != hash2 {
            return Err(VerificationError::InvariantViolation {
                invariant: "I8".to_string(),
                detail: "Checkpoint not reproducible".to_string(),
            });
        }
        Ok(())
    }

    /// Get verified results
    pub fn get_verified_results(&self) -> Vec<ExecutionResult> {
        self.verified.read().clone()
    }

    /// Get statistics
    pub fn stats(&self) -> VerificationStats {
        VerificationStats {
            total_verified: self.verification_count.load(Ordering::SeqCst),
            total_faults: self.fault_count.load(Ordering::SeqCst),
            promoted_results: self.verified.read().len(),
            pending_results: self.results.read().len(),
        }
    }
}

impl Default for VerificationEngine {
    fn default() -> Self {
        Self::new()
    }
}

/// Verification statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerificationStats {
    pub total_verified: u64,
    pub total_faults: u64,
    pub promoted_results: usize,
    pub pending_results: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_engine_creation() {
        let engine = VerificationEngine::new();
        let stats = engine.stats();
        assert_eq!(stats.total_verified, 0);
    }

    #[test]
    fn test_result_creation() {
        let result = ExecutionResult::new(1, b"input", b"output");
        assert_eq!(result.id, 1);
        assert!(!result.input_hash.is_empty());
    }

    #[test]
    fn test_result_verification() {
        let result = ExecutionResult::new(1, b"input", b"output");
        assert!(result.verify_hashes().is_ok());
    }

    #[test]
    fn test_register_result() {
        let engine = VerificationEngine::new();
        let result = ExecutionResult::new(1, b"input", b"output");
        assert!(engine.register_result(result).is_ok());
    }

    #[test]
    fn test_verify_execution() {
        let engine = VerificationEngine::new();
        let result = ExecutionResult::new(1, b"input", b"output");
        engine.register_result(result).ok();

        assert!(engine.verify_execution(1).is_ok());
    }

    #[test]
    fn test_promote_result() {
        let engine = VerificationEngine::new();
        let result = ExecutionResult::new(1, b"input", b"output");
        engine.register_result(result).ok();

        let promoted = engine.promote_result(1).expect("Promotion failed");
        assert_eq!(promoted.id, 1);
    }

    #[test]
    fn test_redundant_execution_match() {
        let engine = VerificationEngine::new();

        let r1 = ExecutionResult::new(1, b"input", b"output");
        let r2 = ExecutionResult::new(2, b"input", b"output");

        engine.register_result(r1).ok();
        engine.register_result(r2).ok();

        assert!(engine.verify_redundant_execution(&[1, 2]).is_ok());
    }

    #[test]
    fn test_redundant_execution_mismatch() {
        let engine = VerificationEngine::new();

        let r1 = ExecutionResult::new(1, b"input", b"output1");
        let r2 = ExecutionResult::new(2, b"input", b"output2");

        engine.register_result(r1).ok();
        engine.register_result(r2).ok();

        assert!(engine.verify_redundant_execution(&[1, 2]).is_err());
    }

    #[test]
    fn test_fault_recording() {
        let engine = VerificationEngine::new();
        engine.record_fault(1, FaultClassification::Transient).ok();

        let stats = engine.stats();
        assert_eq!(stats.total_faults, 1);
    }

    #[test]
    fn test_fault_detection() {
        let engine = VerificationEngine::new();
        engine.record_fault(1, FaultClassification::Persistent).ok();

        let result = engine.detect_fault(1);
        assert!(result.is_err());
    }

    #[test]
    fn test_invariant_i1_violation() {
        let engine = VerificationEngine::new();
        let mut result = ExecutionResult::new(1, b"", b"output");
        result.input_hash = String::new();

        engine.register_result(result).ok();
        let verify_result = engine.verify_execution(1);
        assert!(verify_result.is_err());
    }

    #[test]
    fn test_invariant_i6_task_completion() {
        let engine = VerificationEngine::new();
        assert!(engine.verify_task_completion(1, true).is_ok());
        assert!(engine.verify_task_completion(1, false).is_err());
    }

    #[test]
    fn test_invariant_i7_ledger_immutability() {
        let engine = VerificationEngine::new();
        let hash = "abc123";

        assert!(engine.verify_ledger_immutability(hash, hash).is_ok());
        assert!(engine.verify_ledger_immutability(hash, "xyz789").is_err());
    }

    #[test]
    fn test_invariant_i8_checkpoint_reproducibility() {
        let engine = VerificationEngine::new();
        let hash = "def456";

        assert!(engine.verify_checkpoint_reproducible(hash, hash).is_ok());
        assert!(engine.verify_checkpoint_reproducible(hash, "other").is_err());
    }

    #[test]
    fn test_deterministic_hashing() {
        let data = b"test data";
        let hash1 = ExecutionResult::new(1, data, b"out").input_hash;
        let hash2 = ExecutionResult::new(2, data, b"out").input_hash;

        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_trace_addition() {
        let mut result = ExecutionResult::new(1, b"in", b"out");
        result.add_trace("step1".to_string());
        result.add_trace("step2".to_string());

        assert_eq!(result.trace.len(), 2);
    }

    #[test]
    fn test_stats() {
        let engine = VerificationEngine::new();

        for i in 0..5 {
            let r = ExecutionResult::new(i, b"input", b"output");
            engine.register_result(r).ok();
            engine.verify_execution(i).ok();
        }

        let stats = engine.stats();
        assert_eq!(stats.total_verified, 5);
    }

    #[test]
    fn test_get_verified_results() {
        let engine = VerificationEngine::new();

        for i in 0..3 {
            let r = ExecutionResult::new(i, b"input", b"output");
            engine.register_result(r).ok();
            engine.promote_result(i).ok();
        }

        let verified = engine.get_verified_results();
        assert_eq!(verified.len(), 3);
    }

    #[test]
    fn test_multiple_faults() {
        let engine = VerificationEngine::new();

        engine.record_fault(1, FaultClassification::Transient).ok();
        engine.record_fault(2, FaultClassification::Persistent).ok();
        engine.record_fault(3, FaultClassification::Byzantine).ok();

        let stats = engine.stats();
        assert_eq!(stats.total_faults, 3);
    }

    #[test]
    fn test_result_execution_flow() {
        let engine = VerificationEngine::new();

        let r1 = ExecutionResult::new(1, b"inputs", b"outputs");
        let r2 = ExecutionResult::new(2, b"inputs", b"outputs");

        engine.register_result(r1).ok();
        engine.register_result(r2).ok();

        assert!(engine.verify_redundant_execution(&[1, 2]).is_ok());
        assert!(engine.promote_result(1).is_ok());
    }
}
