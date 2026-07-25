//! Shared rmcp server wiring helper. Each aspect server runs one
//! `ServerHandler` over stdio. This helper is thin and identical across
//! aspects: passing the server struct spawns it on `transport::stdio()`.

use rmcp::transport::stdio;
use rmcp::service::serve_server;

/// Serves a `ServerHandler` over stdio. Blocks until the client disconnects
/// or the process is signalled. Used by every aspect server's `main`.
pub async fn serve<H>(server: H) -> anyhow::Result<()>
where
    H: rmcp::ServerHandler,
{
    let rs = serve_server(server, stdio()).await?;
    let reason = rs.waiting().await?;
    tracing::info!(?reason, "mcp server exited");
    Ok(())
}