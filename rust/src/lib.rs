// fjall-ffi: UniFFI bridge exposing the fjall storage engine to Swift.
//
// Naming: all exported types carry an `Ffi` prefix so the hand-written
// Swift facade (the `Fjall` module) can use the natural names.

use std::ops::Bound;
use std::sync::{Arc, Mutex};

uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Mirror of `fjall::Error`, flattened into FFI-friendly variants.
#[derive(Debug, uniffi::Error)]
pub enum FfiError {
    /// I/O error
    Io { message: String },
    /// Error inside the storage engine (lsm-tree)
    Storage { message: String },
    /// Error during journal recovery
    JournalRecovery { message: String },
    /// Database format version mismatch
    InvalidVersion { message: String },
    /// Decompression failed
    Decompress { message: String },
    /// A lock is poisoned (a thread panicked while holding it)
    Poisoned,
    /// The keyspace was deleted
    KeyspaceDeleted,
    /// The database is locked by another process
    Locked,
    /// The database is in an unrecoverable state
    Unrecoverable,
    /// The write batch was already committed and cannot be used again
    BatchConsumed,
    /// Any other error
    Other { message: String },
}

impl std::fmt::Display for FfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io { message } => write!(f, "I/O error: {message}"),
            Self::Storage { message } => write!(f, "storage error: {message}"),
            Self::JournalRecovery { message } => write!(f, "journal recovery error: {message}"),
            Self::InvalidVersion { message } => write!(f, "invalid format version: {message}"),
            Self::Decompress { message } => write!(f, "decompression error: {message}"),
            Self::Poisoned => write!(f, "lock is poisoned"),
            Self::KeyspaceDeleted => write!(f, "keyspace was deleted"),
            Self::Locked => write!(f, "database is locked by another process"),
            Self::Unrecoverable => write!(f, "database is unrecoverable"),
            Self::BatchConsumed => write!(f, "write batch was already committed"),
            Self::Other { message } => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for FfiError {}

impl From<fjall::Error> for FfiError {
    fn from(err: fjall::Error) -> Self {
        match err {
            fjall::Error::Io(e) => Self::Io {
                message: e.to_string(),
            },
            fjall::Error::Storage(e) => Self::Storage {
                message: e.to_string(),
            },
            fjall::Error::JournalRecovery(e) => Self::JournalRecovery {
                message: format!("{e:?}"),
            },
            fjall::Error::InvalidVersion(v) => Self::InvalidVersion {
                message: format!("{v:?}"),
            },
            fjall::Error::Decompress(c) => Self::Decompress {
                message: format!("{c:?}"),
            },
            fjall::Error::Poisoned => Self::Poisoned,
            fjall::Error::KeyspaceDeleted => Self::KeyspaceDeleted,
            fjall::Error::Locked => Self::Locked,
            fjall::Error::Unrecoverable => Self::Unrecoverable,
            other => Self::Other {
                message: other.to_string(),
            },
        }
    }
}

type FfiResult<T> = Result<T, FfiError>;

// ---------------------------------------------------------------------------
// Enums & records
// ---------------------------------------------------------------------------

/// Durability level for persisting the journal, mirrors `fjall::PersistMode`.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiPersistMode {
    /// Flushes data to OS buffers, safe against application crash.
    Buffer,
    /// Flushes data using `fdatasync`.
    SyncData,
    /// Flushes data + metadata using `fsync`.
    SyncAll,
}

impl From<FfiPersistMode> for fjall::PersistMode {
    fn from(mode: FfiPersistMode) -> Self {
        match mode {
            FfiPersistMode::Buffer => Self::Buffer,
            FfiPersistMode::SyncData => Self::SyncData,
            FfiPersistMode::SyncAll => Self::SyncAll,
        }
    }
}

/// Compression algorithm, mirrors `fjall::CompressionType`.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiCompression {
    None,
    Lz4,
}

impl From<FfiCompression> for fjall::CompressionType {
    fn from(c: FfiCompression) -> Self {
        match c {
            FfiCompression::None => Self::None,
            FfiCompression::Lz4 => Self::Lz4,
        }
    }
}

