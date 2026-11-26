// Standalone validation of the exact production codec against a real PostgreSQL server.
// Blocking socket IO is confined to this test driver; Envoy uses async_client.cc.
#include "source/common/postgres/codec.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cassert>
#include <iostream>
#include <memory>
#include "openssl/ssl.h"
#include "openssl/x509_vfy.h"

using namespace Envoy::Postgres;
class Connection {
public:
  Connection(const Config& config, uint16_t port, const std::string& ca = {}, const std::string& hostname = {}) : config_(config), decoder_(65536) {
    fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (fd_ < 0) throw std::runtime_error("socket failed");
    timeval timeout{5, 0}; setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (::connect(fd_, reinterpret_cast<sockaddr*>(&address), sizeof(address))) throw std::runtime_error("connect failed");
    if (!ca.empty()) {
      write(sslRequest());
      char reply = 0;
      if (recv(fd_, &reply, 1, 0) != 1 || reply != 'S') throw std::runtime_error("SSLRequest rejected");
      ssl_context_.reset(SSL_CTX_new(TLS_client_method()));
      if (!ssl_context_ || SSL_CTX_load_verify_locations(ssl_context_.get(), ca.c_str(), nullptr) != 1)
        throw std::runtime_error("invalid TLS CA");
      SSL_CTX_set_verify(ssl_context_.get(), SSL_VERIFY_PEER, nullptr);
      ssl_.reset(SSL_new(ssl_context_.get()));
      if (!ssl_ || SSL_set_fd(ssl_.get(), fd_) != 1 || SSL_set1_host(ssl_.get(), hostname.c_str()) != 1
          || SSL_set_tlsext_host_name(ssl_.get(), hostname.c_str()) != 1 || SSL_connect(ssl_.get()) != 1)
        throw std::runtime_error("TLS certificate/hostname verification failed");
    }
    write(startup(config));
    bool authenticated = false;
    for (;;) {
      auto [type, body] = read();
      if (type == 'E') throw databaseError(body, true);
      if (type == 'R') {
        Reader r(body); auto method = r.u32();
        auth_method_ = std::max(auth_method_, method);
        switch (method) {
        case 0: if (scram_used_ && !scram_.verified()) throw std::runtime_error("SCRAM signature not verified"); authenticated = true; break;
        case 5: write(passwordMessage(md5Password(config_, r.bytes(4)))); break;
        case 10: scram_used_ = true; write(scram_.start(r.bytes(r.remaining()))); break;
        case 11: write(scram_.continueWith(r.bytes(r.remaining()), config_.password)); break;
        case 12: scram_.finish(r.bytes(r.remaining())); break;
        default: throw std::runtime_error("unsupported authentication");
        }
      }
      if (type == 'Z') { if (!authenticated || body != "I") throw std::runtime_error("startup not idle"); break; }
    }
  }
  ~Connection() { if (fd_ >= 0) ::close(fd_); }
  Json query(const std::string& sql, const Json& params = Json::array()) {
    auto query = Query::parse(Json{{"version", 1}, {"sql", sql}, {"params", params}}.dump(), 65536);
    write(queryMessages(query)); Result result(config_); std::optional<Failure> error;
    for (;;) {
      auto [type, body] = read();
      switch (type) {
      case 'T': result.columns(body); break;
      case 'D': result.row(body); break;
      case 'C': result.command(body); break;
      case 'E': error = databaseError(body, false); break;
      case 'Z': {
        if (body != "I") throw Failure(Status::ProtocolError, "not idle");
        write(discardAll());
        bool complete = false;
        for (;;) {
          auto [t, b] = read();
          if (t == 'E') throw std::runtime_error("reset failed");
          if (t == 'C') complete = true;
          if (t == 'Z') { if (!complete || b != "I") throw std::runtime_error("reset not idle"); break; }
        }
        if (error) throw *error;
        return Json::parse(result.encode());
      }
      default: break;
      }
    }
  }
  uint32_t auth_method_{0};
private:
  void write(const std::string& data) {
    size_t offset = 0;
    while (offset < data.size()) { auto n = ssl_ ? SSL_write(ssl_.get(), data.data() + offset, data.size() - offset) : ::send(fd_, data.data() + offset, data.size() - offset, 0); if (n <= 0) throw std::runtime_error("send failed"); offset += n; }
  }
  std::pair<char, std::string> read() {
    char type; std::string body;
    while (!decoder_.next(type, body)) {
      char bytes[4096]; auto n = ssl_ ? SSL_read(ssl_.get(), bytes, sizeof(bytes)) : recv(fd_, bytes, sizeof(bytes), 0);
      if (n <= 0) throw std::runtime_error("read failed");
      decoder_.append({bytes, static_cast<size_t>(n)});
    }
    return {type, std::move(body)};
  }
  std::unique_ptr<SSL_CTX, decltype(&SSL_CTX_free)> ssl_context_{nullptr, SSL_CTX_free};
  std::unique_ptr<SSL, decltype(&SSL_free)> ssl_{nullptr, SSL_free};
  Config config_; Decoder decoder_; Scram scram_; int fd_{-1}; bool scram_used_{false};
};
int main(int argc, char** argv) {
  if (argc != 4 && argc != 6) { std::cerr << "usage: protocol_integration PORT USER PASSWORD [CA HOSTNAME]\n"; return 2; }
  Config c{argv[2], argv[3], "postgres", "disable", 1000, 8, 128, 1000, 1048576, 65536, 60000};
  const std::string ca = argc == 6 ? argv[4] : "";
  const std::string hostname = argc == 6 ? argv[5] : "";
  try {
    Connection connection(c, std::stoi(argv[1]), ca, hostname);
    auto single = connection.query("SELECT 1"); assert(single["rows"][0][0] == "1");
    auto values = connection.query("SELECT $1::int8 AS v, $2::text AS v, $3::text AS empty, $4::numeric AS precise",
      Json::array({Json{{"type_oid",20},{"value","9223372036854775807"}}, Json{{"type_oid",25},{"value",nullptr}}, Json{{"type_oid",25},{"value",""}}, Json{{"type_oid",1700},{"value","12345678901234567890.123456789"}}}));
    assert(values["rows"][0][0] == "9223372036854775807" && values["rows"][0][1].is_null() && values["rows"][0][2] == "");
    assert(values["rows"][0][3] == "12345678901234567890.123456789");
    assert(values["columns"][0]["name"] == values["columns"][1]["name"]);
    auto injection = connection.query("SELECT $1::text", Json::array({Json{{"type_oid",25},{"value","'; SELECT 2 --"}}}));
    assert(injection["rows"][0][0] == "'; SELECT 2 --");
    auto semicolon = connection.query("SELECT ';'::text, $$a;b$$::text /* ; */"); assert(semicolon["rows"][0][1] == "a;b");
    auto empty = connection.query("SELECT 1 WHERE false"); assert(empty["rows"].empty());
    auto unicode = connection.query("SELECT '中文'::text"); assert(unicode["rows"][0][0] == "中文");
    for (const auto& sql : {"SELECT 1; SELECT 2", "SELEC 1"}) {
      bool rejected = false;
      try { connection.query(sql); } catch (const Failure& e) { rejected = e.sqlstate == "42601"; }
      assert(rejected);
      assert(connection.query("SELECT 42")["rows"][0][0] == "42");
    }
    connection.query("SELECT set_config('application_name', 'polluted', false)");
    assert(connection.query("SELECT current_setting('application_name')")["rows"][0][0] == "higress-wasm");
    auto small = c; small.max_rows = 2;
    bool bounded = false;
    try { Connection limit(small, std::stoi(argv[1]), ca, hostname); limit.query("SELECT generate_series(1, 3)"); }
    catch (const Failure& e) { bounded = e.status == Status::ResourceExhausted; }
    assert(bounded);
    std::cout << Json{{"passed", 12}, {"authentication_method", connection.auth_method_}, {"scram_verified", connection.auth_method_ == 12}, {"tls_verified", !ca.empty()}}.dump() << '\n';
  } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
