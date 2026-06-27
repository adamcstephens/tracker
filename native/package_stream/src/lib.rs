use rustler::{Atom, Binary, Encoder, Env, LocalPid, OwnedEnv, Term};
use serde::de::{self, DeserializeSeed, Deserializer, IgnoredAny, MapAccess, Visitor};
use serde::Deserialize;
use std::fmt;
use std::io::Read;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        packages,
        done,

        // Map keys for package fields
        version,
        description,
        homepage,
        position,
        licenses,
        maintainers,
        teams,

        // Map keys for maintainer fields
        github_id,
        github,

        // Map keys for team fields
        short_name,
        scope,
        members,
    }
}

// ---------------------------------------------------------------------------
// Serde types for deserialization
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize, Debug, PartialEq)]
struct PackageEntry {
    version: Option<String>,
    #[serde(default)]
    meta: Option<PackageMeta>,
}

#[derive(serde::Deserialize, Debug, PartialEq)]
struct PackageMeta {
    description: Option<String>,
    #[serde(default, deserialize_with = "deserialize_homepage")]
    homepage: Option<Vec<String>>,
    position: Option<String>,
    #[serde(default, deserialize_with = "deserialize_licenses")]
    license: Option<Vec<String>>,
    #[serde(default, rename = "nonTeamMaintainers")]
    non_team_maintainers: Option<Vec<MaintainerInfo>>,
    #[serde(default)]
    teams: Option<Vec<TeamInfo>>,
}

#[derive(serde::Deserialize, Debug, PartialEq, Clone)]
struct MaintainerInfo {
    #[serde(rename = "githubId")]
    github_id: Option<u64>,
    github: Option<String>,
}

#[derive(serde::Deserialize, Debug, PartialEq, Clone)]
struct TeamInfo {
    #[serde(default, rename = "shortName")]
    short_name: Option<String>,
    scope: Option<String>,
    github: Option<String>,
    #[serde(rename = "githubId")]
    github_id: Option<u64>,
    #[serde(default)]
    members: Option<Vec<MaintainerInfo>>,
}

// ---------------------------------------------------------------------------
// Custom deserializers for homepage and license normalization
// ---------------------------------------------------------------------------

fn deserialize_homepage<'de, D>(deserializer: D) -> Result<Option<Vec<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(serde::Deserialize)]
    #[serde(untagged)]
    enum HomepageRaw {
        Single(String),
        Multiple(Vec<String>),
    }

    Option::<HomepageRaw>::deserialize(deserializer).map(|opt| {
        opt.map(|raw| match raw {
            HomepageRaw::Single(s) => vec![s],
            HomepageRaw::Multiple(v) => v,
        })
    })
}

fn deserialize_licenses<'de, D>(deserializer: D) -> Result<Option<Vec<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(serde::Deserialize)]
    #[serde(untagged)]
    enum LicenseRaw {
        Str(String),
        Obj(LicenseObject),
        List(Vec<LicenseEntry>),
    }

    #[derive(serde::Deserialize)]
    #[serde(untagged)]
    enum LicenseEntry {
        Str(String),
        Obj(LicenseObject),
    }

    #[derive(serde::Deserialize)]
    struct LicenseObject {
        #[serde(rename = "spdxId")]
        spdx_id: Option<String>,
        #[serde(rename = "shortName")]
        short_name: Option<String>,
        #[serde(rename = "fullName")]
        full_name: Option<String>,
    }

    fn extract_license_name(obj: &LicenseObject) -> String {
        obj.spdx_id
            .as_deref()
            .or(obj.short_name.as_deref())
            .or(obj.full_name.as_deref())
            .unwrap_or("unknown")
            .to_string()
    }

    fn entry_to_string(entry: LicenseEntry) -> String {
        match entry {
            LicenseEntry::Str(s) => s,
            LicenseEntry::Obj(obj) => extract_license_name(&obj),
        }
    }

    Option::<LicenseRaw>::deserialize(deserializer).map(|opt| {
        opt.map(|raw| match raw {
            LicenseRaw::Str(s) => vec![s],
            LicenseRaw::Obj(obj) => vec![extract_license_name(&obj)],
            LicenseRaw::List(entries) => entries.into_iter().map(entry_to_string).collect(),
        })
    })
}

// ---------------------------------------------------------------------------
// BEAM term encoding
// ---------------------------------------------------------------------------

fn encode_package_tuple<'a>(env: Env<'a>, attr: &str, entry: &PackageEntry) -> Term<'a> {
    let fields = encode_package_fields(env, entry);
    (attr, fields).encode(env)
}

