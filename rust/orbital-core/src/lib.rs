// SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
// CLONE_GATE:AES256:fe788e6f612123bdc281424b19f25b5e7caa27dea27cfaf67d093e55e4c3a766
//! # Orbital Core
//!
//! Central coordinator for the Orbital Computing Stack with complete task lifecycle management,
//! error handling, watchdog integration, and fault state machine.
//!
//! ## Features
//! - Task lifecycle management (creation, execution, completion, error recovery)
//! - Multi-level error handling with context preservation
//! - Watchdog integration for reliability
//! - Deterministic fault state machine
//! - Zero-panic error propagation
//! - Comprehensive audit trail
//!
//! ## Architecture
//!
//! The core coordinator manages:
//! - **Task States**: Created → Queued → Running → Completed/Failed/Cancelled
//! - **Error Hierarchy**: Transient → Recoverable → Fatal
//! - **Watchdog Integration**: Heartbeat monitoring with exponential backoff
//! - **Fault Detection**: Automatic state recovery with audit trail

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::{debug, error, info, warn};

/// Unique task identifier
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TaskId(u64);

impl TaskId {
    /// Create new task ID from raw value
    pub fn from_raw(id: u64) -> Self {
        TaskId(id)
    }

    /// Get raw ID value
    pub fn as_u64(self) -> u64 {
        self.0
    }
}

impl fmt::Display for TaskId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "task_{:016x}", self.0)
    }
}

/// Task execution state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TaskState {
    /// Task created but not yet queued
    Created,
    /// Task waiting in execution queue
    Queued,
    /// Task currently executing
    Running,
    /// Task completed successfully
    Completed,
    /// Task failed with recoverable error
    Failed,
    /// Task cancelled by coordinator
    Cancelled,
}

impl fmt::Display for TaskState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TaskState::Created => write!(f, "CREATED"),
            TaskState::Queued => write!(f, "QUEUED"),
            TaskState::Running => write!(f, "RUNNING"),
            TaskState::Completed => write!(f, "COMPLETED"),
            TaskState::Failed => write!(f, "FAILED"),
            TaskState::Cancelled => write!(f, "CANCELLED"),
        }
    }
}

/// Error classification for recovery strategy
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ErrorClassification {
    /// Transient error (e.g., temporary resource unavailable) - retry with backoff
    Transient,
    /// Recoverable error (e.g., corrupted data) - can recover with intervention
    Recoverable,
    /// Fatal error - no recovery possible
    Fatal,
}

/// Core error types with context
#[derive(Error, Debug, Clone, Serialize, Deserialize)]
pub enum CoreError {
    #[error("Task not found: {task_id}")]
    TaskNotFound { task_id: String },

    #[error("Invalid state transition: {from} -> {to}")]
    InvalidStateTransition { from: String, to: String },

    #[error("Watchdog timeout for {task_id} after {seconds}s")]
    WatchdogTimeout {
        task_id: String,
        seconds: u64,
    },

    #[error("Coordinator shutdown: {reason}")]
    CoordinatorShutdown { reason: String },

    #[error("Resource exhaustion: {resource}")]
    ResourceExhaustion { resource: String },

    #[error("Determinism violation: {detail}")]
    DeterminismViolation { detail: String },

    #[error("Task error: {message} (classification: {classification:?})")]
    TaskExecution {
        message: String,
        classification: ErrorClassification,
    },

    #[error("Configuration error: {detail}")]
    ConfigError { detail: String },
}

impl CoreError {
    /// Get error classification for recovery strategy
    pub fn classification(&self) -> ErrorClassification {
        match self {
            CoreError::WatchdogTimeout { .. } => ErrorClassification::Transient,
            CoreError::ResourceExhaustion { .. } => ErrorClassification::Recoverable,
            CoreError::DeterminismViolation { .. } => ErrorClassification::Fatal,
            CoreError::CoordinatorShutdown { .. } => ErrorClassification::Fatal,
            CoreError::TaskExecution { classification, .. } => *classification,
            _ => ErrorClassification::Recoverable,
        }
    }
}

/// Result type for core operations
pub type Result<T> = std::result::Result<T, CoreError>;

