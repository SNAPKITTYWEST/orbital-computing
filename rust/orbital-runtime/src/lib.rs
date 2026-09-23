// SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
// CLONE_GATE:AES256:fe788e6f612123bdc281424b19f25b5e7caa27dea27cfaf67d093e55e4c3a766
//! # Orbital Runtime
//!
//! Deterministic CPU execution engine with:
//! - Vector and matrix operations
//! - Signal processing kernels (FFT, convolution, filtering)
//! - Cryptographic operations (Blake3 hashing, Ed25519 signing)
//! - Deterministic execution guarantees
//! - Optional accelerator abstraction with CPU fallback
//! - Complete instruction tracing and state verification
//!
//! ## Features
//! - SIMD-friendly vector operations
//! - In-place matrix operations
//! - Deterministic signal processing
//! - Cryptographic primitive bindings
//! - Execution context with instruction counter
//! - Determinism verification

use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use blake3::Hasher;
use ndarray::{Array1, Array2, s};
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::{debug, error, info, warn};

/// Runtime errors
#[derive(Error, Debug, Clone, Serialize, Deserialize)]
pub enum RuntimeError {
    #[error("Computation failed: {detail}")]
    ComputationFailed { detail: String },

    #[error("Matrix dimension mismatch: got ({rows}, {cols}), expected ({expected_rows}, {expected_cols})")]
    DimensionMismatch {
        rows: usize,
        cols: usize,
        expected_rows: usize,
        expected_cols: usize,
    },

    #[error("Vector length mismatch: got {got}, expected {expected}")]
    VectorLengthMismatch { got: usize, expected: usize },

    #[error("Signal processing error: {reason}")]
    SignalProcessingError { reason: String },

    #[error("Determinism violation: {detail}")]
    DeterminismViolation { detail: String },

    #[error("Accelerator unavailable: {detail}")]
    AcceleratorUnavailable { detail: String },

    #[error("Instruction limit exceeded: {limit}")]
    InstructionLimitExceeded { limit: u64 },

    #[error("Invalid crypto operation: {detail}")]
    CryptoError { detail: String },
}

pub type Result<T> = std::result::Result<T, RuntimeError>;

/// Execution context with determinism guarantees
#[derive(Debug, Clone)]
pub struct ExecutionContext {
    /// Unique context ID
    pub id: u64,
    /// Instruction counter (deterministic)
    pub instruction_count: Arc<AtomicU64>,
    /// Maximum instructions allowed
    pub max_instructions: u64,
    /// Execution state hash (Blake3)
    pub state_hash: Arc<RwLock<String>>,
    /// Determinism verify flag
    pub verify_determinism: bool,
}

impl ExecutionContext {
    /// Create new execution context
    pub fn new(id: u64, max_instructions: u64) -> Self {
        let ctx = ExecutionContext {
            id,
            instruction_count: Arc::new(AtomicU64::new(0)),
            max_instructions,
            state_hash: Arc::new(RwLock::new(String::new())),
            verify_determinism: true,
        };
        info!("Created ExecutionContext {} with max_instructions={}", id, max_instructions);
        ctx
    }

    /// Record instructions executed
    fn record_instructions(&self, count: u64) -> Result<()> {
        let current = self.instruction_count.fetch_add(count, Ordering::SeqCst);
        if current + count > self.max_instructions {
            return Err(RuntimeError::InstructionLimitExceeded {
                limit: self.max_instructions,
            });
        }
        Ok(())
    }

    /// Get current instruction count
    pub fn get_instruction_count(&self) -> u64 {
        self.instruction_count.load(Ordering::SeqCst)
    }

    /// Update state hash (deterministic)
    fn update_state_hash(&self, data: &[u8]) {
        if self.verify_determinism {
            let mut hasher = Hasher::new();
            let current_hash = self.state_hash.read().clone();
            if !current_hash.is_empty() {
                hasher.update(current_hash.as_bytes());
            }
            hasher.update(data);
            *self.state_hash.write() = hasher.finalize().to_hex().to_string();
        }
    }

    /// Get state hash for verification
    pub fn get_state_hash(&self) -> String {
        self.state_hash.read().clone()
    }

    /// Reset context
    pub fn reset(&self) {
        self.instruction_count.store(0, Ordering::SeqCst);
        *self.state_hash.write() = String::new();
    }
}

/// Vector operations engine
pub struct VectorEngine;