fn encode_package_fields<'a>(env: Env<'a>, entry: &PackageEntry) -> Term<'a> {
    let version_term = entry.version.as_deref().unwrap_or("").encode(env);

    let mut keys = vec![atoms::version().encode(env)];
    let mut vals = vec![version_term];

    if let Some(ref meta) = entry.meta {
        if let Some(ref desc) = meta.description {
            keys.push(atoms::description().encode(env));
            vals.push(desc.as_str().encode(env));
        }
        if let Some(ref hp) = meta.homepage {
            keys.push(atoms::homepage().encode(env));
            vals.push(encode_string_list(env, hp));
        }
        if let Some(ref pos) = meta.position {
            keys.push(atoms::position().encode(env));
            vals.push(pos.as_str().encode(env));
        }
        if let Some(ref lics) = meta.license {
            keys.push(atoms::licenses().encode(env));
            vals.push(encode_string_list(env, lics));
        }
        if let Some(ref maints) = meta.non_team_maintainers {
            keys.push(atoms::maintainers().encode(env));
            vals.push(encode_maintainers(env, maints));
        }
        if let Some(ref tms) = meta.teams {
            keys.push(atoms::teams().encode(env));
            vals.push(encode_teams(env, tms));
        }
    }

    Term::map_from_arrays(env, &keys, &vals).expect("failed to build map")
}

fn encode_string_list<'a>(env: Env<'a>, items: &[String]) -> Term<'a> {
    let terms: Vec<Term<'a>> = items.iter().map(|s| s.as_str().encode(env)).collect();
    terms.encode(env)
}

fn encode_maintainers<'a>(env: Env<'a>, maints: &[MaintainerInfo]) -> Term<'a> {
    let terms: Vec<Term<'a>> = maints.iter().map(|m| encode_maintainer(env, m)).collect();
    terms.encode(env)
}

fn encode_maintainer<'a>(env: Env<'a>, m: &MaintainerInfo) -> Term<'a> {
    let mut keys = Vec::new();
    let mut vals = Vec::new();

    if let Some(id) = m.github_id {
        keys.push(atoms::github_id().encode(env));
        vals.push(id.encode(env));
    }
    if let Some(ref gh) = m.github {
        keys.push(atoms::github().encode(env));
        vals.push(gh.as_str().encode(env));
    }

    Term::map_from_arrays(env, &keys, &vals).expect("failed to build maintainer map")
}

fn encode_teams<'a>(env: Env<'a>, teams: &[TeamInfo]) -> Term<'a> {
    // nixpkgs occasionally lists a maintainer-shaped object (no `shortName`) in
    // a package's `teams`; drop those rather than fail the whole stream.
    let terms: Vec<Term<'a>> = teams
        .iter()
        .filter_map(|t| {
            t.short_name
                .as_deref()
                .map(|name| encode_team(env, t, name))
        })
        .collect();
    terms.encode(env)
}

fn encode_team<'a>(env: Env<'a>, t: &TeamInfo, short_name: &str) -> Term<'a> {
    let mut keys = vec![atoms::short_name().encode(env)];
    let mut vals = vec![short_name.encode(env)];

    if let Some(ref s) = t.scope {
        keys.push(atoms::scope().encode(env));
        vals.push(s.as_str().encode(env));
    }
    if let Some(ref gh) = t.github {
        keys.push(atoms::github().encode(env));
        vals.push(gh.as_str().encode(env));
    }
    if let Some(id) = t.github_id {
        keys.push(atoms::github_id().encode(env));
        vals.push(id.encode(env));
    }
    if let Some(ref ms) = t.members {
        keys.push(atoms::members().encode(env));
        vals.push(encode_maintainers(env, ms));
    }

    Term::map_from_arrays(env, &keys, &vals).expect("failed to build team map")
}

// ---------------------------------------------------------------------------
// Streaming JSON visitor
// ---------------------------------------------------------------------------

const SEND_BATCH_SIZE: usize = 500;

/// Seed for deserializing the "packages" object, sending batched entries via enif_send.
struct PackagesStreamSeed<'a, 'env> {
    caller_env: Env<'env>,
    pid: &'a LocalPid,
}

impl<'de, 'a, 'env> DeserializeSeed<'de> for PackagesStreamSeed<'a, 'env> {
    type Value = ();

    fn deserialize<D>(self, deserializer: D) -> Result<(), D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_map(PackagesVisitor {
            caller_env: self.caller_env,
            pid: self.pid,
        })
    }
}

