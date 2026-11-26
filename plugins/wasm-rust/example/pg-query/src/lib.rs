//! Local verification plugin. The HTTP body is a query envelope, not a production API.
use higress_wasm_rust::{cluster_wrapper::Cluster, pg_wrapper::*};
use proxy_wasm::{hostcalls, traits::*, types::*};
use serde::Deserialize;
use std::time::Duration;

struct TestCluster(String);
impl Cluster for TestCluster {
    fn cluster_name(&self) -> String {
        self.0.clone()
    }
    fn host_name(&self) -> String {
        self.0.clone()
    }
}

#[derive(Deserialize)]
struct Config {
    cluster: String,
    username: String,
    password: String,
    database: String,
    #[serde(default = "timeout")]
    timeout_ms: u64,
    #[serde(default = "tls")]
    tls_mode: String,
    #[serde(default = "rows")]
    max_rows: u32,
}
fn timeout() -> u64 {
    500
}
fn tls() -> String {
    "require".into()
}
fn rows() -> u32 {
    1000
}
#[derive(Default)]
struct Root {
    client: Option<PgClient>,
}
impl Context for Root {}
impl RootContext for Root {
    fn on_configure(&mut self, _: usize) -> bool {
        self.client = None;
        let result = (|| -> Result<PgClient, Box<dyn std::error::Error>> {
            let data = self
                .get_plugin_configuration()
                .ok_or("missing configuration")?;
            let config: Config = serde_json::from_slice(&data)?;
            let cluster = TestCluster(config.cluster);
            let client = PgClientBuilder::new(&cluster, Duration::from_millis(config.timeout_ms))
                .username(config.username)
                .password(config.password)
                .database(config.database)
                .tls_mode(config.tls_mode)
                .max_rows(config.max_rows)
                .build()?;
            client.init()?;
            Ok(client)
        })();
        match result {
            Ok(client) => {
                self.client = Some(client);
                true
            }
            Err(_) => {
                let _ = hostcalls::log(
                    LogLevel::Error,
                    "PG verification client configuration failed",
                );
                false
            }
        }
    }
    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }
    fn create_http_context(&self, _: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(QueryContext {
            client: self.client.clone(),
            submitted: false,
        }))
    }
}
struct QueryContext {
    client: Option<PgClient>,
    submitted: bool,
}
impl Context for QueryContext {}
fn reply(status: u32, body: &[u8]) {
    let _ = hostcalls::send_http_response(
        status,
        vec![("content-type", "application/json")],
        Some(body),
    );
}
impl QueryContext {
    fn submit(&mut self, body: &[u8]) {
        if self.submitted {
            return;
        }
        self.submitted = true;
        #[derive(Deserialize)]
        struct Request {
            sql: String,
            #[serde(default)]
            params: Vec<PgParam>,
        }
        let request: Request = match serde_json::from_slice(body) {
            Ok(request) => request,
            Err(_) => {
                reply(400, br#"{"error":"invalid query envelope"}"#);
                return;
            }
        };
        let Some(client) = &self.client else {
            reply(503, br#"{"error":"PG unavailable"}"#);
            return;
        };
        let result = client.query(&request.sql, &request.params, Box::new(|result| match result {
            Ok(result) => {
                let data = serde_json::json!({"columns": result.columns, "rows": result.rows, "command_tag": result.command_tag});
                reply(200, data.to_string().as_bytes());
            }
            Err(error) => {
                let status = match error.kind {
                    PgErrorKind::Timeout => 504,
                    PgErrorKind::Database => 400,
                    PgErrorKind::ResourceExhausted => 429,
                    _ => 502,
                };
                reply(status, serde_json::json!({"error": error.message, "sqlstate": error.sqlstate}).to_string().as_bytes());
            }
        }));
        if result.is_err() {
            reply(503, br#"{"error":"PG submission failed"}"#);
        }
    }
}
impl HttpContext for QueryContext {
    fn on_http_request_headers(&mut self, _: usize, end: bool) -> HeaderAction {
        if end {
            self.submit(br#"{"sql":"SELECT 1"}"#);
        }
        HeaderAction::StopIteration
    }
    fn on_http_request_body(&mut self, size: usize, end: bool) -> DataAction {
        if size > 65536 {
            reply(413, br#"{"error":"query body too large"}"#);
            return DataAction::StopIterationNoBuffer;
        }
        if !end {
            return DataAction::StopIterationAndBuffer;
        }
        let body = self.get_http_request_body(0, size).unwrap_or_default();
        self.submit(&body);
        DataAction::StopIterationNoBuffer
    }
}
proxy_wasm::main! {{ proxy_wasm::set_root_context(|_| Box::<Root>::default()); }}
