use rustler::{Atom, Binary, Encoder, Env, LocalPid, OwnedEnv, Term};
use serde::de::{self, DeserializeSeed, Deserializer, IgnoredAny, MapAccess, Visitor};
use serde::Deserialize;
use serde_json::Value;
use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::fmt;
use std::io::Read;
use std::sync::OnceLock;

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
        pname,
        outputs,
        default_output,
        long_description,
        main_program,
        broken,
        unfree,
        insecure,
        unsupported,
        known_vulnerabilities,
        platforms,
        bad_platforms,
        changelog,
        download_page,
        source_provenance,

        // Extra key in the :done meta map
        unknown_platform_patterns,

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
    pname: Option<String>,
    #[serde(default, deserialize_with = "deserialize_outputs")]
    outputs: Option<Vec<String>>,
    #[serde(rename = "outputName")]
    default_output: Option<String>,
    #[serde(default)]
    meta: Option<PackageMeta>,
}

#[derive(serde::Deserialize, Debug, PartialEq)]
struct PackageMeta {
    description: Option<String>,
    #[serde(rename = "longDescription")]
    long_description: Option<String>,
    #[serde(default, deserialize_with = "deserialize_homepage")]
    homepage: Option<Vec<String>>,
    position: Option<String>,
    #[serde(default, deserialize_with = "deserialize_licenses")]
    license: Option<Vec<String>>,
    #[serde(rename = "mainProgram")]
    main_program: Option<String>,
    broken: Option<bool>,
    unfree: Option<bool>,
    insecure: Option<bool>,
    unsupported: Option<bool>,
    #[serde(rename = "knownVulnerabilities")]
    known_vulnerabilities: Option<Vec<String>>,
    #[serde(rename = "platforms")]
    platforms_raw: Option<Vec<Value>>,
    #[serde(skip)]
    platforms: Option<Vec<String>>,
    #[serde(rename = "badPlatforms")]
    bad_platforms_raw: Option<Vec<Value>>,
    #[serde(skip)]
    bad_platforms: Option<Vec<String>>,
    #[serde(default, deserialize_with = "deserialize_changelog")]
    changelog: Option<Vec<String>>,
    #[serde(rename = "downloadPage")]
    download_page: Option<String>,
    #[serde(
        default,
        rename = "sourceProvenance",
        deserialize_with = "deserialize_source_provenance"
    )]
    source_provenance: Option<Vec<String>>,
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

fn deserialize_changelog<'de, D>(deserializer: D) -> Result<Option<Vec<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(serde::Deserialize)]
    #[serde(untagged)]
    enum ChangelogRaw {
        Single(String),
        Multiple(Vec<String>),
    }

    Option::<ChangelogRaw>::deserialize(deserializer).map(|opt| {
        opt.map(|raw| match raw {
            ChangelogRaw::Single(s) => vec![s],
            ChangelogRaw::Multiple(v) => v,
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

/// `outputs` is an object whose keys are the output names and whose values are
/// null store paths; extract the keys in order. The object itself may be null.
fn deserialize_outputs<'de, D>(deserializer: D) -> Result<Option<Vec<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    struct OptionalOutputsVisitor;

    impl<'de> Visitor<'de> for OptionalOutputsVisitor {
        type Value = Option<Vec<String>>;

        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            write!(f, "null or an object keyed by output name")
        }

        fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
            Ok(None)
        }

        fn visit_none<E: de::Error>(self) -> Result<Self::Value, E> {
            Ok(None)
        }

        fn visit_some<D2: Deserializer<'de>>(self, d: D2) -> Result<Self::Value, D2::Error> {
            struct KeysVisitor;

            impl<'de> Visitor<'de> for KeysVisitor {
                type Value = Vec<String>;

                fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                    write!(f, "an object keyed by output name")
                }

                fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
                    Ok(Vec::new())
                }

                fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                    let mut keys = Vec::new();
                    while let Some(key) = map.next_key::<String>()? {
                        let _ = map.next_value::<IgnoredAny>()?;
                        keys.push(key);
                    }
                    Ok(keys)
                }
            }

            d.deserialize_map(KeysVisitor).map(Some)
        }
    }

    deserializer.deserialize_option(OptionalOutputsVisitor)
}