/// Task metadata and lifecycle tracking
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskMetadata {
    /// Unique task identifier
    pub id: TaskId,
    /// Human-readable task name
    pub name: String,
    /// Current execution state
    pub state: TaskState,
    /// Creation timestamp (seconds since UNIX_EPOCH)
    pub created_at: u64,
    /// Last state transition timestamp
    pub last_transition_at: u64,
    /// Last successful heartbeat timestamp
    pub last_heartbeat: u64,
    /// Execution attempt count (incremented on retry)
    pub attempt_count: u32,
    /// Maximum allowed retry attempts
    pub max_retries: u32,
    /// Last error (if any)
    pub last_error: Option<String>,
    /// Priority level (0=lowest, 255=highest)
    pub priority: u8,
}

impl TaskMetadata {
    /// Check if task has exceeded retry limit
    pub fn exceeded_retries(&self) -> bool {
        self.attempt_count > self.max_retries
    }

    /// Check if watchdog timeout has occurred
    pub fn is_watchdog_timeout(&self, timeout: Duration, now: u64) -> bool {
        let elapsed = now.saturating_sub(self.last_heartbeat);
        elapsed > timeout.as_secs()
    }

    /// Time elapsed since task creation
    pub fn elapsed_since_creation(&self, now: u64) -> Duration {
        Duration::from_secs(now.saturating_sub(self.created_at))
    }
}

/// Watchdog configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WatchdogConfig {
    /// Heartbeat timeout in seconds
    pub timeout_secs: u64,
    /// Initial backoff multiplier for retries
    pub initial_backoff_ms: u64,
    /// Maximum backoff between retries
    pub max_backoff_ms: u64,
    /// Enable automatic recovery on timeout
    pub auto_recovery: bool,
}

impl Default for WatchdogConfig {
    fn default() -> Self {
        WatchdogConfig {
            timeout_secs: 30,
            initial_backoff_ms: 100,
            max_backoff_ms: 30000,
            auto_recovery: true,
        }
    }
}

/// Fault state machine for deterministic error recovery
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FaultState {
    /// No fault detected
    Healthy,
    /// Transient fault detected (automatic recovery in progress)
    Transient,
    /// Recoverable fault detected (intervention required)
    Recoverable,
    /// Fatal fault (system must halt gracefully)
    Fatal,
    /// Recovering from fault
    Recovering,
}

/// Core coordinator managing task lifecycle
pub struct OrbitalCoordinator {
    /// Active task metadata
    tasks: Arc<RwLock<HashMap<TaskId, TaskMetadata>>>,
    /// Current fault state
    fault_state: Arc<RwLock<FaultState>>,
    /// Task ID generator (monotonic)
    task_id_counter: Arc<AtomicU64>,
    /// Watchdog configuration
    watchdog_config: WatchdogConfig,
    /// Audit trail of state transitions
    audit_trail: Arc<RwLock<Vec<AuditEntry>>>,
    /// Shutdown flag
    is_shutdown: Arc<RwLock<bool>>,
}

/// Audit trail entry for state transitions
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    pub timestamp: u64,
    pub task_id: TaskId,
    pub from_state: TaskState,
    pub to_state: TaskState,
    pub reason: String,
}

impl OrbitalCoordinator {
    /// Create new coordinator with default watchdog config
    pub fn new() -> Self {
        Self::with_config(WatchdogConfig::default())
    }

    /// Create new coordinator with custom watchdog config
    pub fn with_config(watchdog_config: WatchdogConfig) -> Self {
        info!("Initializing OrbitalCoordinator with watchdog timeout={}s",
              watchdog_config.timeout_secs);

        OrbitalCoordinator {
            tasks: Arc::new(RwLock::new(HashMap::new())),
            fault_state: Arc::new(RwLock::new(FaultState::Healthy)),
            task_id_counter: Arc::new(AtomicU64::new(1)),
            watchdog_config,
            audit_trail: Arc::new(RwLock::new(Vec::new())),
            is_shutdown: Arc::new(RwLock::new(false)),
        }
    }