struct PackagesVisitor<'a, 'env> {
    caller_env: Env<'env>,
    pid: &'a LocalPid,
}

impl<'de, 'a, 'env> Visitor<'de> for PackagesVisitor<'a, 'env> {
    type Value = ();

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "a map of package attribute to package entry")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        let mut batch: Vec<(String, PackageEntry)> = Vec::with_capacity(SEND_BATCH_SIZE);

        while let Some(attr) = map.next_key::<String>()? {
            let entry: PackageEntry = map.next_value()?;

            // Skip packages with null or empty version
            let has_version = entry.version.as_ref().is_some_and(|v| !v.is_empty());

            if has_version {
                batch.push((attr, entry));

                if batch.len() >= SEND_BATCH_SIZE {
                    send_batch(self.caller_env, self.pid, &batch)
                        .map_err(|_| de::Error::custom("caller process is dead"))?;
                    batch.clear();
                }
            }
        }

        // Flush remaining entries
        if !batch.is_empty() {
            send_batch(self.caller_env, self.pid, &batch)
                .map_err(|_| de::Error::custom("caller process is dead"))?;
        }

        Ok(())
    }
}

/// Send a message built in a fresh process-independent env to `pid`, from
/// inside a NIF running on a (dirty) scheduler thread.
///
/// `OwnedEnv::send_and_clear` can't be used here: it asserts the current
/// thread is *unmanaged* and panics on a scheduler thread. The supported path
/// is `enif_send` with the live callback env as the caller env and the owned
/// env as the message env. The message is copied into `pid`'s mailbox, then
/// the owned env (and its per-batch terms) is freed on drop — so memory stays
/// bounded to one batch instead of accumulating in the callback env.
fn send_from_nif<F>(
    caller_env: Env,
    pid: &LocalPid,
    build: F,
) -> Result<(), rustler::env::SendError>
where
    F: for<'a> FnOnce(Env<'a>) -> Term<'a>,
{
    let msg_env = OwnedEnv::new();

    // NIF_ENV and NIF_TERM are plain copyable handles that don't borrow `env`.
    let (raw_env, raw_msg) = msg_env.run(|env| (env.as_c_arg(), build(env).as_c_arg()));

    // SAFETY:
    // - `caller_env` is the live NIF callback env: `stream_packages` runs
    //   synchronously on the scheduler thread that entered it, so it is valid.
    // - `raw_env`/`raw_msg` belong to `msg_env`, which is alive for the whole
    //   call and freed exactly once on drop after this send.
    // - enif_send copies `raw_msg` into `pid`'s mailbox; it neither frees
    //   `msg_env` nor retains a reference past the call.
    let res =
        unsafe { rustler::sys::enif_send(caller_env.as_c_arg(), pid.as_c_arg(), raw_env, raw_msg) };

    if res == 1 {
        Ok(())
    } else {
        Err(rustler::env::SendError)
    }
}

fn send_batch(
    caller_env: Env,
    pid: &LocalPid,
    batch: &[(String, PackageEntry)],
) -> Result<(), rustler::env::SendError> {
    send_from_nif(caller_env, pid, |env| {
        let entries: Vec<Term> = batch
            .iter()
            .map(|(attr, entry)| encode_package_tuple(env, attr, entry))
            .collect();
        (atoms::packages(), entries).encode(env)
    })
}

/// Visitor for the top-level JSON object {"version": N, "packages": {...}}.
struct TopLevelVisitor<'a, 'env> {
    caller_env: Env<'env>,
    pid: &'a LocalPid,
}

impl<'de, 'a, 'env> Visitor<'de> for TopLevelVisitor<'a, 'env> {
    type Value = u64;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "a map with 'version' and 'packages' keys")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<u64, A::Error> {
        let mut version: Option<u64> = None;
        let mut packages_seen = false;

        while let Some(key) = map.next_key::<String>()? {
            match key.as_str() {
                "version" => {
                    let v = map.next_value::<serde_json::Value>()?;
                    version = match &v {
                        serde_json::Value::Number(n) => n.as_u64(),
                        serde_json::Value::String(s) => s.parse::<u64>().ok(),
                        _ => None,
                    };
                }
                "packages" => {
                    // Validate version before processing packages if we've seen it
                    if let Some(v) = version {
                        if v != 2 {
                            return Err(de::Error::custom(format!(
                                "unsupported version: {v}, expected 2"
                            )));
                        }
                    }
                    map.next_value_seed(PackagesStreamSeed {
                        caller_env: self.caller_env,
                        pid: self.pid,
                    })?;
                    packages_seen = true;
                }
                _ => {
                    let _ = map.next_value::<IgnoredAny>()?;
                }
            }
        }

        let ver = version.ok_or_else(|| de::Error::missing_field("version"))?;
        if ver != 2 {
            return Err(de::Error::custom(format!(
                "unsupported version: {ver}, expected 2"
            )));
        }
        if !packages_seen {
            return Err(de::Error::missing_field("packages"));
        }

        Ok(ver)
    }
}