/// `sourceProvenance` is a list of attrsets; extract each `shortName`
/// (e.g. `binaryNativeCode`).
fn deserialize_source_provenance<'de, D>(deserializer: D) -> Result<Option<Vec<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(serde::Deserialize)]
    struct ProvenanceEntry {
        #[serde(rename = "shortName")]
        short_name: Option<String>,
    }

    Option::<Vec<ProvenanceEntry>>::deserialize(deserializer)
        .map(|opt| opt.map(|entries| entries.into_iter().filter_map(|e| e.short_name).collect()))
}

// ---------------------------------------------------------------------------
// Platform pattern normalization
// ---------------------------------------------------------------------------

/// `lib.systems.inspect.patterns`, dumped via
/// `nix eval --json nixpkgs#lib.systems.inspect.patterns`.
static PLATFORM_PATTERNS_JSON: &str = include_str!("platform_patterns.json");

struct NamedPattern {
    name: String,
    cpu_ish: bool,
    members: Vec<Value>,
}

struct Member {
    value: Value,
    name: String,
    /// Orders conjunction operands into system-tuple order (`64bit-bsd`,
    /// `mips-linux`, `power64-littleendian`).
    rank: u8,
}

struct PatternTable {
    /// Canonical (key-sorted) JSON of each pattern member -> display name.
    exact: HashMap<String, String>,
    /// Every distinct member, named as the exact table names it so a member
    /// shared by two patterns reads the same alone and in a conjunction.
    members: Vec<Member>,
}

fn pattern_table() -> &'static PatternTable {
    static TABLE: OnceLock<PatternTable> = OnceLock::new();
    TABLE.get_or_init(build_pattern_table)
}

fn build_pattern_table() -> PatternTable {
    let raw: serde_json::Map<String, Value> =
        serde_json::from_str(PLATFORM_PATTERNS_JSON).expect("invalid platform_patterns.json");

    let mut named: Vec<NamedPattern> = raw
        .into_iter()
        .map(|(key, value)| {
            let name = key.strip_prefix("is").unwrap_or(&key).to_lowercase();
            let members = match normalize_pattern(value) {
                Value::Array(members) => members,
                single => vec![single],
            };
            let cpu_ish = members.iter().any(|m| m.get("cpu").is_some());
            NamedPattern {
                name,
                cpu_ish,
                members,
            }
        })
        .collect();

    // `lib.systems.inspect.platformPatterns.isStatic` is not part of
    // `patterns`; it serializes with an empty `parsed` attrset, which
    // `strip_empty_parsed` removes before matching.
    named.push(NamedPattern {
        name: "static".to_string(),
        cpu_ish: false,
        members: vec![serde_json::json!({"isStatic": true})],
    });

    named.sort_by(|a, b| (!a.cpu_ish, &a.name).cmp(&(!b.cpu_ish, &b.name)));

    let mut exact = HashMap::new();

    // Single-pattern names first so they win over group members: the linux
    // pattern is both isLinux and a member of isUnix, and must map to "linux".
    for pattern in named.iter().filter(|p| p.members.len() == 1) {
        exact
            .entry(pattern.members[0].to_string())
            .or_insert_with(|| pattern.name.clone());
    }

    for pattern in named.iter().filter(|p| p.members.len() > 1) {
        for member in &pattern.members {
            exact
                .entry(member.to_string())
                .or_insert_with(|| pattern.name.clone());
        }
    }

    let mut members: Vec<Member> = named
        .iter()
        .flat_map(|pattern| &pattern.members)
        .map(|value| Member {
            name: exact
                .get(&value.to_string())
                .cloned()
                .expect("member named"),
            rank: operand_rank(value),
            value: value.clone(),
        })
        .collect();

    members.sort_by(|a, b| (a.rank, &a.name).cmp(&(b.rank, &b.name)));
    members.dedup_by(|a, b| a.value == b.value);

    PatternTable { exact, members }
}