/// A key-value pair.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiKvPair {
    pub key: Vec<u8>,
    pub value: Vec<u8>,
}

impl From<fjall::KvPair> for FfiKvPair {
    fn from((key, value): fjall::KvPair) -> Self {
        Self {
            key: key.to_vec(),
            value: value.to_vec(),
        }
    }
}

/// One end of a key range.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiBound {
    pub key: Vec<u8>,
    pub inclusive: bool,
}

fn to_bound(bound: Option<FfiBound>) -> Bound<Vec<u8>> {
    match bound {
        None => Bound::Unbounded,
        Some(FfiBound {
            key,
            inclusive: true,
        }) => Bound::Included(key),
        Some(FfiBound {
            key,
            inclusive: false,
        }) => Bound::Excluded(key),
    }
}

/// Database-level configuration, mirrors `fjall::DatabaseBuilder` options.
/// Every field is optional; `None` keeps fjall's default.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct FfiDatabaseConfig {
    /// Size of the block cache in bytes.
    #[uniffi(default = None)]
    pub cache_size_bytes: Option<u64>,
    /// If true, the database is deleted when dropped.
    #[uniffi(default = None)]
    pub temporary: Option<bool>,
    /// If true, the journal is only persisted on explicit `persist` calls.
    #[uniffi(default = None)]
    pub manual_journal_persist: Option<bool>,
    /// Maximum size of the journal before forcing a flush.
    #[uniffi(default = None)]
    pub max_journaling_size_bytes: Option<u64>,
    /// Compression to use for the journal.
    #[uniffi(default = None)]
    pub journal_compression: Option<FfiCompression>,
    /// Number of background worker threads.
    #[uniffi(default = None)]
    pub worker_threads: Option<u32>,
}

/// Options for key-value separation (storing large values out of line),
/// mirrors `fjall::KvSeparationOptions`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiKvSeparationOptions {
    /// Values at least this many bytes are stored separately.
    #[uniffi(default = None)]
    pub separation_threshold_bytes: Option<u32>,
    /// Target size of blob files.
    #[uniffi(default = None)]
    pub file_target_size_bytes: Option<u64>,
    /// Compression for blob files.
    #[uniffi(default = None)]
    pub compression: Option<FfiCompression>,
}

/// Options used when creating a keyspace, mirrors `fjall::KeyspaceCreateOptions`.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct FfiKeyspaceOptions {
    /// Maximum size of this keyspace's memtable.
    #[uniffi(default = None)]
    pub max_memtable_size_bytes: Option<u64>,
    /// If true, journal writes for this keyspace are only persisted on explicit `persist` calls.
    #[uniffi(default = None)]
    pub manual_journal_persist: Option<bool>,
    /// Enable key-value separation (recommended for large values).
    #[uniffi(default = None)]
    pub kv_separation: Option<FfiKvSeparationOptions>,
}

