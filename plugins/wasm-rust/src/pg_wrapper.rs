//! Asynchronous PostgreSQL access through the Higress PG host ABI v1.
//! Requires the matching custom gateway; stock Higress 2.2.6 has no PG ABI.
use crate::cluster_wrapper::Cluster;
use proxy_wasm::{hostcalls, types::PgCallStatus};
use serde::{Deserialize, Serialize};
use std::{cell::Cell, fmt, rc::Rc, time::Duration};

const VERSION: u32 = 1;
const MAX_TIMEOUT_MS: u128 = i32::MAX as u128;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PgParam {
    pub type_oid: u32,
    pub value: Option<String>,
}

impl PgParam {
    pub fn text(value: impl Into<String>) -> Self {
        Self {
            type_oid: 25,
            value: Some(value.into()),
        }
    }
    pub fn int8(value: i64) -> Self {
        Self {
            type_oid: 20,
            value: Some(value.to_string()),
        }
    }
    pub fn null(type_oid: u32) -> Self {
        Self {
            type_oid,
            value: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PgColumn {
    pub name: String,
    pub type_oid: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PgQueryResult {
    pub columns: Vec<PgColumn>,
    pub rows: Vec<Vec<Option<String>>>,
    pub command_tag: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PgErrorKind {
    Configuration,
    Submission(u32),
    NotInitialized,
    Database,
    Network,
    Timeout,
    Authentication,
    Protocol,
    ResourceExhausted,
    UnknownStatus(u32),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PgError {
    pub kind: PgErrorKind,
    pub message: String,
    pub sqlstate: Option<String>,
}

impl PgError {
    fn new(kind: PgErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            sqlstate: None,
        }
    }
}

impl fmt::Display for PgError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.message)
    }
}
impl std::error::Error for PgError {}
impl From<hostcalls::PgHostcallError> for PgError {
    fn from(value: hostcalls::PgHostcallError) -> Self {
        Self::new(PgErrorKind::Submission(value.0), value.to_string())
    }
}

pub type PgQueryCallbackFn = dyn FnOnce(Result<PgQueryResult, PgError>);

#[derive(Clone, Serialize)]
struct Config {
    version: u32,
    username: String,
    password: String,
    database: String,
    tls_mode: String,
    connect_timeout_ms: u32,
    max_connections: u32,
    max_pending_requests: u32,
    max_rows: u32,
    max_response_bytes: u32,
    max_request_bytes: u32,
    idle_timeout_ms: u32,
}

/// All clones share the root-scoped client handle. Do not move between workers.
#[derive(Clone)]
pub struct PgClient {
    upstream: String,
    config: Config,
    timeout: Duration,
    handle: Rc<Cell<Option<u32>>>,
}

// Intentionally omit credentials, cluster, and config from Debug.
impl fmt::Debug for PgClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PgClient")
            .field("initialized", &self.handle.get().is_some())
            .finish()
    }
}

pub struct PgClientBuilder {
    upstream: String,
    config: Config,
    timeout: Duration,
}