/// Concrete cpu families lead a conjunction, then cpu modifiers (bit width,
/// endianness), then everything kernel- or abi-shaped.
fn operand_rank(member: &Value) -> u8 {
    match member.get("cpu") {
        Some(cpu) if cpu.get("family").is_some() => 0,
        Some(_) => 1,
        None => 2,
    }
}

fn normalize_platform_fields(entry: &mut PackageEntry, unknowns: &mut BTreeSet<String>) {
    if let Some(meta) = entry.meta.as_mut() {
        meta.platforms = meta
            .platforms_raw
            .take()
            .map(|list| normalize_platform_list(list, unknowns));
        meta.bad_platforms = meta
            .bad_platforms_raw
            .take()
            .map(|list| normalize_platform_list(list, unknowns));
    }
}

fn normalize_platform_list(list: Vec<Value>, unknowns: &mut BTreeSet<String>) -> Vec<String> {
    list.into_iter()
        .map(|value| normalize_platform_entry(value, unknowns))
        .collect()
}

fn normalize_platform_entry(value: Value, unknowns: &mut BTreeSet<String>) -> String {
    match value {
        Value::String(system) => system,
        pattern => {
            match_platform_pattern(&normalize_pattern(pattern.clone())).unwrap_or_else(|| {
                unknowns.insert(pattern.to_string());
                "unknown-platform".to_string()
            })
        }
    }
}

/// Reduce a pattern to what the table matches on: packages.json tags nixpkgs'
/// typed attrsets with a `_type` discriminator the dumped patterns lack, and
/// the observed isStatic pattern carries an empty `parsed` attrset that says
/// nothing.
fn normalize_pattern(pattern: Value) -> Value {
    match pattern {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .filter(|(key, value)| {
                    key != "_type"
                        && !(key == "parsed" && value.as_object().is_some_and(|o| o.is_empty()))
                })
                .map(|(key, value)| (key, normalize_pattern(value)))
                .collect(),
        ),
        Value::Array(members) => Value::Array(members.into_iter().map(normalize_pattern).collect()),
        other => other,
    }
}

fn match_platform_pattern(pattern: &Value) -> Option<String> {
    let table = pattern_table();

    if let Some(name) = table.exact.get(&pattern.to_string()) {
        return Some(name.clone());
    }

    conjunction_match(table, pattern)
}

/// Match `patternLogicalAnd` conjunctions of two named patterns by trying
/// pairwise deep-merges of their members. Both merge directions are tried, so
/// operand rank — not iteration order — decides which name leads.
fn conjunction_match(table: &PatternTable, target: &Value) -> Option<String> {
    for first in &table.members {
        for second in &table.members {
            if first.name == second.name {
                continue;
            }

            if deep_merge(&first.value, &second.value) == *target {
                let (lead, tail) = if (first.rank, &first.name) <= (second.rank, &second.name) {
                    (first, second)
                } else {
                    (second, first)
                };

                return Some(format!("{}-{}", lead.name, tail.name));
            }
        }
    }

    None
}

