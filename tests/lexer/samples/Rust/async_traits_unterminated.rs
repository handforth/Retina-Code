// Second Rust sample: async, traits, impl blocks, unsafe, and an unterminated nested comment.
#![forbid(unsafe_op_in_unsafe_fn)]
#![warn(missing_docs, clippy::pedantic)]

//! Inner doc line comment for this module.

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, RwLock};
use std::task::{Context, Poll};

/// Outer doc comment with `code` and [links](https://example.com).
///
/// ```rust
/// let x = "inside a doc test";
/// assert_eq!(x.len(), 17);
/// ```
pub struct Ready<T>(Option<T>);

impl<T: Unpin> Future for Ready<T> {
    type Output = T;
    fn poll(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<T> {
        Poll::Ready(self.0.take().expect("polled after completion"))
    }
}

pub trait Repository: Send + Sync {
    type Error: std::error::Error + Send + Sync + 'static;
    type Item;

    fn get(&self, id: u64) -> impl Future<Output = Result<Option<Self::Item>, Self::Error>> + Send;
    async fn put(&self, id: u64, item: Self::Item) -> Result<(), Self::Error>;
    fn boxed<'a>(&'a self) -> Pin<Box<dyn Future<Output = ()> + Send + 'a>> {
        Box::pin(async move {})
    }
}

#[derive(Debug, thiserror::Error)]
pub enum RepoError {
    #[error("not found: {0}")]
    NotFound(u64),
    #[error("lock poisoned")]
    Poisoned,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(Default)]
pub struct MemRepo<V> {
    inner: Arc<RwLock<std::collections::BTreeMap<u64, V>>>,
    hits: Mutex<u64>,
}

impl<V> Repository for MemRepo<V>
where
    V: Clone + Send + Sync + 'static,
{
    type Error = RepoError;
    type Item = V;

    fn get(&self, id: u64) -> impl Future<Output = Result<Option<V>, RepoError>> + Send {
        let inner = Arc::clone(&self.inner);
        async move {
            let guard = inner.read().map_err(|_| RepoError::Poisoned)?;
            Ok(guard.get(&id).cloned())
        }
    }

    async fn put(&self, id: u64, item: V) -> Result<(), RepoError> {
        let mut guard = self.inner.write().map_err(|_| RepoError::Poisoned)?;
        guard.insert(id, item);
        *self.hits.lock().unwrap() += 1;
        Ok(())
    }
}

/// # Safety
/// `ptr` must be valid for `len` reads.
pub unsafe fn sum_raw(ptr: *const u32, len: usize) -> u64 {
    let mut total = 0u64;
    for i in 0..len {
        // SAFETY: caller guarantees validity
        total += u64::from(unsafe { *ptr.add(i) });
    }
    total
}

#[repr(transparent)]
pub struct Wrapper(u32);

union IntOrFloat {
    i: u32,
    f: f32,
}

extern "C" {
    fn abs(x: i32) -> i32;
    static errno: i32;
}

#[no_mangle]
pub extern "C" fn exported(x: i32) -> i32 { x.wrapping_mul(2) }

pub const fn const_fn(x: u32) -> u32 { x << 1 }
static mut COUNTER: u32 = 0;
static GREETING: &str = r#"static "raw" greeting"#;

pub fn patterns(t: (i32, &str, Option<char>)) -> String {
    match t {
        (0, _, None) => "zero".into(),
        (n @ 1..=9, s, Some(c)) if s.starts_with(c) => format!("{n}{s}{c}"),
        (n, "literal", _) | (n, "other", _) => format!("lit {n}"),
        (i32::MIN..=-1, ..) => String::from("negative"),
        (_, s, Some('\'')) => format!("quote {s:?}"),
        (_, s, Some('"')) => format!(r#"dq "{s}""#),
        _ => unreachable!("all cases {}", "covered"),
    }
}

pub fn slices(v: &[i32]) -> i32 {
    match v {
        [] => 0,
        [x] => *x,
        [first, .., last] => first + last,
    }
}

pub fn closures() -> impl Fn(i32) -> Box<dyn FnMut() -> i32> {
    move |start| {
        let mut n = start;
        Box::new(move || { n += 1; n })
    }
}

pub async fn run<R: Repository<Item = String>>(repo: &R) -> Result<(), R::Error> {
    repo.put(1, "one".to_owned()).await?;
    repo.put(2, String::from("two")).await?;
    if let Some(v) = repo.get(1).await? {
        println!("got {v:?} with len {}", v.len());
    }
    let Some(two) = repo.get(2).await? else {
        return Ok(());
    };
    let label = 'blk: {
        if two.is_empty() { break 'blk "empty"; }
        "full"
    };
    println!("{label}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn mem_repo_roundtrip() {
        let repo = MemRepo::<String>::default();
        run(&repo).await.unwrap();
        assert_eq!(*repo.hits.lock().unwrap(), 2);
    }

    #[test]
    #[should_panic(expected = "polled")]
    fn ready_twice() {}
}

/* Unterminated nested comment:
   /* level two
      /* level three */
      level two again: fn not_code() -> &'static str { "string" }
   */
   level one — one more */ would be needed to close this.
   let x = r#"raw string inside comment"#;
   'a' 'static b"bytes"
