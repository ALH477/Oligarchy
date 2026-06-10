// Blipply Assistant — MCP client
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License
//
// Minimal Model Context Protocol stdio client. Spawns the local, read-only
// Oligarchy MCP server (`oligarchy-mcp`) as a child process and speaks
// newline-delimited JSON-RPC over its stdin/stdout. No new heavy crate: built
// on the existing tokio + serde_json dependencies.
//
// One client is created per user message and dropped afterwards (the server is
// a cheap, stateless Python process), which keeps ownership simple.

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

pub struct McpClient {
    child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    next_id: i64,
}

impl McpClient {
    /// Spawn the MCP server (`command` may include arguments) and complete the
    /// initialize handshake.
    pub async fn connect(command: &str) -> Result<Self> {
        let mut parts = command.split_whitespace();
        let prog = parts.next().context("empty mcp command")?;
        let args: Vec<&str> = parts.collect();

        let mut child = Command::new(prog)
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("failed to spawn MCP server: {command}"))?;

        let stdin = child.stdin.take().context("MCP child has no stdin")?;
        let stdout = child.stdout.take().context("MCP child has no stdout")?;
        let lines = BufReader::new(stdout).lines();

        let mut client = Self { child, stdin, lines, next_id: 1 };
        client.initialize().await?;
        Ok(client)
    }

    async fn send(&mut self, msg: &Value) -> Result<()> {
        let mut s = serde_json::to_string(msg)?;
        s.push('\n');
        self.stdin.write_all(s.as_bytes()).await?;
        self.stdin.flush().await?;
        Ok(())
    }

    async fn read_response(&mut self, id: i64) -> Result<Value> {
        loop {
            let line = self
                .lines
                .next_line()
                .await?
                .ok_or_else(|| anyhow!("MCP server closed the connection"))?;
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let v: Value = match serde_json::from_str(line) {
                Ok(v) => v,
                Err(_) => continue, // ignore non-JSON noise
            };
            if v.get("id").and_then(Value::as_i64) == Some(id) {
                if let Some(err) = v.get("error") {
                    return Err(anyhow!("MCP error: {err}"));
                }
                return Ok(v.get("result").cloned().unwrap_or(Value::Null));
            }
            // otherwise a notification or unrelated message — keep reading
        }
    }

    async fn request(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        let msg = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
        self.send(&msg).await?;
        self.read_response(id).await
    }

    async fn notify(&mut self, method: &str, params: Value) -> Result<()> {
        let msg = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        self.send(&msg).await
    }

    async fn initialize(&mut self) -> Result<()> {
        self.request(
            "initialize",
            json!({
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": { "name": "blipply", "version": "1.0" }
            }),
        )
        .await?;
        self.notify("notifications/initialized", json!({})).await?;
        Ok(())
    }

    /// List the server's tools as Ollama-format function definitions, optionally
    /// filtered to an allowlist (empty = allow all).
    pub async fn list_tools_ollama(&mut self, allowed: &[String]) -> Result<Vec<Value>> {
        let result = self.request("tools/list", json!({})).await?;
        let tools = result
            .get("tools")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();

        let mut out = Vec::new();
        for t in tools {
            let name = t.get("name").and_then(Value::as_str).unwrap_or("").to_string();
            if name.is_empty() {
                continue;
            }
            if !allowed.is_empty() && !allowed.iter().any(|a| a == &name) {
                continue;
            }
            let desc = t
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let schema = t
                .get("inputSchema")
                .cloned()
                .unwrap_or_else(|| json!({ "type": "object" }));
            out.push(json!({
                "type": "function",
                "function": { "name": name, "description": desc, "parameters": schema }
            }));
        }
        Ok(out)
    }

    /// Invoke a tool; returns its concatenated text content.
    pub async fn call_tool(&mut self, name: &str, arguments: &Value) -> Result<String> {
        // Models sometimes omit arguments for no-arg tools; send {} not null.
        let args = if arguments.is_null() { json!({}) } else { arguments.clone() };
        let result = self
            .request("tools/call", json!({ "name": name, "arguments": args }))
            .await?;

        let mut text = String::new();
        if let Some(content) = result.get("content").and_then(Value::as_array) {
            for item in content {
                if let Some(t) = item.get("text").and_then(Value::as_str) {
                    if !text.is_empty() {
                        text.push('\n');
                    }
                    text.push_str(t);
                }
            }
        }
        if text.is_empty() {
            text = result.to_string();
        }
        Ok(text)
    }
}

impl Drop for McpClient {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}