/// `lib.recursiveUpdate` semantics: objects merge recursively, the right side
/// wins elsewhere — how `patternLogicalAnd` combines two patterns.
fn deep_merge(a: &Value, b: &Value) -> Value {
    match (a, b) {
        (Value::Object(left), Value::Object(right)) => {
            let mut merged = left.clone();
            for (key, value) in right {
                let value = match merged.get(key) {
                    Some(existing) => deep_merge(existing, value),
                    None => value.clone(),
                };
                merged.insert(key.clone(), value);
            }
            Value::Object(merged)
        }
        (_, other) => other.clone(),
    }
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

    if let Some(ref pname) = entry.pname {
        keys.push(atoms::pname().encode(env));
        vals.push(pname.as_str().encode(env));
    }
    if let Some(ref outputs) = entry.outputs {
        keys.push(atoms::outputs().encode(env));
        vals.push(encode_string_list(env, outputs));
    }
    if let Some(ref default_output) = entry.default_output {
        keys.push(atoms::default_output().encode(env));
        vals.push(default_output.as_str().encode(env));
    }

    if let Some(ref meta) = entry.meta {
        if let Some(ref desc) = meta.description {
            keys.push(atoms::description().encode(env));
            vals.push(desc.as_str().encode(env));
        }
        if let Some(ref long_desc) = meta.long_description {
            keys.push(atoms::long_description().encode(env));
            vals.push(long_desc.as_str().encode(env));
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
        if let Some(ref main_program) = meta.main_program {
            keys.push(atoms::main_program().encode(env));
            vals.push(main_program.as_str().encode(env));
        }
        if let Some(broken) = meta.broken {
            keys.push(atoms::broken().encode(env));
            vals.push(broken.encode(env));
        }
        if let Some(unfree) = meta.unfree {
            keys.push(atoms::unfree().encode(env));
            vals.push(unfree.encode(env));
        }
        if let Some(insecure) = meta.insecure {
            keys.push(atoms::insecure().encode(env));
            vals.push(insecure.encode(env));
        }
        if let Some(unsupported) = meta.unsupported {
            keys.push(atoms::unsupported().encode(env));
            vals.push(unsupported.encode(env));
        }
        if let Some(ref vulns) = meta.known_vulnerabilities {
            keys.push(atoms::known_vulnerabilities().encode(env));
            vals.push(encode_string_list(env, vulns));
        }
        if let Some(ref platforms) = meta.platforms {
            keys.push(atoms::platforms().encode(env));
            vals.push(encode_string_list(env, platforms));
        }
        if let Some(ref bad_platforms) = meta.bad_platforms {
            keys.push(atoms::bad_platforms().encode(env));
            vals.push(encode_string_list(env, bad_platforms));
        }
        if let Some(ref changelog) = meta.changelog {
            keys.push(atoms::changelog().encode(env));
            vals.push(encode_string_list(env, changelog));
        }
        if let Some(ref download_page) = meta.download_page {
            keys.push(atoms::download_page().encode(env));
            vals.push(download_page.as_str().encode(env));
        }
        if let Some(ref provenance) = meta.source_provenance {
            keys.push(atoms::source_provenance().encode(env));
            vals.push(encode_string_list(env, provenance));
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
    unknown_patterns: &'a RefCell<BTreeSet<String>>,
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
            unknown_patterns: self.unknown_patterns,
        })
    }
}

struct PackagesVisitor<'a, 'env> {
    caller_env: Env<'env>,
    pid: &'a LocalPid,
    unknown_patterns: &'a RefCell<BTreeSet<String>>,
}

