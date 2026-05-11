use chrono::Utc;
use lazy_static::lazy_static;
use serde_json::Value;
use sha2::Digest;
use sha2::Sha256;
use std::collections::HashMap;
use std::collections::HashSet;
use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;
use std::time::Instant;

const CACHE_RELOAD_INTERVAL: Duration = Duration::from_secs(5);

#[derive(Default)]
struct TranslationCache {
    entries: HashMap<String, String>,
    by_kind_sha: HashMap<String, String>,
    by_sha: HashMap<String, String>,
    loaded_at: Option<Instant>,
}

lazy_static! {
    static ref CACHE: Mutex<TranslationCache> = Mutex::new(TranslationCache::default());
    static ref PENDING_SEEN: Mutex<HashSet<String>> = Mutex::new(HashSet::new());
}

pub(crate) fn translate_for_display(kind: &str, source_id: &str, original: &str) -> String {
    let trimmed = original.trim();
    if !should_consider_translation(trimmed) {
        return original.to_string();
    }

    let sha = sha256_hex(trimmed);
    let key = format!("{kind}|{source_id}|{sha}");
    if let Some(translated) = lookup_cached_translation(kind, &key, &sha) {
        return translated;
    }

    record_pending_translation(&key, kind, source_id, &sha, trimmed);
    original.to_string()
}

fn should_consider_translation(text: &str) -> bool {
    if std::env::var("CODEX_KO_TRANSLATE")
        .map(|value| value == "0")
        .unwrap_or(false)
    {
        return false;
    }
    if text.len() < 3 {
        return false;
    }
    if text.chars().any(is_hangul) {
        return false;
    }
    text.chars().any(|ch| ch.is_ascii_alphabetic())
}

fn is_hangul(ch: char) -> bool {
    matches!(ch as u32, 0xAC00..=0xD7A3 | 0x1100..=0x11FF | 0x3130..=0x318F)
}

fn lookup_cached_translation(kind: &str, key: &str, sha: &str) -> Option<String> {
    let mut cache = CACHE.lock().ok()?;
    let should_reload = cache
        .loaded_at
        .map(|loaded_at| loaded_at.elapsed() >= CACHE_RELOAD_INTERVAL)
        .unwrap_or(true);
    if should_reload {
        *cache = load_cache();
    }
    cache
        .entries
        .get(key)
        .or_else(|| cache.by_kind_sha.get(&format!("{kind}|{sha}")))
        .or_else(|| cache.by_sha.get(sha))
        .cloned()
        .filter(|value| !value.trim().is_empty())
}

fn load_cache() -> TranslationCache {
    let mut cache = TranslationCache {
        entries: HashMap::new(),
        by_kind_sha: HashMap::new(),
        by_sha: HashMap::new(),
        loaded_at: Some(Instant::now()),
    };
    if let Some(path) = overrides_path() {
        load_translation_file(&mut cache, path, true);
    }
    if let Some(path) = cache_path() {
        load_translation_file(&mut cache, path, false);
    }
    cache
}

fn load_translation_file(cache: &mut TranslationCache, path: PathBuf, allow_global_sha: bool) {
    let Ok(raw) = fs::read_to_string(path) else {
        return;
    };
    let Ok(value) = serde_json::from_str::<Value>(&raw) else {
        return;
    };

    if let Some(entries) = value.get("entries").and_then(Value::as_object) {
        for (key, entry) in entries {
            load_translation_entry(cache, Some(key), entry, allow_global_sha);
        }
    } else if let Some(entries) = value.get("entries").and_then(Value::as_array) {
        for entry in entries {
            load_translation_entry(cache, None, entry, allow_global_sha);
        }
    }
}

fn load_translation_entry(
    cache: &mut TranslationCache,
    key_from_map: Option<&String>,
    entry: &Value,
    allow_global_sha: bool,
) {
    let Some(ko) = entry
        .get("ko_text")
        .or_else(|| entry.get("ko"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
    else {
        return;
    };

    let kind = entry
        .get("kind")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty());
    let source_id = entry
        .get("source_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty());
    let sha = entry
        .get("sha256")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
        .or_else(|| {
            entry
                .get("original_text")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .map(sha256_hex)
        });

    if let Some(key) = key_from_map
        .map(ToString::to_string)
        .or_else(|| match (kind, source_id, sha.as_deref()) {
            (Some(kind), Some(source_id), Some(sha)) if kind != "*" => {
                Some(format!("{kind}|{source_id}|{sha}"))
            }
            _ => None,
        })
    {
        cache
            .entries
            .entry(key)
            .or_insert_with(|| ko.to_string());
    }

    if let (Some(kind), Some(sha)) = (kind, sha.as_deref()) {
        if kind != "*" {
            cache
                .by_kind_sha
                .entry(format!("{kind}|{sha}"))
                .or_insert_with(|| ko.to_string());
        }
        if allow_global_sha {
            cache
                .by_sha
                .entry(sha.to_string())
                .or_insert_with(|| ko.to_string());
        }
    }
}

fn record_pending_translation(key: &str, kind: &str, source_id: &str, sha: &str, original: &str) {
    let Ok(mut seen) = PENDING_SEEN.lock() else {
        return;
    };
    if !seen.insert(key.to_string()) {
        return;
    }
    drop(seen);

    let Some(path) = pending_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let record = serde_json::json!({
        "key": key,
        "kind": kind,
        "source_id": source_id,
        "sha256": sha,
        "original_text": original,
        "first_seen_at": Utc::now().to_rfc3339(),
    });
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{record}");
    }
}

fn cache_path() -> Option<PathBuf> {
    Some(root_path()?.join("translations").join("dynamic-cache.json"))
}

fn overrides_path() -> Option<PathBuf> {
    Some(root_path()?.join("translations").join("ko-overrides.json"))
}

fn pending_path() -> Option<PathBuf> {
    Some(
        root_path()?
            .join("translations")
            .join("pending")
            .join("dynamic-pending.jsonl"),
    )
}

fn root_path() -> Option<PathBuf> {
    if let Ok(root) = std::env::var("CODEX_KO_ROOT") {
        if !root.trim().is_empty() {
            return Some(PathBuf::from(root));
        }
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        if !profile.trim().is_empty() {
            return Some(PathBuf::from(profile).join(".codex-ko"));
        }
    }
    std::env::var("HOME")
        .ok()
        .filter(|home| !home.trim().is_empty())
        .map(|home| PathBuf::from(home).join(".codex-ko"))
}

fn sha256_hex(text: &str) -> String {
    let digest = Sha256::digest(text.as_bytes());
    format!("{digest:x}")
}