fn build_create_options(options: FfiKeyspaceOptions) -> fjall::KeyspaceCreateOptions {
    let mut opts = fjall::KeyspaceCreateOptions::default();
    if let Some(bytes) = options.max_memtable_size_bytes {
        opts = opts.max_memtable_size(bytes);
    }
    if let Some(flag) = options.manual_journal_persist {
        opts = opts.manual_journal_persist(flag);
    }
    if let Some(kv) = options.kv_separation {
        let mut sep = fjall::KvSeparationOptions::default();
        if let Some(threshold) = kv.separation_threshold_bytes {
            sep = sep.separation_threshold(threshold);
        }
        if let Some(target) = kv.file_target_size_bytes {
            sep = sep.file_target_size(target);
        }
        if let Some(compression) = kv.compression {
            sep = sep.compression(compression.into());
        }
        opts = opts.with_kv_separation(Some(sep));
    }
    opts
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

/// Handle to a fjall database, mirrors `fjall::Database`.
#[derive(uniffi::Object)]
pub struct FfiDatabase {
    inner: fjall::Database,
}

#[uniffi::export]
impl FfiDatabase {
    /// Opens (or creates) a database at the given path.
    #[uniffi::constructor]
    pub fn open(path: String, config: FfiDatabaseConfig) -> FfiResult<Arc<Self>> {
        let mut builder = fjall::Database::builder(&path);
        if let Some(bytes) = config.cache_size_bytes {
            builder = builder.cache_size(bytes);
        }
        if let Some(flag) = config.temporary {
            builder = builder.temporary(flag);
        }
        if let Some(flag) = config.manual_journal_persist {
            builder = builder.manual_journal_persist(flag);
        }
        if let Some(bytes) = config.max_journaling_size_bytes {
            builder = builder.max_journaling_size(bytes);
        }
        if let Some(compression) = config.journal_compression {
            builder = builder.journal_compression(compression.into());
        }
        if let Some(n) = config.worker_threads {
            builder = builder.worker_threads(n as usize);
        }
        Ok(Arc::new(Self {
            inner: builder.open()?,
        }))
    }

    /// Opens a keyspace, creating it (with the given options) if it does not exist.
    pub fn keyspace(
        &self,
        name: String,
        options: FfiKeyspaceOptions,
    ) -> FfiResult<Arc<FfiKeyspace>> {
        let keyspace = self
            .inner
            .keyspace(&name, move || build_create_options(options))?;
        Ok(Arc::new(FfiKeyspace { inner: keyspace }))
    }

    /// Returns true if a keyspace with this name exists.
    pub fn keyspace_exists(&self, name: String) -> bool {
        self.inner.keyspace_exists(&name)
    }

    /// Number of keyspaces in the database.
    pub fn keyspace_count(&self) -> u64 {
        self.inner.keyspace_count() as u64
    }

    /// Names of all keyspaces in the database.
    pub fn list_keyspace_names(&self) -> Vec<String> {
        self.inner
            .list_keyspace_names()
            .into_iter()
            .map(|name| name.to_string())
            .collect()
    }

    /// Deletes a keyspace and all its data.
    pub fn delete_keyspace(&self, keyspace: Arc<FfiKeyspace>) -> FfiResult<()> {
        self.inner.delete_keyspace(keyspace.inner.clone())?;
        Ok(())
    }

    /// Persists the journal to disk with the given durability level.
    pub fn persist(&self, mode: FfiPersistMode) -> FfiResult<()> {
        self.inner.persist(mode.into())?;
        Ok(())
    }

    /// Creates a new atomic write batch.
    pub fn batch(&self) -> Arc<FfiWriteBatch> {
        Arc::new(FfiWriteBatch {
            inner: Mutex::new(Some(self.inner.batch())),
        })
    }

    /// Creates a cross-keyspace snapshot for consistent reads.
    pub fn snapshot(&self) -> Arc<FfiSnapshot> {
        Arc::new(FfiSnapshot {
            inner: self.inner.snapshot(),
        })
    }

    /// Total disk space used by the database.
    pub fn disk_space(&self) -> FfiResult<u64> {
        Ok(self.inner.disk_space()?)
    }

    /// Disk space used by the journal.
    pub fn journal_disk_space(&self) -> FfiResult<u64> {
        Ok(self.inner.journal_disk_space()?)
    }

    /// Number of journal files.
    pub fn journal_count(&self) -> u64 {
        self.inner.journal_count() as u64
    }

    /// Current size of the block cache in bytes.
    pub fn cache_size(&self) -> u64 {
        self.inner.cache_size()
    }

    /// Capacity of the block cache in bytes.
    pub fn cache_capacity(&self) -> u64 {
        self.inner.cache_capacity()
    }

    /// Current size of all write buffers in bytes.
    pub fn write_buffer_size(&self) -> u64 {
        self.inner.write_buffer_size()
    }
}

// ---------------------------------------------------------------------------
// Keyspace
// ---------------------------------------------------------------------------

/// Handle to a keyspace (a single LSM-tree), mirrors `fjall::Keyspace`.
#[derive(uniffi::Object)]
pub struct FfiKeyspace {
    inner: fjall::Keyspace,
}

fn guard_to_pair(guard: Option<fjall::Guard>) -> FfiResult<Option<FfiKvPair>> {
    match guard {
        None => Ok(None),
        Some(guard) => Ok(Some(guard.into_inner().map(FfiKvPair::from)?)),
    }
}

#[uniffi::export]
impl FfiKeyspace {
    /// Name of the keyspace.
    pub fn name(&self) -> String {
        self.inner.name().to_string()
    }

    /// Filesystem path of the keyspace's data.
    pub fn path(&self) -> String {
        self.inner.path().display().to_string()
    }

    /// Inserts a key-value pair, overwriting any previous value.
    pub fn insert(&self, key: Vec<u8>, value: Vec<u8>) -> FfiResult<()> {
        self.inner.insert(key, value)?;
        Ok(())
    }

    /// Retrieves the value for a key.
    pub fn get(&self, key: Vec<u8>) -> FfiResult<Option<Vec<u8>>> {
        Ok(self.inner.get(key)?.map(|value| value.to_vec()))
    }

    /// Removes a key (leaves a tombstone).
    pub fn remove(&self, key: Vec<u8>) -> FfiResult<()> {
        self.inner.remove(key)?;
        Ok(())
    }

    /// Removes a key with a weak tombstone (experimental; see fjall docs).
    pub fn remove_weak(&self, key: Vec<u8>) -> FfiResult<()> {
        self.inner.remove_weak(key)?;
        Ok(())
    }

    /// Returns true if the key exists.
    pub fn contains_key(&self, key: Vec<u8>) -> FfiResult<bool> {
        Ok(self.inner.contains_key(key)?)
    }

    /// Size of the value for a key in bytes, without fetching it.
    pub fn size_of(&self, key: Vec<u8>) -> FfiResult<Option<u32>> {
        Ok(self.inner.size_of(key)?)
    }

    /// Exact number of items (requires a full scan).
    pub fn len(&self) -> FfiResult<u64> {
        Ok(self.inner.len()? as u64)
    }

    /// Returns true if the keyspace contains no items.
    pub fn is_empty(&self) -> FfiResult<bool> {
        Ok(self.inner.is_empty()?)
    }

    /// Fast approximation of the number of items (O(1), may overcount).
    pub fn approximate_len(&self) -> u64 {
        self.inner.approximate_len() as u64
    }

    /// Disk space used by this keyspace.
    pub fn disk_space(&self) -> u64 {
        self.inner.disk_space()
    }

    /// Removes all items from the keyspace in O(1).
    pub fn clear(&self) -> FfiResult<()> {
        self.inner.clear()?;
        Ok(())
    }

    /// Runs a major compaction, merging everything into one run.
    pub fn major_compact(&self) -> FfiResult<()> {
        Ok(self.inner.major_compact()?)
    }

    /// The first (minimum) key-value pair.
    pub fn first_key_value(&self) -> FfiResult<Option<FfiKvPair>> {
        guard_to_pair(self.inner.first_key_value())
    }

    /// The last (maximum) key-value pair.
    pub fn last_key_value(&self) -> FfiResult<Option<FfiKvPair>> {
        guard_to_pair(self.inner.last_key_value())
    }

    /// Iterates over the whole keyspace.
    pub fn iter(&self) -> Arc<FfiIterator> {
        FfiIterator::new(self.inner.iter())
    }

    /// Iterates over a key range. `None` bounds are unbounded.
    pub fn range(&self, lower: Option<FfiBound>, upper: Option<FfiBound>) -> Arc<FfiIterator> {
        FfiIterator::new(
            self.inner
                .range::<Vec<u8>, _>((to_bound(lower), to_bound(upper))),
        )
    }

    /// Iterates over all keys starting with the given prefix.
    pub fn prefix(&self, prefix: Vec<u8>) -> Arc<FfiIterator> {
        FfiIterator::new(self.inner.prefix(prefix))
    }
}

// ---------------------------------------------------------------------------
// Iterator
// ---------------------------------------------------------------------------

/// A double-ended iterator over key-value pairs.
///
/// Holds a snapshot of the database for consistent iteration.
#[derive(uniffi::Object)]
pub struct FfiIterator {
    inner: Mutex<fjall::Iter>,
}

impl FfiIterator {
    fn new(iter: fjall::Iter) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(iter),
        })
    }
}