impl<'de, 'a, 'env> Visitor<'de> for PackagesVisitor<'a, 'env> {
    type Value = ();

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "a map of package attribute to package entry")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        let mut batch: Vec<(String, PackageEntry)> = Vec::with_capacity(SEND_BATCH_SIZE);

        while let Some(attr) = map.next_key::<String>()? {
            let mut entry: PackageEntry = map.next_value()?;
            normalize_platform_fields(&mut entry, &mut self.unknown_patterns.borrow_mut());

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
    unknown_patterns: &'a RefCell<BTreeSet<String>>,
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
                        unknown_patterns: self.unknown_patterns,
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

fn stream_from_reader<R: Read>(
    reader: R,
    env: Env,
    pid: &LocalPid,
) -> Result<(u64, BTreeSet<String>), String> {
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

    let unknown_patterns = RefCell::new(BTreeSet::new());
    let mut deser = serde_json::Deserializer::from_slice(&decompressed);
    let version = deser
        .deserialize_map(TopLevelVisitor {
            caller_env: env,
            pid,
            unknown_patterns: &unknown_patterns,
        })
        .map_err(|e| e.to_string())?;

    Ok((version, unknown_patterns.into_inner()))
}

fn send_done(caller_env: Env, pid: &LocalPid, version: u64, unknown_patterns: &BTreeSet<String>) {
    let _ = send_from_nif(caller_env, pid, |env| {
        let keys = [
            atoms::version().encode(env),
            atoms::unknown_platform_patterns().encode(env),
        ];
        let patterns: Vec<Term> = unknown_patterns
            .iter()
            .map(|p| p.as_str().encode(env))
            .collect();
        let vals = [version.encode(env), patterns.encode(env)];
        let meta = Term::map_from_arrays(env, &keys, &vals).expect("failed to build done map");
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
        Ok((version, unknown_patterns)) => send_done(env, &caller, version, &unknown_patterns),
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

    // Test changelog normalization: bare string -> vec
    #[test]
    fn test_changelog_string_normalized_to_list() {
        let json = r#"{"version": "1.0", "meta": {"changelog": "https://example.com/NEWS"}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(
            entry.meta.unwrap().changelog,
            Some(vec!["https://example.com/NEWS".to_string()])
        );
    }

    // Test changelog normalization: list passes through (cryptopp ships two)
    #[test]
    fn test_changelog_list_passes_through() {
        let json = r#"{"version": "1.0", "meta": {"changelog": ["https://a.com/History.txt", "https://b.com/releases/tag/v1"]}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(
            entry.meta.unwrap().changelog,
            Some(vec![
                "https://a.com/History.txt".to_string(),
                "https://b.com/releases/tag/v1".to_string()
            ])
        );
    }

    // Test changelog normalization: null -> None
    #[test]
    fn test_changelog_null() {
        let json = r#"{"version": "1.0", "meta": {"changelog": null}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.meta.unwrap().changelog, None);
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

    // -- Extended span fields --

    #[test]
    fn test_top_level_pname_outputs_default_output() {
        let json = r#"{
            "version": "1.0",
            "pname": "hello",
            "outputs": {"out": null, "dev": null, "man": null},
            "outputName": "out"
        }"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.pname, Some("hello".to_string()));
        assert_eq!(
            entry.outputs,
            Some(vec![
                "out".to_string(),
                "dev".to_string(),
                "man".to_string()
            ])
        );
        assert_eq!(entry.default_output, Some("out".to_string()));
    }

    #[test]
    fn test_null_outputs_tolerated() {
        let json = r#"{"version": "1.0", "outputs": null}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.outputs, None);
    }

    #[test]
    fn test_meta_extended_fields() {
        let json = r#"{
            "version": "1.0",
            "meta": {
                "longDescription": "A long\ndescription",
                "mainProgram": "hello",
                "broken": false,
                "unfree": true,
                "insecure": true,
                "unsupported": false,
                "knownVulnerabilities": ["CVE-2024-0001"],
                "changelog": "https://example.com/changelog",
                "downloadPage": "https://example.com/download",
                "sourceProvenance": [{"shortName": "binaryNativeCode", "isSource": false}]
            }
        }"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        let meta = entry.meta.unwrap();
        assert_eq!(
            meta.long_description,
            Some("A long\ndescription".to_string())
        );
        assert_eq!(meta.main_program, Some("hello".to_string()));
        assert_eq!(meta.broken, Some(false));
        assert_eq!(meta.unfree, Some(true));
        assert_eq!(meta.insecure, Some(true));
        assert_eq!(meta.unsupported, Some(false));
        assert_eq!(
            meta.known_vulnerabilities,
            Some(vec!["CVE-2024-0001".to_string()])
        );
        assert_eq!(
            meta.changelog,
            Some(vec!["https://example.com/changelog".to_string()])
        );
        assert_eq!(
            meta.download_page,
            Some("https://example.com/download".to_string())
        );
        assert_eq!(
            meta.source_provenance,
            Some(vec!["binaryNativeCode".to_string()])
        );
    }

    #[test]
    fn test_absent_extended_fields_are_none() {
        let json = r#"{"version": "1.0", "meta": {"description": "test"}}"#;
        let entry: PackageEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.pname, None);
        assert_eq!(entry.outputs, None);
        assert_eq!(entry.default_output, None);
        let meta = entry.meta.unwrap();
        assert_eq!(meta.long_description, None);
        assert_eq!(meta.main_program, None);
        assert_eq!(meta.broken, None);
        assert_eq!(meta.known_vulnerabilities, None);
        assert_eq!(meta.source_provenance, None);
    }

    // -- Platform pattern normalization --

    fn normalize(json: &str) -> (String, BTreeSet<String>) {
        let mut unknowns = BTreeSet::new();
        let value: serde_json::Value = serde_json::from_str(json).unwrap();
        let name = normalize_platform_entry(value, &mut unknowns);
        (name, unknowns)
    }

    #[test]
    fn test_platform_string_passes_through() {
        assert_eq!(normalize(r#""x86_64-linux""#).0, "x86_64-linux");
    }

    #[test]
    fn test_platform_named_pattern() {
        let (name, unknowns) =
            normalize(r#"{"abi":{"abi":"n32"},"cpu":{"bits":64,"family":"mips"}}"#);
        assert_eq!(name, "mips64n32");
        assert!(unknowns.is_empty());
    }

    #[test]
    fn test_platform_list_member_maps_to_group_name() {
        assert_eq!(
            normalize(r#"{"abi":{"eabi":true,"float":"hard","name":"gnueabihf"}}"#).0,
            "gnu"
        );
        assert_eq!(normalize(r#"{"abi":{"name":"musl"}}"#).0, "musl");
    }

    // The linux and darwin patterns appear both as their own names and as
    // members of the isUnix group; the specific name must win.
    #[test]
    fn test_platform_ambiguity_prefers_specific_name() {
        let (name, _) =
            normalize(r#"{"kernel":{"execFormat":{"name":"elf"},"families":{},"name":"linux"}}"#);
        assert_eq!(name, "linux");

        let (name, _) = normalize(r#"{"kernel":{"families":{"darwin":{"name":"darwin"}}}}"#);
        assert_eq!(name, "darwin");
    }

    #[test]
    fn test_platform_static_quirk_ignores_empty_parsed() {
        let (name, unknowns) = normalize(r#"{"isStatic":true,"parsed":{}}"#);
        assert_eq!(name, "static");
        assert!(unknowns.is_empty());
    }

    #[test]
    fn test_platform_conjunctions() {
        let (name, _) =
            normalize(r#"{"cpu":{"bits":64},"kernel":{"families":{"bsd":{"name":"bsd"}}}}"#);
        assert_eq!(name, "64bit-bsd");

        let (name, _) = normalize(
            r#"{"cpu":{"family":"mips"},"kernel":{"execFormat":{"name":"elf"},"families":{},"name":"linux"}}"#,
        );
        assert_eq!(name, "mips-linux");
    }

    // packages.json serializes nixpkgs' typed attrsets with their `_type`
    // discriminator; the dumped pattern table carries none. These fixtures are
    // verbatim from a nixos-unstable packages.json.
    #[test]
    fn test_platform_typed_attrsets() {
        let (name, unknowns) =
            normalize(r#"{"abi":{"_type":"abi","eabi":true,"float":"hard","name":"gnueabihf"}}"#);
        assert_eq!(name, "gnu");
        assert!(unknowns.is_empty());

        assert_eq!(
            normalize(r#"{"abi":{"_type":"abi","abi":"64","name":"muslabi64"}}"#).0,
            "musl"
        );
        assert_eq!(
            normalize(
                r#"{"kernel":{"_type":"kernel","execFormat":{"_type":"exec-format","name":"elf"},"families":{},"name":"linux"}}"#
            )
            .0,
            "linux"
        );
        assert_eq!(
            normalize(r#"{"kernel":{"execFormat":{"_type":"exec-format","name":"elf"}}}"#).0,
            "elf"
        );
        assert_eq!(
            normalize(
                r#"{"kernel":{"families":{"darwin":{"_type":"exec-format","name":"darwin"}}}}"#
            )
            .0,
            "darwin"
        );
        assert_eq!(
            normalize(
                r#"{"abi":{"_type":"abi","name":"gnu"},"kernel":{"_type":"kernel","execFormat":{"_type":"exec-format","name":"pe"},"families":{},"name":"windows"}}"#
            )
            .0,
            "mingw"
        );
    }

    #[test]
    fn test_platform_typed_conjunctions() {
        assert_eq!(
            normalize(
                r#"{"cpu":{"bits":64,"family":"x86"},"kernel":{"_type":"kernel","execFormat":{"_type":"exec-format","name":"elf"},"families":{},"name":"linux"}}"#
            )
            .0,
            "x86_64-linux"
        );
        assert_eq!(
            normalize(
                r#"{"cpu":{"bits":64,"family":"riscv"},"kernel":{"_type":"kernel","execFormat":{"_type":"exec-format","name":"elf"},"families":{},"name":"linux"}}"#
            )
            .0,
            "riscv64-linux"
        );
    }

    // The x86 cpu spec is both isx86 and a member of isEfi; the conjunction
    // must be named after the specific pattern, like the exact-match case.
    #[test]
    fn test_platform_conjunction_prefers_specific_operand_name() {
        assert_eq!(
            normalize(
                r#"{"cpu":{"family":"x86"},"kernel":{"_type":"kernel","execFormat":{"_type":"exec-format","name":"elf"},"families":{},"name":"linux"}}"#
            )
            .0,
            "x86-linux"
        );
        assert_eq!(
            normalize(
                r#"{"cpu":{"family":"x86"},"kernel":{"families":{"darwin":{"_type":"exec-format","name":"darwin"}}}}"#
            )
            .0,
            "x86-darwin"
        );
    }

    // ppc64le: both operands are cpu patterns, so the cpu family leads and the
    // endianness modifier follows.
    #[test]
    fn test_platform_conjunction_cpu_family_leads() {
        assert_eq!(
            normalize(
                r#"{"cpu":{"bits":64,"family":"power","significantByte":{"_type":"significant-byte","name":"littleEndian"}}}"#
            )
            .0,
            "power64-littleendian"
        );
    }

    // The raw pattern is what a table extension needs, so log it untouched.
    #[test]
    fn test_platform_unknown_reports_raw_pattern() {
        let (name, unknowns) = normalize(r#"{"cpu":{"_type":"cpu-type","family":"frobnitz"}}"#);
        assert_eq!(name, "unknown-platform");
        assert!(unknowns.first().unwrap().contains("_type"));
    }

    #[test]
    fn test_platform_unknown_sentinel_and_accumulation() {
        let (name, unknowns) = normalize(r#"{"cpu":{"family":"frobnitz"}}"#);
        assert_eq!(name, "unknown-platform");
        assert_eq!(unknowns.len(), 1);
        assert!(unknowns.first().unwrap().contains("frobnitz"));
    }

    #[test]
    fn test_platform_fields_normalized_in_place() {
        let json = r#"{
            "version": "1.0",
            "meta": {
                "platforms": ["x86_64-linux", {"cpu":{"family":"mips"}}],
                "badPlatforms": [{"kernel":{"families":{"darwin":{"name":"darwin"}}}}]
            }
        }"#;
        let mut entry: PackageEntry = serde_json::from_str(json).unwrap();
        let mut unknowns = BTreeSet::new();
        normalize_platform_fields(&mut entry, &mut unknowns);

        let meta = entry.meta.unwrap();
        assert_eq!(
            meta.platforms,
            Some(vec!["x86_64-linux".to_string(), "mips".to_string()])
        );
        assert_eq!(meta.bad_platforms, Some(vec!["darwin".to_string()]));
        assert!(unknowns.is_empty());
    }
}