    /// Create new task
    pub fn create_task(&self, name: String, priority: u8, max_retries: u32) -> Result<TaskId> {
        if *self.is_shutdown.read() {
            return Err(CoreError::CoordinatorShutdown {
                reason: "Cannot create task on shutdown coordinator".to_string(),
            });
        }

        let task_id = TaskId::from_raw(self.task_id_counter.fetch_add(1, Ordering::SeqCst));
        let now = current_timestamp();

        let metadata = TaskMetadata {
            id: task_id,
            name: name.clone(),
            state: TaskState::Created,
            created_at: now,
            last_transition_at: now,
            last_heartbeat: now,
            attempt_count: 0,
            max_retries,
            last_error: None,
            priority,
        };

        {
            let mut tasks = self.tasks.write();
            tasks.insert(task_id, metadata);
        }

        info!("Task created: {} ({})", task_id, name);
        Ok(task_id)
    }

    /// Transition task to new state with audit trail
    pub fn transition_task(&self, task_id: TaskId, new_state: TaskState) -> Result<()> {
        let now = current_timestamp();

        let mut tasks = self.tasks.write();
        let metadata = tasks.get_mut(&task_id)
            .ok_or(CoreError::TaskNotFound {
                task_id: task_id.to_string(),
            })?;

        let old_state = metadata.state;

        // Validate state transition
        if !self.is_valid_transition(old_state, new_state) {
            return Err(CoreError::InvalidStateTransition {
                from: format!("{}", old_state),
                to: format!("{}", new_state),
            });
        }

        metadata.state = new_state;
        metadata.last_transition_at = now;

        if new_state == TaskState::Running {
            metadata.last_heartbeat = now;
            metadata.attempt_count += 1;
        }

        debug!("Task {} transitioned {} -> {}", task_id, old_state, new_state);

        // Record audit entry
        drop(tasks);
        {
            let mut audit = self.audit_trail.write();
            audit.push(AuditEntry {
                timestamp: now,
                task_id,
                from_state: old_state,
                to_state: new_state,
                reason: format!("{} -> {}", old_state, new_state),
            });
        }

        Ok(())
    }

    /// Record heartbeat for task (watchdog integration)
    pub fn record_heartbeat(&self, task_id: TaskId) -> Result<()> {
        let now = current_timestamp();
        let mut tasks = self.tasks.write();

        let metadata = tasks.get_mut(&task_id)
            .ok_or(CoreError::TaskNotFound {
                task_id: task_id.to_string(),
            })?;

        metadata.last_heartbeat = now;
        debug!("Heartbeat recorded for {}", task_id);
        Ok(())
    }

    /// Check task watchdog status and recover if needed
    pub fn check_watchdog(&self, task_id: TaskId) -> Result<bool> {
        let now = current_timestamp();
        let timeout = Duration::from_secs(self.watchdog_config.timeout_secs);

        let tasks = self.tasks.read();
        let metadata = tasks.get(&task_id)
            .ok_or(CoreError::TaskNotFound {
                task_id: task_id.to_string(),
            })?;

        if metadata.state != TaskState::Running {
            return Ok(true);
        }

        let is_timeout = metadata.is_watchdog_timeout(timeout, now);

        if is_timeout {
            drop(tasks);

            warn!("Watchdog timeout detected for {}", task_id);

            if self.watchdog_config.auto_recovery {
                let mut fault_state = self.fault_state.write();
                *fault_state = FaultState::Transient;

                self.transition_task(task_id, TaskState::Failed)?;

                // Update error in metadata
                {
                    let mut tasks = self.tasks.write();
                    if let Some(meta) = tasks.get_mut(&task_id) {
                        meta.last_error = Some("Watchdog timeout - automatic recovery triggered".to_string());
                    }
                }
            }

            return Err(CoreError::WatchdogTimeout {
                task_id: task_id.to_string(),
                seconds: self.watchdog_config.timeout_secs,
            });
        }

        Ok(true)
    }

    /// Get task metadata
    pub fn get_task(&self, task_id: TaskId) -> Result<TaskMetadata> {
        let tasks = self.tasks.read();
        tasks.get(&task_id)
            .cloned()
            .ok_or(CoreError::TaskNotFound {
                task_id: task_id.to_string(),
            })
    }