impl PgClientBuilder {
    pub fn new(cluster: &dyn Cluster, timeout: Duration) -> Self {
        Self {
            upstream: cluster.cluster_name(),
            timeout,
            config: Config {
                version: VERSION,
                username: String::new(),
                password: String::new(),
                database: String::new(),
                tls_mode: "require".into(),
                connect_timeout_ms: 1000,
                max_connections: 8,
                max_pending_requests: 128,
                max_rows: 1000,
                max_response_bytes: 1_048_576,
                max_request_bytes: 65_536,
                idle_timeout_ms: 60_000,
            },
        }
    }
    pub fn username(mut self, value: impl Into<String>) -> Self {
        self.config.username = value.into();
        self
    }
    pub fn password(mut self, value: impl Into<String>) -> Self {
        self.config.password = value.into();
        self
    }
    pub fn database(mut self, value: impl Into<String>) -> Self {
        self.config.database = value.into();
        self
    }
    /// `require` needs a StartTLS cluster with certificate/SAN validation configured.
    /// `disable` is intended for explicitly configured plaintext test clusters.
    pub fn tls_mode(mut self, value: impl Into<String>) -> Self {
        self.config.tls_mode = value.into();
        self
    }
    pub fn connect_timeout(mut self, value: Duration) -> Self {
        self.config.connect_timeout_ms = if valid_timeout(value) {
            value.as_millis() as u32
        } else {
            0
        };
        self
    }
    pub fn max_connections(mut self, value: u32) -> Self {
        self.config.max_connections = value;
        self
    }
    pub fn max_pending_requests(mut self, value: u32) -> Self {
        self.config.max_pending_requests = value;
        self
    }
    pub fn max_rows(mut self, value: u32) -> Self {
        self.config.max_rows = value;
        self
    }
    pub fn max_response_bytes(mut self, value: u32) -> Self {
        self.config.max_response_bytes = value;
        self
    }
    pub fn max_request_bytes(mut self, value: u32) -> Self {
        self.config.max_request_bytes = value;
        self
    }
    pub fn idle_timeout(mut self, value: Duration) -> Self {
        self.config.idle_timeout_ms = if valid_timeout(value) {
            value.as_millis() as u32
        } else {
            0
        };
        self
    }
    pub fn build(self) -> Result<PgClient, PgError> {
        let c = &self.config;
        if self.upstream.is_empty()
            || self.upstream.contains('\0')
            || c.username.is_empty()
            || c.database.is_empty()
            || [&c.username, &c.password, &c.database]
                .iter()
                .any(|v| v.contains('\0'))
            || !matches!(c.tls_mode.as_str(), "require" | "disable")
            || !valid_timeout(self.timeout)
            || c.connect_timeout_ms == 0
            || c.idle_timeout_ms == 0
            || !(1..=64).contains(&c.max_connections)
            || !(1..=1024).contains(&c.max_pending_requests)
            || !(1..=100_000).contains(&c.max_rows)
            || !(256..=16_777_216).contains(&c.max_response_bytes)
            || !(64..=1_048_576).contains(&c.max_request_bytes)
        {
            return Err(PgError::new(
                PgErrorKind::Configuration,
                "invalid PostgreSQL client configuration",
            ));
        }
        Ok(PgClient {
            upstream: self.upstream,
            config: self.config,
            timeout: self.timeout,
            handle: Rc::new(Cell::new(None)),
        })
    }
}

fn valid_timeout(value: Duration) -> bool {
    let millis = value.as_millis();
    millis > 0 && millis <= MAX_TIMEOUT_MS
}

impl PgClient {
    pub fn init(&self) -> Result<(), PgError> {
        // Always consult the host: a cloned/reconfigured VM must not reuse a stale
        // client handle copied in Wasm memory. Identical configs are deduplicated by the host.
        let config = serde_json::to_vec(&self.config).map_err(|_| {
            PgError::new(
                PgErrorKind::Configuration,
                "cannot encode PostgreSQL configuration",
            )
        })?;
        self.handle
            .set(Some(hostcalls::pg_init(&self.upstream, &config)?));
        Ok(())
    }

    pub fn query(
        &self,
        sql: &str,
        params: &[PgParam],
        callback: Box<PgQueryCallbackFn>,
    ) -> Result<u32, PgError> {
        let handle = self.handle.get().ok_or_else(|| {
            PgError::new(
                PgErrorKind::NotInitialized,
                "call init() in the configuration context first",
            )
        })?;
        let request = encode_request(sql, params, self.config.max_request_bytes)?;
        let limit = self.config.max_response_bytes as usize;
        Ok(hostcalls::dispatch_pg_call(
            handle,
            &request,
            self.timeout,
            Box::new(move |_, status, size| {
                let result = if size > limit {
                    Err(PgError::new(
                        PgErrorKind::ResourceExhausted,
                        "PostgreSQL response exceeds configured limit",
                    ))
                } else {
                    hostcalls::get_pg_call_response(size)
                        .map_err(PgError::from)
                        .and_then(|body| {
                            body.ok_or_else(|| {
                                PgError::new(PgErrorKind::Protocol, "missing PostgreSQL response")
                            })
                        })
                        .and_then(|body| decode_response(status, &body))
                };
                callback(result);
            }),
        )?)
    }
}

fn encode_request(sql: &str, params: &[PgParam], limit: u32) -> Result<Vec<u8>, PgError> {
    if sql.trim().is_empty()
        || sql.contains('\0')
        || params.len() > i16::MAX as usize
        || params
            .iter()
            .any(|p| p.value.as_ref().is_some_and(|v| v.contains('\0')))
    {
        return Err(PgError::new(
            PgErrorKind::Configuration,
            "invalid SQL or query parameters",
        ));
    }
    // Limit before serialization as well as after JSON escaping.
    let raw_size = params.iter().try_fold(sql.len(), |n, p| {
        n.checked_add(p.value.as_ref().map_or(0, String::len))
    });
    if raw_size.map_or(true, |n| n > limit as usize) {
        return Err(PgError::new(
            PgErrorKind::ResourceExhausted,
            "PostgreSQL request exceeds configured limit",
        ));
    }
    #[derive(Serialize)]
    struct Request<'a> {
        version: u32,
        sql: &'a str,
        params: &'a [PgParam],
    }
    let data = serde_json::to_vec(&Request {
        version: VERSION,
        sql,
        params,
    })
    .map_err(|_| PgError::new(PgErrorKind::Protocol, "cannot encode PostgreSQL request"))?;
    if data.len() > limit as usize {
        return Err(PgError::new(
            PgErrorKind::ResourceExhausted,
            "PostgreSQL request exceeds configured limit",
        ));
    }
    Ok(data)
}