fn stream_from_reader<R: Read>(reader: R, env: Env, pid: &LocalPid) -> Result<u64, String> {
    // Decompress fully into a Rust-owned buffer, then parse from memory.
    // serde_json::from_reader reads byte-by-byte which is slow through
    // the brotli streaming decoder. Decompressing first into a Vec<u8>
    // lets serde_json::from_slice use SIMD-optimized parsing.
    // The buffer lives on the Rust heap (not BEAM) and is freed when
    // this function returns.
    let mut decompressed = Vec::new();
    let mut reader = reader;
    reader
        .read_to_end(&mut decompressed)
        .map_err(|e| e.to_string())?;

    let mut deser = serde_json::Deserializer::from_slice(&decompressed);
    deser
        .deserialize_map(TopLevelVisitor {
            caller_env: env,
            pid,
        })
        .map_err(|e| e.to_string())
}

fn send_done(caller_env: Env, pid: &LocalPid, version: u64) {
    let _ = send_from_nif(caller_env, pid, |env| {
        let version_key = atoms::version().encode(env);
        let version_val = version.encode(env);
        let meta = Term::map_from_arrays(env, &[version_key], &[version_val])
            .expect("failed to build done map");
        (atoms::done(), meta).encode(env)
    });
}

fn send_error(caller_env: Env, pid: &LocalPid, reason: &str) {
    let _ = send_from_nif(caller_env, pid, |env| {
        (atoms::error(), reason.encode(env)).encode(env)
    });
}

// ---------------------------------------------------------------------------
// NIF entry point
// ---------------------------------------------------------------------------

// Runs on a dirty CPU scheduler (decompress + parse is CPU-bound). The
// scheduler thread is owned, tracked, and drained by the runtime, so there
// is no detached thread to outlive a module unload or VM shutdown. The work
// is synchronous: the `data` binary stays borrowed for the whole call, so we
// read straight from `data.as_slice()` with no owning copy. The caller is
// expected to run this in its own process (e.g. a Task) so batched sends to
// `caller` are drained concurrently rather than piling in its own mailbox.
#[rustler::nif(schedule = "DirtyCpu")]
fn stream_packages(env: Env, data: Binary, caller: LocalPid) -> Atom {
    let reader = brotli::Decompressor::new(data.as_slice(), 4096);

    match stream_from_reader(reader, env, &caller) {
        Ok(version) => send_done(env, &caller, version),
        Err(reason) => send_error(env, &caller, &reason),
    }

    atoms::ok()
}

rustler::init!("Elixir.Tracker.Ingestion.PackageStream");