    /// Record task error with classification
    pub fn record_error(&self, task_id: TaskId, error: String, classification: ErrorClassification) -> Result<()> {
        let mut tasks = self.tasks.write();
        let metadata = tasks.get_mut(&task_id)
            .ok_or(CoreError::TaskNotFound {
                task_id: task_id.to_string(),
            })?;

        metadata.last_error = Some(error.clone());

        match classification {
            ErrorClassification::Transient => {
                debug!("Transient error recorded for {}: {}", task_id, error);
            }
            ErrorClassification::Recoverable => {
                warn!("Recoverable error recorded for {}: {}", task_id, error);
            }
            ErrorClassification::Fatal => {
                error!("Fatal error recorded for {}: {}", task_id, error);
                *self.fault_state.write() = FaultState::Fatal;
            }
        }

        Ok(())
    }

    /// Attempt task recovery after transient failure
    pub fn recover_task(&self, task_id: TaskId) -> Result<()> {
        let metadata = self.get_task(task_id)?;

        if metadata.exceeded_retries() {
            return Err(CoreError::TaskExecution {
                message: format!("Task {} exceeded maximum retries ({})", task_id, metadata.max_retries),
                classification: ErrorClassification::Fatal,
            });
        }

        self.transition_task(task_id, TaskState::Queued)?;
        info!("Task {} queued for recovery (attempt {})", task_id, metadata.attempt_count + 1);
        Ok(())
    }

    /// Get current fault state
    pub fn get_fault_state(&self) -> FaultState {
        *self.fault_state.read()
    }

    /// Set fault state (deterministic state machine)
    pub fn set_fault_state(&self, state: FaultState) -> Result<()> {
        let current = *self.fault_state.read();

        // Validate state transitions
        let valid = match (current, state) {
            (FaultState::Healthy, FaultState::Transient) => true,
            (FaultState::Healthy, FaultState::Fatal) => true,
            (FaultState::Transient, FaultState::Healthy) => true,
            (FaultState::Transient, FaultState::Recoverable) => true,
            (FaultState::Transient, FaultState::Fatal) => true,
            (FaultState::Recoverable, FaultState::Recovering) => true,
            (FaultState::Recovering, FaultState::Healthy) => true,
            (FaultState::Recovering, FaultState::Fatal) => true,
            (FaultState::Fatal, _) => false,
            _ => false,
        };

        if !valid {
            return Err(CoreError::DeterminismViolation {
                detail: format!("Invalid fault state transition: {:?} -> {:?}", current, state),
            });
        }

        *self.fault_state.write() = state;
        info!("Fault state transitioned: {:?} -> {:?}", current, state);
        Ok(())
    }

    /// Get audit trail
    pub fn get_audit_trail(&self) -> Vec<AuditEntry> {
        self.audit_trail.read().clone()
    }

    /// Gracefully shutdown coordinator
    pub fn shutdown(&self) -> Result<()> {
        *self.is_shutdown.write() = true;
        info!("OrbitalCoordinator shutdown initiated");
        Ok(())
    }

    /// Check if coordinator is shutdown
    pub fn is_shutdown(&self) -> bool {
        *self.is_shutdown.read()
    }

    fn is_valid_transition(&self, from: TaskState, to: TaskState) -> bool {
        match (from, to) {
            (TaskState::Created, TaskState::Queued) => true,
            (TaskState::Queued, TaskState::Running) => true,
            (TaskState::Queued, TaskState::Cancelled) => true,
            (TaskState::Running, TaskState::Completed) => true,
            (TaskState::Running, TaskState::Failed) => true,
            (TaskState::Failed, TaskState::Queued) => true,
            (TaskState::Failed, TaskState::Cancelled) => true,
            _ => false,
        }
    }
}

impl Default for OrbitalCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