#[uniffi::export]
impl FfiIterator {
    /// Next pair from the front, or None when exhausted.
    pub fn next(&self) -> FfiResult<Option<FfiKvPair>> {
        let mut iter = self.inner.lock().map_err(|_| FfiError::Poisoned)?;
        match iter.next() {
            None => Ok(None),
            Some(guard) => Ok(Some(guard.into_inner().map(FfiKvPair::from)?)),
        }
    }

    /// Next pair from the back, or None when exhausted.
    pub fn next_back(&self) -> FfiResult<Option<FfiKvPair>> {
        let mut iter = self.inner.lock().map_err(|_| FfiError::Poisoned)?;
        match iter.next_back() {
            None => Ok(None),
            Some(guard) => Ok(Some(guard.into_inner().map(FfiKvPair::from)?)),
        }
    }

    /// Up to `count` pairs from the front. Fewer (or zero) means exhausted.
    /// Reduces FFI round-trips compared to calling `next` repeatedly.
    pub fn next_many(&self, count: u32) -> FfiResult<Vec<FfiKvPair>> {
        let mut iter = self.inner.lock().map_err(|_| FfiError::Poisoned)?;
        let mut out = Vec::with_capacity(count as usize);
        for _ in 0..count {
            match iter.next() {
                None => break,
                Some(guard) => out.push(guard.into_inner().map(FfiKvPair::from)?),
            }
        }
        Ok(out)
    }