// ---------------------------------------------------------------------------
// Rust unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // Test serde deserialization of PackageEntry with all fields
    #[test]
    fn test_package_entry_full_meta() {
        let json = r#"{
            "version": "2.12.1",
            "meta": {
                "description": "A greeting program",
                "homepage": "https://example.com",
                "position": "pkgs/hello/default.nix",
                "license": [{"spdxId": "MIT"}],
                "nonTeamMaintainers": [{"githubId": 123, "github": "alice"}],
                "teams": [{
                    "shortName": "nixos-team",
                    "scope": "NixOS",
                    "github": "NixOS",
                    "githubId": 999,
                    "members": [{"githubId": 456, "github": "bob"}]
                }]
            }
        }"#;

        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.version, Some("2.12.1".to_string()));

        let meta = entry.meta.unwrap();
        assert_eq!(meta.description, Some("A greeting program".to_string()));
        assert_eq!(meta.homepage, Some(vec!["https://example.com".to_string()]));
        assert_eq!(meta.position, Some("pkgs/hello/default.nix".to_string()));
        assert_eq!(meta.license, Some(vec!["MIT".to_string()]));

        let maints = meta.non_team_maintainers.unwrap();
        assert_eq!(maints.len(), 1);
        assert_eq!(maints[0].github_id, Some(123));
        assert_eq!(maints[0].github, Some("alice".to_string()));

        let teams = meta.teams.unwrap();
        assert_eq!(teams.len(), 1);
        assert_eq!(teams[0].short_name, Some("nixos-team".to_string()));
        assert_eq!(teams[0].members.as_ref().unwrap().len(), 1);
    }

    // A maintainer-shaped object (no shortName) in `teams` must parse without
    // error so a single malformed entry can't fail the whole package stream.
    #[test]
    fn test_team_without_short_name_parses() {
        let json = r#"{"version": "1.0", "meta": {"teams": [
            {"email": "me@example.com", "github": "alice", "githubId": 1, "name": "Alice"}
        ]}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        let teams = entry.meta.unwrap().teams.unwrap();
        assert_eq!(teams.len(), 1);
        assert_eq!(teams[0].short_name, None);
    }

    // Test homepage normalization: bare string -> vec
    #[test]
    fn test_homepage_string_normalized_to_list() {
        let json = r#"{"version": "1.0", "meta": {"homepage": "https://example.com"}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(
            entry.meta.unwrap().homepage,
            Some(vec!["https://example.com".to_string()])
        );
    }

    // Test homepage normalization: list passes through
    #[test]
    fn test_homepage_list_passes_through() {
        let json =
            r#"{"version": "1.0", "meta": {"homepage": ["https://a.com", "https://b.com"]}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(
            entry.meta.unwrap().homepage,
            Some(vec![
                "https://a.com".to_string(),
                "https://b.com".to_string()
            ])
        );
    }

    // Test homepage normalization: null -> None
    #[test]
    fn test_homepage_null() {
        let json = r#"{"version": "1.0", "meta": {"homepage": null}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.meta.unwrap().homepage, None);
    }

    // Test license normalization: bare string -> vec
    #[test]
    fn test_license_string_normalized() {
        let json = r#"{"version": "1.0", "meta": {"license": "MIT"}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.meta.unwrap().license, Some(vec!["MIT".to_string()]));
    }

    // Test license normalization: single object -> vec using spdxId
    #[test]
    fn test_license_single_object_spdx() {
        let json = r#"{"version": "1.0", "meta": {"license": {"spdxId": "Apache-2.0"}}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(
            entry.meta.unwrap().license,
            Some(vec!["Apache-2.0".to_string()])
        );
    }

    // Test license fallback: shortName when no spdxId
    #[test]
    fn test_license_fallback_short_name() {
        let json = r#"{"version": "1.0", "meta": {"license": {"shortName": "custom"}}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(
            entry.meta.unwrap().license,
            Some(vec!["custom".to_string()])
        );
    }

    // Test license fallback: fullName when no spdxId or shortName
    #[test]
    fn test_license_fallback_full_name() {
        let json = r#"{"version": "1.0", "meta": {"license": {"fullName": "My License"}}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(
            entry.meta.unwrap().license,
            Some(vec!["My License".to_string()])
        );
    }

    // Test license fallback: "unknown" when no recognized fields
    #[test]
    fn test_license_fallback_unknown() {
        let json = r#"{"version": "1.0", "meta": {"license": {"free": true}}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(
            entry.meta.unwrap().license,
            Some(vec!["unknown".to_string()])
        );
    }

    // Test license list with mixed entries
    #[test]
    fn test_license_mixed_list() {
        let json = r#"{
            "version": "1.0",
            "meta": {
                "license": [
                    {"spdxId": "MIT"},
                    {"shortName": "custom"},
                    "BSD-3-Clause"
                ]
            }
        }"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(
            entry.meta.unwrap().license,
            Some(vec![
                "MIT".to_string(),
                "custom".to_string(),
                "BSD-3-Clause".to_string()
            ])
        );
    }

    // Test package entry with no meta
    #[test]
    fn test_package_entry_no_meta() {
        let json = r#"{"version": "3.0"}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.version, Some("3.0".to_string()));
        assert!(entry.meta.is_none());
    }

    // Test package entry with null version
    #[test]
    fn test_package_entry_null_version() {
        let json = r#"{"version": null}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert!(entry.version.is_none());
    }

    // Test package entry with empty version
    #[test]
    fn test_package_entry_empty_version() {
        let json = r#"{"version": ""}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.version, Some("".to_string()));
    }

    // Test that PackageMeta with unknown fields doesn't fail
    #[test]
    fn test_package_meta_ignores_unknown_fields() {
        let json = r#"{"version": "1.0", "meta": {"unknown_field": 42, "description": "test"}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.meta.unwrap().description, Some("test".to_string()));
    }
}