/// Get current timestamp in seconds since UNIX_EPOCH
fn current_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_coordinator_initialization() {
        let coordinator = OrbitalCoordinator::new();
        assert!(!coordinator.is_shutdown());
        assert_eq!(coordinator.get_fault_state(), FaultState::Healthy);
    }

    #[test]
    fn test_create_task() {
        let coordinator = OrbitalCoordinator::new();
        let task_id = coordinator.create_task("test_task".to_string(), 128, 3)
            .expect("Task creation failed");

        let metadata = coordinator.get_task(task_id)
            .expect("Task not found");

        assert_eq!(metadata.name, "test_task");
        assert_eq!(metadata.state, TaskState::Created);
        assert_eq!(metadata.priority, 128);
        assert_eq!(metadata.max_retries, 3);
    }

    #[test]
    fn test_task_state_transitions() {
        let coordinator = OrbitalCoordinator::new();
        let task_id = coordinator.create_task("test".to_string(), 100, 3)
            .expect("Task creation failed");

        // Created -> Queued
        coordinator.transition_task(task_id, TaskState::Queued)
            .expect("Transition failed");
        assert_eq!(coordinator.get_task(task_id).unwrap().state, TaskState::Queued);

        // Queued -> Running
        coordinator.transition_task(task_id, TaskState::Running)
            .expect("Transition failed");
        assert_eq!(coordinator.get_task(task_id).unwrap().state, TaskState::Running);

        // Running -> Completed
        coordinator.transition_task(task_id, TaskState::Completed)
            .expect("Transition failed");
        assert_eq!(coordinator.get_task(task_id).unwrap().state, TaskState::Completed);
    }

    #[test]
    fn test_invalid_state_transition() {
        let coordinator = OrbitalCoordinator::new();
        let task_id = coordinator.create_task("test".to_string(), 100, 3)
            .expect("Task creation failed");

        // Try invalid transition: Created -> Completed
        let result = coordinator.transition_task(task_id, TaskState::Completed);
        assert!(result.is_err());
    }

    #[test]
    fn test_heartbeat_recording() {
        let coordinator = OrbitalCoordinator::new();
        let task_id = coordinator.create_task("test".to_string(), 100, 3)
            .expect("Task creation failed");

        let initial_hb = coordinator.get_task(task_id).unwrap().last_heartbeat;

        // Record new heartbeat
        coordinator.record_heartbeat(task_id)
            .expect("Heartbeat recording failed");

        let new_hb = coordinator.get_task(task_id).unwrap().last_heartbeat;
        assert!(new_hb >= initial_hb);
    }

    #[test]
    fn test_watchdog_timeout() {
        let config = WatchdogConfig {
            timeout_secs: 1,
            initial_backoff_ms: 100,
            max_backoff_ms: 30000,
            auto_recovery: true,
        };
        let coordinator = OrbitalCoordinator::with_config(config);
        let task_id = coordinator.create_task("test".to_string(), 100, 3)
            .expect("Task creation failed");

        coordinator.transition_task(task_id, TaskState::Queued)
            .expect("Transition failed");
        coordinator.transition_task(task_id, TaskState::Running)
            .expect("Transition failed");

        // Simulate timeout by manually manipulating metadata
        {
            let mut tasks = coordinator.tasks.write();
            if let Some(meta) = tasks.get_mut(&task_id) {
                meta.last_heartbeat = 0;
            }
        }

        let result = coordinator.check_watchdog(task_id);
        assert!(result.is_err());
    }

    #[test]
    fn test_error_recording_and_classification() {
        let coordinator = OrbitalCoordinator::new();
        let task_id = coordinator.create_task("test".to_string(), 100, 3)
            .expect("Task creation failed");

        coordinator.record_error(
            task_id,
            "Test transient error".to_string(),
            ErrorClassification::Transient,
        ).expect("Error recording failed");

        let metadata = coordinator.get_task(task_id).unwrap();
        assert!(metadata.last_error.is_some());
        assert_eq!(metadata.last_error.unwrap(), "Test transient error");
    }

    #[test]
    fn test_task_recovery() {
        let coordinator = OrbitalCoordinator::new();
        let task_id = coordinator.create_task("test".to_string(), 100, 3)
            .expect("Task creation failed");

        coordinator.transition_task(task_id, TaskState::Queued)
            .expect("Transition failed");
        coordinator.transition_task(task_id, TaskState::Running)
            .expect("Transition failed");
        coordinator.transition_task(task_id, TaskState::Failed)
            .expect("Transition failed");

        // Recover task
        coordinator.recover_task(task_id)
            .expect("Recovery failed");

        assert_eq!(coordinator.get_task(task_id).unwrap().state, TaskState::Queued);
    }

    #[test]
    fn test_exceed_max_retries() {
        let coordinator = OrbitalCoordinator::new();
        let task_id = coordinator.create_task("test".to_string(), 100, 1)
            .expect("Task creation failed");

        // Simulate 2 failed attempts
        for _ in 0..2 {
            coordinator.transition_task(task_id, TaskState::Queued).ok();
            coordinator.transition_task(task_id, TaskState::Running).ok();
            coordinator.transition_task(task_id, TaskState::Failed).ok();
        }

        let result = coordinator.recover_task(task_id);
        assert!(result.is_err());
    }

    #[test]
    fn test_fault_state_machine() {
        let coordinator = OrbitalCoordinator::new();

        assert_eq!(coordinator.get_fault_state(), FaultState::Healthy);

        coordinator.set_fault_state(FaultState::Transient)
            .expect("State transition failed");
        assert_eq!(coordinator.get_fault_state(), FaultState::Transient);

        coordinator.set_fault_state(FaultState::Healthy)
            .expect("State transition failed");
        assert_eq!(coordinator.get_fault_state(), FaultState::Healthy);
    }

    #[test]
    fn test_audit_trail() {
        let coordinator = OrbitalCoordinator::new();
        let task_id = coordinator.create_task("test".to_string(), 100, 3)
            .expect("Task creation failed");

        coordinator.transition_task(task_id, TaskState::Queued)
            .expect("Transition failed");
        coordinator.transition_task(task_id, TaskState::Running)
            .expect("Transition failed");

        let audit = coordinator.get_audit_trail();
        assert!(audit.len() >= 2);
    }

    #[test]
    fn test_task_not_found() {
        let coordinator = OrbitalCoordinator::new();
        let fake_id = TaskId::from_raw(999);

        let result = coordinator.get_task(fake_id);
        assert!(result.is_err());
    }

    #[test]
    fn test_shutdown_prevents_new_tasks() {
        let coordinator = OrbitalCoordinator::new();
        coordinator.shutdown().expect("Shutdown failed");

        let result = coordinator.create_task("test".to_string(), 100, 3);
        assert!(result.is_err());
        assert!(coordinator.is_shutdown());
    }

    #[test]
    fn test_multiple_tasks() {
        let coordinator = OrbitalCoordinator::new();

        let task1 = coordinator.create_task("task1".to_string(), 100, 3).unwrap();
        let task2 = coordinator.create_task("task2".to_string(), 50, 2).unwrap();
        let task3 = coordinator.create_task("task3".to_string(), 150, 5).unwrap();

        assert_ne!(task1, task2);
        assert_ne!(task2, task3);

        let m1 = coordinator.get_task(task1).unwrap();
        let m2 = coordinator.get_task(task2).unwrap();
        let m3 = coordinator.get_task(task3).unwrap();

        assert_eq!(m1.priority, 100);
        assert_eq!(m2.priority, 50);
        assert_eq!(m3.priority, 150);
    }

    #[test]
    fn test_task_id_uniqueness() {
        let coordinator = OrbitalCoordinator::new();
        let ids: Vec<_> = (0..100)
            .map(|_| coordinator.create_task("test".to_string(), 100, 3).unwrap())
            .collect();

        for i in 0..ids.len() {
            for j in (i+1)..ids.len() {
                assert_ne!(ids[i], ids[j]);
            }
        }
    }

    #[test]
    fn test_error_classification() {
        let transient_err = CoreError::WatchdogTimeout {
            task_id: "t1".to_string(),
            seconds: 30,
        };
        assert_eq!(transient_err.classification(), ErrorClassification::Transient);

        let fatal_err = CoreError::DeterminismViolation {
            detail: "test".to_string(),
        };
        assert_eq!(fatal_err.classification(), ErrorClassification::Fatal);
    }

    #[test]
    fn test_task_attempt_count_increment() {
        let coordinator = OrbitalCoordinator::new();
        let task_id = coordinator.create_task("test".to_string(), 100, 5)
            .expect("Task creation failed");

        assert_eq!(coordinator.get_task(task_id).unwrap().attempt_count, 0);

        coordinator.transition_task(task_id, TaskState::Queued).unwrap();
        coordinator.transition_task(task_id, TaskState::Running).unwrap();
        assert_eq!(coordinator.get_task(task_id).unwrap().attempt_count, 1);

        coordinator.transition_task(task_id, TaskState::Failed).unwrap();
        coordinator.recover_task(task_id).unwrap();
        coordinator.transition_task(task_id, TaskState::Running).unwrap();
        assert_eq!(coordinator.get_task(task_id).unwrap().attempt_count, 2);
    }
}