fn decode_response(status: u32, data: &[u8]) -> Result<PgQueryResult, PgError> {
    let status = PgCallStatus::try_from(status).map_err(|s| {
        PgError::new(
            PgErrorKind::UnknownStatus(s),
            "unknown PostgreSQL completion status",
        )
    })?;
    if status != PgCallStatus::Ok {
        #[derive(Deserialize)]
        struct ErrorBody {
            version: u32,
            message: String,
            sqlstate: Option<String>,
        }
        let body: ErrorBody = serde_json::from_slice(data).map_err(|_| {
            PgError::new(PgErrorKind::Protocol, "invalid PostgreSQL error envelope")
        })?;
        if body.version != VERSION {
            return Err(PgError::new(
                PgErrorKind::Protocol,
                "unsupported PostgreSQL response version",
            ));
        }
        let kind = match status {
            PgCallStatus::DatabaseError => PgErrorKind::Database,
            PgCallStatus::NetworkError => PgErrorKind::Network,
            PgCallStatus::Timeout => PgErrorKind::Timeout,
            PgCallStatus::AuthenticationError => PgErrorKind::Authentication,
            PgCallStatus::ResourceExhausted => PgErrorKind::ResourceExhausted,
            _ => PgErrorKind::Protocol,
        };
        return Err(PgError {
            kind,
            message: body.message,
            sqlstate: body.sqlstate,
        });
    }
    #[derive(Deserialize)]
    struct Envelope {
        version: u32,
        #[serde(flatten)]
        result: PgQueryResult,
    }
    let env: Envelope = serde_json::from_slice(data)
        .map_err(|_| PgError::new(PgErrorKind::Protocol, "invalid PostgreSQL result envelope"))?;
    if env.version != VERSION
        || env
            .result
            .rows
            .iter()
            .any(|r| r.len() != env.result.columns.len())
    {
        return Err(PgError::new(
            PgErrorKind::Protocol,
            "invalid PostgreSQL result version or column count",
        ));
    }
    Ok(env.result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_null_empty_precision_and_duplicate_columns() {
        let data = br#"{"version":1,"columns":[{"name":"v","type_oid":20},{"name":"v","type_oid":25}],"rows":[["9223372036854775807",null],["1",""]],"command_tag":"SELECT 2"}"#;
        let result = decode_response(0, data).unwrap();
        assert_eq!(result.rows[0][0].as_deref(), Some("9223372036854775807"));
        assert_eq!(result.rows[0][1], None);
        assert_eq!(result.rows[1][1].as_deref(), Some(""));
        assert_eq!(result.columns[0].name, result.columns[1].name);
    }
    #[test]
    fn validates_protocol_and_sqlstate() {
        assert_eq!(
            decode_response(99, b"{}").unwrap_err().kind,
            PgErrorKind::UnknownStatus(99)
        );
        assert_eq!(
            decode_response(
                0,
                br#"{"version":2,"columns":[],"rows":[],"command_tag":""}"#
            )
            .unwrap_err()
            .kind,
            PgErrorKind::Protocol
        );
        assert_eq!(
            decode_response(
                0,
                br#"{"version":1,"columns":[],"rows":[[null]],"command_tag":""}"#
            )
            .unwrap_err()
            .kind,
            PgErrorKind::Protocol
        );
        let err = decode_response(
            1,
            br#"{"version":1,"message":"syntax error","sqlstate":"42601"}"#,
        )
        .unwrap_err();
        assert_eq!(err.kind, PgErrorKind::Database);
        assert_eq!(err.sqlstate.as_deref(), Some("42601"));
    }
    #[test]
    fn parameter_binding_and_limits() {
        let bytes = encode_request(
            "SELECT $1, $2",
            &[PgParam::text("'; SELECT 2"), PgParam::null(25)],
            1024,
        )
        .unwrap();
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["sql"], "SELECT $1, $2");
        assert!(value["params"][1]["value"].is_null());
        assert!(encode_request("SELECT 1\0", &[], 1024).is_err());
        assert!(encode_request("SELECT 1", &[], 8).is_err());
        assert!(!valid_timeout(Duration::from_micros(10)));
        assert!(!valid_timeout(Duration::from_millis(u32::MAX as u64)));
    }
}