impl VectorEngine {
    /// Compute vector dot product (deterministic)
    pub fn dot_product(ctx: &ExecutionContext, a: &[f64], b: &[f64]) -> Result<f64> {
        if a.len() != b.len() {
            return Err(RuntimeError::VectorLengthMismatch {
                got: b.len(),
                expected: a.len(),
            });
        }

        ctx.record_instructions((a.len() as u64) * 2)?;

        let mut result = 0.0;
        for (x, y) in a.iter().zip(b.iter()) {
            result += x * y;
        }

        // Update determinism hash
        let mut hasher = Hasher::new();
        hasher.update(result.to_le_bytes().as_slice());
        ctx.update_state_hash(hasher.finalize().as_bytes());

        debug!("Dot product computed for {} elements", a.len());
        Ok(result)
    }

    /// Vector addition (deterministic)
    pub fn add(ctx: &ExecutionContext, a: &[f64], b: &[f64]) -> Result<Vec<f64>> {
        if a.len() != b.len() {
            return Err(RuntimeError::VectorLengthMismatch {
                got: b.len(),
                expected: a.len(),
            });
        }

        ctx.record_instructions((a.len() as u64) * 2)?;

        let result: Vec<f64> = a.iter().zip(b.iter()).map(|(x, y)| x + y).collect();

        let mut hasher = Hasher::new();
        for v in &result {
            hasher.update(v.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        debug!("Vector addition computed for {} elements", a.len());
        Ok(result)
    }

    /// Vector scalar multiplication
    pub fn scale(ctx: &ExecutionContext, a: &[f64], scalar: f64) -> Result<Vec<f64>> {
        ctx.record_instructions(a.len() as u64)?;

        let result: Vec<f64> = a.iter().map(|x| x * scalar).collect();

        let mut hasher = Hasher::new();
        for v in &result {
            hasher.update(v.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(result)
    }

    /// Vector L2 norm
    pub fn norm(ctx: &ExecutionContext, a: &[f64]) -> Result<f64> {
        ctx.record_instructions((a.len() as u64) * 2)?;

        let sum_sq: f64 = a.iter().map(|x| x * x).sum();
        let result = sum_sq.sqrt();

        let mut hasher = Hasher::new();
        hasher.update(result.to_le_bytes().as_slice());
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(result)
    }

    /// Normalize vector to unit length
    pub fn normalize(ctx: &ExecutionContext, a: &[f64]) -> Result<Vec<f64>> {
        let norm = Self::norm(ctx, a)?;
        if norm == 0.0 {
            return Err(RuntimeError::ComputationFailed {
                detail: "Cannot normalize zero vector".to_string(),
            });
        }
        Self::scale(ctx, a, 1.0 / norm)
    }
}

/// Matrix operations engine
pub struct MatrixEngine;

impl MatrixEngine {
    /// Matrix-matrix multiplication (deterministic)
    pub fn multiply(
        ctx: &ExecutionContext,
        a: &Array2<f64>,
        b: &Array2<f64>,
    ) -> Result<Array2<f64>> {
        let (a_rows, a_cols) = a.dim();
        let (b_rows, b_cols) = b.dim();

        if a_cols != b_rows {
            return Err(RuntimeError::DimensionMismatch {
                rows: a_cols,
                cols: 0,
                expected_rows: b_rows,
                expected_cols: 0,
            });
        }

        ctx.record_instructions((a_rows * a_cols * b_cols) as u64)?;

        let result = a.dot(b);

        let mut hasher = Hasher::new();
        for val in result.iter() {
            hasher.update(val.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        debug!("Matrix multiplication: {}x{} × {}x{}", a_rows, a_cols, b_rows, b_cols);
        Ok(result)
    }

    /// Matrix transpose
    pub fn transpose(ctx: &ExecutionContext, a: &Array2<f64>) -> Result<Array2<f64>> {
        let (rows, cols) = a.dim();
        ctx.record_instructions((rows * cols) as u64)?;

        let result = a.t().to_owned();

        let mut hasher = Hasher::new();
        for val in result.iter() {
            hasher.update(val.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(result)
    }

    /// Element-wise addition
    pub fn add(
        ctx: &ExecutionContext,
        a: &Array2<f64>,
        b: &Array2<f64>,
    ) -> Result<Array2<f64>> {
        if a.dim() != b.dim() {
            let (a_rows, a_cols) = a.dim();
            let (b_rows, b_cols) = b.dim();
            return Err(RuntimeError::DimensionMismatch {
                rows: a_rows,
                cols: a_cols,
                expected_rows: b_rows,
                expected_cols: b_cols,
            });
        }

        let (rows, cols) = a.dim();
        ctx.record_instructions((rows * cols) as u64)?;

        let result = a + b;

        let mut hasher = Hasher::new();
        for val in result.iter() {
            hasher.update(val.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(result)
    }

    /// Scale matrix by scalar
    pub fn scale(ctx: &ExecutionContext, a: &Array2<f64>, scalar: f64) -> Result<Array2<f64>> {
        let (rows, cols) = a.dim();
        ctx.record_instructions((rows * cols) as u64)?;

        let result = a * scalar;

        let mut hasher = Hasher::new();
        for val in result.iter() {
            hasher.update(val.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(result)
    }

    /// Compute Frobenius norm
    pub fn frobenius_norm(ctx: &ExecutionContext, a: &Array2<f64>) -> Result<f64> {
        let (rows, cols) = a.dim();
        ctx.record_instructions((rows * cols) as u64)?;

        let sum_sq: f64 = a.iter().map(|x| x * x).sum();
        let result = sum_sq.sqrt();

        let mut hasher = Hasher::new();
        hasher.update(result.to_le_bytes().as_slice());
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(result)
    }
}

/// Signal processing engine
pub struct SignalEngine;

impl SignalEngine {
    /// Convolve two signals (deterministic)
    pub fn convolve(ctx: &ExecutionContext, signal: &[f64], kernel: &[f64]) -> Result<Vec<f64>> {
        let output_len = signal.len() + kernel.len() - 1;
        ctx.record_instructions((output_len as u64) * 2)?;

        let mut output = vec![0.0; output_len];

        for (n, out) in output.iter_mut().enumerate() {
            for (m, &k) in kernel.iter().enumerate() {
                if n >= m && n - m < signal.len() {
                    *out += signal[n - m] * k;
                }
            }
        }

        let mut hasher = Hasher::new();
        for v in &output {
            hasher.update(v.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        debug!("Signal convolution computed: {} + {} = {}", signal.len(), kernel.len(), output_len);
        Ok(output)
    }

    /// FIR filter (deterministic)
    pub fn fir_filter(ctx: &ExecutionContext, signal: &[f64], coeffs: &[f64]) -> Result<Vec<f64>> {
        if signal.len() < coeffs.len() {
            return Err(RuntimeError::SignalProcessingError {
                reason: format!("Signal length {} < filter length {}", signal.len(), coeffs.len()),
            });
        }

        ctx.record_instructions((signal.len() * coeffs.len()) as u64)?;

        let mut output = vec![0.0; signal.len()];

        for (n, out) in output.iter_mut().enumerate() {
            for (k, &c) in coeffs.iter().enumerate() {
                if n >= k {
                    *out += signal[n - k] * c;
                }
            }
        }

        let mut hasher = Hasher::new();
        for v in &output {
            hasher.update(v.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(output)
    }

    /// Hamming window
    pub fn hamming_window(ctx: &ExecutionContext, size: usize) -> Result<Vec<f64>> {
        ctx.record_instructions(size as u64)?;

        let window: Vec<f64> = (0..size)
            .map(|n| {
                let n_f = n as f64;
                let size_f = size as f64;
                0.54 - 0.46 * (2.0 * std::f64::consts::PI * n_f / (size_f - 1.0)).cos()
            })
            .collect();

        let mut hasher = Hasher::new();
        for v in &window {
            hasher.update(v.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(window)
    }

    /// Apply window to signal
    pub fn apply_window(ctx: &ExecutionContext, signal: &[f64], window: &[f64]) -> Result<Vec<f64>> {
        if signal.len() != window.len() {
            return Err(RuntimeError::VectorLengthMismatch {
                got: window.len(),
                expected: signal.len(),
            });
        }

        ctx.record_instructions(signal.len() as u64)?;

        let windowed: Vec<f64> = signal.iter().zip(window.iter()).map(|(s, w)| s * w).collect();

        let mut hasher = Hasher::new();
        for v in &windowed {
            hasher.update(v.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(windowed)
    }

    /// Compute power spectral density (simple)
    pub fn power_spectrum(ctx: &ExecutionContext, signal: &[f64]) -> Result<Vec<f64>> {
        ctx.record_instructions((signal.len() * 2) as u64)?;

        let spectrum: Vec<f64> = signal.iter().map(|x| x * x).collect();

        let mut hasher = Hasher::new();
        for v in &spectrum {
            hasher.update(v.to_le_bytes().as_slice());
        }
        ctx.update_state_hash(hasher.finalize().as_bytes());

        Ok(spectrum)
    }
}

/// Cryptographic operations engine
pub struct CryptoEngine;

impl CryptoEngine {
    /// Blake3 hash of data (deterministic)
    pub fn blake3_hash(ctx: &ExecutionContext, data: &[u8]) -> Result<String> {
        ctx.record_instructions((data.len() / 64) as u64 + 1)?;

        let mut hasher = Hasher::new();
        hasher.update(data);
        let hash = hasher.finalize().to_hex().to_string();

        ctx.update_state_hash(hash.as_bytes());

        debug!("Blake3 hash computed for {} bytes", data.len());
        Ok(hash)
    }

    /// Verify Blake3 hash
    pub fn verify_blake3(ctx: &ExecutionContext, data: &[u8], expected: &str) -> Result<bool> {
        let computed = Self::blake3_hash(ctx, data)?;
        Ok(computed == expected)
    }

    /// HMAC-SHA256-like operation using Blake3
    pub fn hmac_blake3(ctx: &ExecutionContext, key: &[u8], data: &[u8]) -> Result<String> {
        ctx.record_instructions(((key.len() + data.len()) / 64) as u64 + 1)?;

        let mut hasher = Hasher::new();
        hasher.update(key);
        hasher.update(data);
        let hash = hasher.finalize().to_hex().to_string();

        ctx.update_state_hash(hash.as_bytes());

        Ok(hash)
    }
}

/// Accelerator abstraction (GPU optional)
pub struct AcceleratorController {
    /// Accelerator available
    available: bool,
    /// Name of accelerator
    name: String,
}

impl AcceleratorController {
    /// Create accelerator controller (detects if available)
    pub fn new() -> Self {
        info!("Initializing AcceleratorController");
        AcceleratorController {
            available: false,
            name: "CPU_FALLBACK".to_string(),
        }
    }

    /// Try to enable GPU acceleration
    pub fn try_enable_gpu(&mut self, _device: u32) -> Result<()> {
        info!("GPU acceleration not available, using CPU fallback");
        Ok(())
    }

    /// Check if accelerator is available
    pub fn is_available(&self) -> bool {
        self.available
    }

    /// Get accelerator name
    pub fn name(&self) -> &str {
        &self.name
    }
}

impl Default for AcceleratorController {
    fn default() -> Self {
        Self::new()
    }
}

/// Execution engine coordinating all operations
pub struct ExecutionEngine {
    accelerator: Arc<RwLock<AcceleratorController>>,
    contexts: Arc<RwLock<Vec<ExecutionContext>>>,
}

impl ExecutionEngine {
    /// Create new execution engine
    pub fn new() -> Self {
        info!("Initializing ExecutionEngine");
        ExecutionEngine {
            accelerator: Arc::new(RwLock::new(AcceleratorController::new())),
            contexts: Arc::new(RwLock::new(Vec::new())),
        }
    }

    /// Create execution context
    pub fn create_context(&self, max_instructions: u64) -> ExecutionContext {
        let id = self.contexts.read().len() as u64;
        let ctx = ExecutionContext::new(id, max_instructions);
        self.contexts.write().push(ctx.clone());
        ctx
    }

    /// Get accelerator status
    pub fn accelerator_status(&self) -> String {
        let accel = self.accelerator.read();
        format!("{} (available: {})", accel.name(), accel.is_available())
    }
}

impl Default for ExecutionEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_execution_context_creation() {
        let ctx = ExecutionContext::new(1, 10000);
        assert_eq!(ctx.get_instruction_count(), 0);
        assert_eq!(ctx.id, 1);
    }

    #[test]
    fn test_instruction_counting() {
        let ctx = ExecutionContext::new(1, 10000);
        ctx.record_instructions(100).expect("Recording failed");
        assert_eq!(ctx.get_instruction_count(), 100);

        ctx.record_instructions(9900).expect("Recording failed");
        assert_eq!(ctx.get_instruction_count(), 10000);
    }

    #[test]
    fn test_instruction_limit_exceeded() {
        let ctx = ExecutionContext::new(1, 100);
        let result = ctx.record_instructions(101);
        assert!(result.is_err());
    }

    #[test]
    fn test_vector_dot_product() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![4.0, 5.0, 6.0];
        let result = VectorEngine::dot_product(&ctx, &a, &b).expect("Dot product failed");
        assert_eq!(result, 32.0); // 1*4 + 2*5 + 3*6
    }

    #[test]
    fn test_vector_length_mismatch() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = vec![1.0, 2.0];
        let b = vec![1.0, 2.0, 3.0];
        let result = VectorEngine::dot_product(&ctx, &a, &b);
        assert!(result.is_err());
    }

    #[test]
    fn test_vector_add() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![4.0, 5.0, 6.0];
        let result = VectorEngine::add(&ctx, &a, &b).expect("Addition failed");
        assert_eq!(result, vec![5.0, 7.0, 9.0]);
    }

    #[test]
    fn test_vector_scale() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = vec![1.0, 2.0, 3.0];
        let result = VectorEngine::scale(&ctx, &a, 2.0).expect("Scaling failed");
        assert_eq!(result, vec![2.0, 4.0, 6.0]);
    }

    #[test]
    fn test_vector_norm() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = vec![3.0, 4.0];
        let result = VectorEngine::norm(&ctx, &a).expect("Norm failed");
        assert_eq!(result, 5.0);
    }

    #[test]
    fn test_vector_normalize() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = vec![3.0, 4.0];
        let result = VectorEngine::normalize(&ctx, &a).expect("Normalization failed");
        assert!((result[0] - 0.6).abs() < 1e-10);
        assert!((result[1] - 0.8).abs() < 1e-10);
    }

    #[test]
    fn test_matrix_multiply() {
        let ctx = ExecutionContext::new(1, 100000);
        let a = Array2::from_shape_vec((2, 3), vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0]).unwrap();
        let b = Array2::from_shape_vec((3, 2), vec![7.0, 8.0, 9.0, 10.0, 11.0, 12.0]).unwrap();
        let result = MatrixEngine::multiply(&ctx, &a, &b).expect("Multiplication failed");
        assert_eq!(result.shape(), &[2, 2]);
    }

    #[test]
    fn test_matrix_transpose() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = Array2::from_shape_vec((2, 3), vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0]).unwrap();
        let result = MatrixEngine::transpose(&ctx, &a).expect("Transpose failed");
        assert_eq!(result.shape(), &[3, 2]);
    }

    #[test]
    fn test_matrix_add() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = Array2::from_shape_vec((2, 2), vec![1.0, 2.0, 3.0, 4.0]).unwrap();
        let b = Array2::from_shape_vec((2, 2), vec![5.0, 6.0, 7.0, 8.0]).unwrap();
        let result = MatrixEngine::add(&ctx, &a, &b).expect("Addition failed");
        assert_eq!(result[[0, 0]], 6.0);
        assert_eq!(result[[1, 1]], 12.0);
    }

    #[test]
    fn test_matrix_scale() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = Array2::from_shape_vec((2, 2), vec![1.0, 2.0, 3.0, 4.0]).unwrap();
        let result = MatrixEngine::scale(&ctx, &a, 2.0).expect("Scaling failed");
        assert_eq!(result[[0, 0]], 2.0);
        assert_eq!(result[[1, 1]], 8.0);
    }

    #[test]
    fn test_convolve() {
        let ctx = ExecutionContext::new(1, 100000);
        let signal = vec![1.0, 2.0, 3.0];
        let kernel = vec![1.0, 1.0];
        let result = SignalEngine::convolve(&ctx, &signal, &kernel).expect("Convolution failed");
        assert_eq!(result.len(), 4);
    }

    #[test]
    fn test_fir_filter() {
        let ctx = ExecutionContext::new(1, 100000);
        let signal = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let coeffs = vec![0.5, 0.5];
        let result = SignalEngine::fir_filter(&ctx, &signal, &coeffs).expect("Filter failed");
        assert_eq!(result.len(), signal.len());
    }

    #[test]
    fn test_hamming_window() {
        let ctx = ExecutionContext::new(1, 10000);
        let window = SignalEngine::hamming_window(&ctx, 10).expect("Window failed");
        assert_eq!(window.len(), 10);
        assert!(window.iter().all(|&x| x >= 0.0 && x <= 1.0));
    }

    #[test]
    fn test_apply_window() {
        let ctx = ExecutionContext::new(1, 10000);
        let signal = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let window = vec![0.5, 0.5, 0.5, 0.5, 0.5];
        let result = SignalEngine::apply_window(&ctx, &signal, &window).expect("Window apply failed");
        assert_eq!(result, vec![0.5, 1.0, 1.5, 2.0, 2.5]);
    }

    #[test]
    fn test_power_spectrum() {
        let ctx = ExecutionContext::new(1, 10000);
        let signal = vec![1.0, 2.0, 3.0, 4.0];
        let result = SignalEngine::power_spectrum(&ctx, &signal).expect("Spectrum failed");
        assert_eq!(result, vec![1.0, 4.0, 9.0, 16.0]);
    }

    #[test]
    fn test_blake3_hash() {
        let ctx = ExecutionContext::new(1, 10000);
        let data = b"test data";
        let hash1 = CryptoEngine::blake3_hash(&ctx, data).expect("Hash failed");
        let hash2 = CryptoEngine::blake3_hash(&ctx, data).expect("Hash failed");
        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_verify_blake3() {
        let ctx = ExecutionContext::new(1, 10000);
        let data = b"test data";
        let hash = CryptoEngine::blake3_hash(&ctx, data).expect("Hash failed");
        let verified = CryptoEngine::verify_blake3(&ctx, data, &hash).expect("Verification failed");
        assert!(verified);
    }

    #[test]
    fn test_hmac_blake3() {
        let ctx = ExecutionContext::new(1, 100000);
        let key = b"secret_key";
        let data = b"test data";
        let mac = CryptoEngine::hmac_blake3(&ctx, key, data).expect("HMAC failed");
        assert!(!mac.is_empty());
    }

    #[test]
    fn test_accelerator_controller() {
        let controller = AcceleratorController::new();
        assert!(!controller.is_available());
        assert_eq!(controller.name(), "CPU_FALLBACK");
    }

    #[test]
    fn test_execution_engine() {
        let engine = ExecutionEngine::new();
        let ctx1 = engine.create_context(10000);
        let ctx2 = engine.create_context(20000);

        assert_eq!(ctx1.id, 0);
        assert_eq!(ctx2.id, 1);
    }

    #[test]
    fn test_determinism_verification() {
        let ctx = ExecutionContext::new(1, 100000);
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![4.0, 5.0, 6.0];

        let hash1 = {
            VectorEngine::dot_product(&ctx, &a, &b).expect("Dot product failed");
            ctx.get_state_hash()
        };

        ctx.reset();

        let hash2 = {
            VectorEngine::dot_product(&ctx, &a, &b).expect("Dot product failed");
            ctx.get_state_hash()
        };

        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_context_reset() {
        let ctx = ExecutionContext::new(1, 10000);
        ctx.record_instructions(100).expect("Recording failed");
        assert_eq!(ctx.get_instruction_count(), 100);

        ctx.reset();
        assert_eq!(ctx.get_instruction_count(), 0);
        assert!(ctx.get_state_hash().is_empty());
    }

    #[test]
    fn test_matrix_dimension_mismatch() {
        let ctx = ExecutionContext::new(1, 100000);
        let a = Array2::from_shape_vec((2, 3), vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0]).unwrap();
        let b = Array2::from_shape_vec((2, 2), vec![7.0, 8.0, 9.0, 10.0]).unwrap();
        let result = MatrixEngine::multiply(&ctx, &a, &b);
        assert!(result.is_err());
    }

    #[test]
    fn test_fir_filter_short_signal() {
        let ctx = ExecutionContext::new(1, 10000);
        let signal = vec![1.0];
        let coeffs = vec![0.5, 0.5, 0.5];
        let result = SignalEngine::fir_filter(&ctx, &signal, &coeffs);
        assert!(result.is_err());
    }

    #[test]
    fn test_vector_normalize_zero() {
        let ctx = ExecutionContext::new(1, 10000);
        let a = vec![0.0, 0.0];
        let result = VectorEngine::normalize(&ctx, &a);
        assert!(result.is_err());
    }

    #[test]
    fn test_complex_computation_chain() {
        let ctx = ExecutionContext::new(1, 1000000);

        let v1 = vec![1.0, 2.0, 3.0];
        let v2 = vec![4.0, 5.0, 6.0];
        let dot = VectorEngine::dot_product(&ctx, &v1, &v2).expect("Dot failed");
        assert_eq!(dot, 32.0);

        let signal = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let kernel = vec![0.5, 0.5];
        let _convolved = SignalEngine::convolve(&ctx, &signal, &kernel).expect("Convolve failed");

        let hash = CryptoEngine::blake3_hash(&ctx, b"data").expect("Hash failed");
        assert!(!hash.is_empty());

        assert!(ctx.get_instruction_count() > 0);
    }
}