    /// Up to `count` pairs from the back. Fewer (or zero) means exhausted.
    pub fn next_back_many(&self, count: u32) -> FfiResult<Vec<FfiKvPair>> {
        let mut iter = self.inner.lock().map_err(|_| FfiError::Poisoned)?;
        let mut out = Vec::with_capacity(count as usize);
        for _ in 0..count {
            match iter.next_back() {
                None => break,
                Some(guard) => out.push(guard.into_inner().map(FfiKvPair::from)?),
            }
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------

/// A consistent, cross-keyspace point-in-time view, mirrors `fjall::Snapshot`.
#[derive(uniffi::Object)]
pub struct FfiSnapshot {
    inner: fjall::Snapshot,
}

#[uniffi::export]
impl FfiSnapshot {
    /// Retrieves the value for a key as of this snapshot.
    pub fn get(&self, keyspace: Arc<FfiKeyspace>, key: Vec<u8>) -> FfiResult<Option<Vec<u8>>> {
        use fjall::Readable;
        Ok(self
            .inner
            .get(&keyspace.inner, key)?
            .map(|value| value.to_vec()))
    }

    /// Returns true if the key exists in this snapshot.
    pub fn contains_key(&self, keyspace: Arc<FfiKeyspace>, key: Vec<u8>) -> FfiResult<bool> {
        use fjall::Readable;
        Ok(self.inner.contains_key(&keyspace.inner, key)?)
    }

    /// Size of the value for a key in bytes in this snapshot.
    pub fn size_of(&self, keyspace: Arc<FfiKeyspace>, key: Vec<u8>) -> FfiResult<Option<u32>> {
        use fjall::Readable;
        Ok(self.inner.size_of(&keyspace.inner, key)?)
    }

    /// Exact number of items in this snapshot (full scan).
    pub fn len(&self, keyspace: Arc<FfiKeyspace>) -> FfiResult<u64> {
        use fjall::Readable;
        Ok(self.inner.len(&keyspace.inner)? as u64)
    }

    /// Returns true if the keyspace is empty in this snapshot.
    pub fn is_empty(&self, keyspace: Arc<FfiKeyspace>) -> FfiResult<bool> {
        use fjall::Readable;
        Ok(self.inner.is_empty(&keyspace.inner)?)
    }

    /// The first (minimum) key-value pair in this snapshot.
    pub fn first_key_value(&self, keyspace: Arc<FfiKeyspace>) -> FfiResult<Option<FfiKvPair>> {
        use fjall::Readable;
        guard_to_pair(self.inner.first_key_value(&keyspace.inner))
    }

    /// The last (maximum) key-value pair in this snapshot.
    pub fn last_key_value(&self, keyspace: Arc<FfiKeyspace>) -> FfiResult<Option<FfiKvPair>> {
        use fjall::Readable;
        guard_to_pair(self.inner.last_key_value(&keyspace.inner))
    }

    /// Iterates over the whole keyspace as of this snapshot.
    pub fn iter(&self, keyspace: Arc<FfiKeyspace>) -> Arc<FfiIterator> {
        use fjall::Readable;
        FfiIterator::new(self.inner.iter(&keyspace.inner))
    }

    /// Iterates over a key range as of this snapshot.
    pub fn range(
        &self,
        keyspace: Arc<FfiKeyspace>,
        lower: Option<FfiBound>,
        upper: Option<FfiBound>,
    ) -> Arc<FfiIterator> {
        use fjall::Readable;
        FfiIterator::new(
            self.inner
                .range::<Vec<u8>, _>(&keyspace.inner, (to_bound(lower), to_bound(upper))),
        )
    }

    /// Iterates over all keys starting with the given prefix, as of this snapshot.
    pub fn prefix(&self, keyspace: Arc<FfiKeyspace>, prefix: Vec<u8>) -> Arc<FfiIterator> {
        use fjall::Readable;
        FfiIterator::new(self.inner.prefix(&keyspace.inner, prefix))
    }
}

// ---------------------------------------------------------------------------
// WriteBatch
// ---------------------------------------------------------------------------

/// An atomic write batch, mirrors `fjall::OwnedWriteBatch`.
///
/// Contains `None` after a successful `commit`.
#[derive(uniffi::Object)]
pub struct FfiWriteBatch {
    inner: Mutex<Option<fjall::OwnedWriteBatch>>,
}

impl FfiWriteBatch {
    fn with_batch<T>(&self, f: impl FnOnce(&mut fjall::OwnedWriteBatch) -> T) -> FfiResult<T> {
        let mut guard = self.inner.lock().map_err(|_| FfiError::Poisoned)?;
        match guard.as_mut() {
            None => Err(FfiError::BatchConsumed),
            Some(batch) => Ok(f(batch)),
        }
    }
}

#[uniffi::export]
impl FfiWriteBatch {
    /// Stages an insert.
    pub fn insert(
        &self,
        keyspace: Arc<FfiKeyspace>,
        key: Vec<u8>,
        value: Vec<u8>,
    ) -> FfiResult<()> {
        self.with_batch(|batch| batch.insert(&keyspace.inner, key, value))
    }

    /// Stages a removal.
    pub fn remove(&self, keyspace: Arc<FfiKeyspace>, key: Vec<u8>) -> FfiResult<()> {
        self.with_batch(|batch| batch.remove(&keyspace.inner, key))
    }

    /// Stages a weak removal (experimental; see fjall docs).
    pub fn remove_weak(&self, keyspace: Arc<FfiKeyspace>, key: Vec<u8>) -> FfiResult<()> {
        self.with_batch(|batch| batch.remove_weak(&keyspace.inner, key))
    }

    /// Number of staged operations.
    pub fn len(&self) -> FfiResult<u64> {
        self.with_batch(|batch| batch.len() as u64)
    }

    /// Returns true if no operations are staged.
    pub fn is_empty(&self) -> FfiResult<bool> {
        self.with_batch(|batch| batch.is_empty())
    }

    /// Sets the durability level used when the batch commits.
    pub fn set_durability(&self, mode: Option<FfiPersistMode>) -> FfiResult<()> {
        let mut guard = self.inner.lock().map_err(|_| FfiError::Poisoned)?;
        match guard.take() {
            None => Err(FfiError::BatchConsumed),
            Some(batch) => {
                *guard = Some(batch.durability(mode.map(Into::into)));
                Ok(())
            }
        }
    }

    /// Atomically commits all staged operations. The batch cannot be reused.
    pub fn commit(&self) -> FfiResult<()> {
        let mut guard = self.inner.lock().map_err(|_| FfiError::Poisoned)?;
        match guard.take() {
            None => Err(FfiError::BatchConsumed),
            Some(batch) => {
                batch.commit()?;
                Ok(())
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_db() -> (tempfile::TempDir, Arc<FfiDatabase>) {
        let dir = tempfile::tempdir().unwrap();
        let db = FfiDatabase::open(
            dir.path().join("db").display().to_string(),
            FfiDatabaseConfig::default(),
        )
        .unwrap();
        (dir, db)
    }

    #[test]
    fn roundtrip() {
        let (_dir, db) = temp_db();
        let ks = db
            .keyspace("items".into(), FfiKeyspaceOptions::default())
            .unwrap();

        assert!(ks.is_empty().unwrap());
        ks.insert(b"a".to_vec(), b"hello".to_vec()).unwrap();
        ks.insert(b"b".to_vec(), b"world".to_vec()).unwrap();

        assert_eq!(ks.get(b"a".to_vec()).unwrap(), Some(b"hello".to_vec()));
        assert_eq!(ks.get(b"missing".to_vec()).unwrap(), None);
        assert_eq!(ks.len().unwrap(), 2);
        assert!(ks.contains_key(b"b".to_vec()).unwrap());

        ks.remove(b"a".to_vec()).unwrap();
        assert_eq!(ks.get(b"a".to_vec()).unwrap(), None);
    }

    #[test]
    fn iteration() {
        let (_dir, db) = temp_db();
        let ks = db
            .keyspace("items".into(), FfiKeyspaceOptions::default())
            .unwrap();

        for i in 0..10u8 {
            ks.insert(vec![i], vec![i * 2]).unwrap();
        }

        let iter = ks.iter();
        let first = iter.next().unwrap().unwrap();
        assert_eq!(first.key, vec![0]);
        let last = iter.next_back().unwrap().unwrap();
        assert_eq!(last.key, vec![9]);
        let rest = iter.next_many(100).unwrap();
        assert_eq!(rest.len(), 8);

        let ranged = ks.range(
            Some(FfiBound {
                key: vec![2],
                inclusive: true,
            }),
            Some(FfiBound {
                key: vec![5],
                inclusive: false,
            }),
        );
        let items = ranged.next_many(100).unwrap();
        assert_eq!(items.len(), 3);

        let prefixed = ks.prefix(vec![3]);
        assert_eq!(prefixed.next_many(100).unwrap().len(), 1);
    }

    #[test]
    fn batch_and_snapshot() {
        let (_dir, db) = temp_db();
        let ks = db
            .keyspace("items".into(), FfiKeyspaceOptions::default())
            .unwrap();

        ks.insert(b"before".to_vec(), b"1".to_vec()).unwrap();
        let snapshot = db.snapshot();

        let batch = db.batch();
        batch
            .insert(ks.clone(), b"x".to_vec(), b"1".to_vec())
            .unwrap();
        batch
            .insert(ks.clone(), b"y".to_vec(), b"2".to_vec())
            .unwrap();
        assert_eq!(batch.len().unwrap(), 2);
        batch.commit().unwrap();
        assert!(matches!(batch.commit(), Err(FfiError::BatchConsumed)));

        assert_eq!(ks.get(b"x".to_vec()).unwrap(), Some(b"1".to_vec()));
        // Snapshot predates the batch
        assert_eq!(snapshot.get(ks.clone(), b"x".to_vec()).unwrap(), None);
        assert_eq!(
            snapshot.get(ks.clone(), b"before".to_vec()).unwrap(),
            Some(b"1".to_vec())
        );

        db.persist(FfiPersistMode::SyncAll).unwrap();
    }

    #[test]
    fn keyspace_management() {
        let (_dir, db) = temp_db();
        let ks = db
            .keyspace("one".into(), FfiKeyspaceOptions::default())
            .unwrap();
        db.keyspace("two".into(), FfiKeyspaceOptions::default())
            .unwrap();

        assert!(db.keyspace_exists("one".into()));
        assert_eq!(db.keyspace_count(), 2);
        let mut names = db.list_keyspace_names();
        names.sort();
        assert_eq!(names, vec!["one".to_string(), "two".to_string()]);

        db.delete_keyspace(ks).unwrap();
        assert!(!db.keyspace_exists("one".into()));
    }
}
