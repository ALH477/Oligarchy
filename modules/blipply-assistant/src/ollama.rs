// Blipply Assistant
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::{Result, Context};
use futures::Stream;
use pin_project::pin_project;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::pin::Pin;
use std::task::{Context as TaskContext, Poll};
use tracing::{debug, error};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}

impl Message {
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: "user".to_string(),
            content: content.into(),
        }
    }

    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: "assistant".to_string(),
            content: content.into(),
        }
    }

    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: "system".to_string(),
            content: content.into(),
        }
    }
}

#[derive(Debug, Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<Message>,
    stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    options: Option<GenerationOptions>,
}

#[derive(Debug, Serialize)]
struct GenerationOptions {
    temperature: f32,
    num_ctx: u32,
}

#[derive(Debug, Deserialize)]
struct ChatResponse {
    message: Message,
    done: bool,
}

pub struct OllamaClient {
    client: Client,
    base_url: String,
}

impl OllamaClient {
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            client: Client::new(),
            base_url: base_url.into(),
        }
    }

    pub async fn list_models(&self) -> Result<Vec<String>> {
        let url = format!("{}/api/tags", self.base_url);
        
        #[derive(Deserialize)]
        struct TagsResponse {
            models: Vec<ModelInfo>,
        }
        
        #[derive(Deserialize)]
        struct ModelInfo {
            name: String,
        }
        
        let response = self.client
            .get(&url)
            .send()
            .await
            .context("Failed to fetch models")?;
        
        let tags: TagsResponse = response.json().await?;
        Ok(tags.models.into_iter().map(|m| m.name).collect())
    }

    pub async fn chat(
        &self,
        model: &str,
        messages: Vec<Message>,
    ) -> Result<String> {
        let url = format!("{}/api/chat", self.base_url);
        
        let request = ChatRequest {
            model: model.to_string(),
            messages,
            stream: false,
            options: Some(GenerationOptions {
                temperature: 0.7,
                num_ctx: 4096,
            }),
        };

        debug!("Sending chat request to Ollama");
        
        let response = self.client
            .post(&url)
            .json(&request)
            .send()
            .await
            .context("Failed to send chat request")?;

        let chat_response: ChatResponse = response.json().await?;
        Ok(chat_response.message.content)
    }

    pub fn chat_stream(
        &self,
        model: String,
        messages: Vec<Message>,
    ) -> impl Stream<Item = Result<String>> + '_ {
        ChatStream::new(self, model, messages)
    }
}

#[pin_project]
struct ChatStream {
    #[pin]
    inner: Pin<Box<dyn Stream<Item = Result<bytes::Bytes>> + Send>>,
    buffer: String,
}

impl ChatStream {
    fn new(client: &OllamaClient, model: String, messages: Vec<Message>) -> Self {
        let url = format!("{}/api/chat", client.base_url);
        let http_client = client.client.clone();
        
        let request = ChatRequest {
            model,
            messages,
            stream: true,
            options: Some(GenerationOptions {
                temperature: 0.7,
                num_ctx: 4096,
            }),
        };

        let stream = Box::pin(async_stream::stream! {
            match http_client.post(&url).json(&request).send().await {
                Ok(response) => {
                    let mut stream = response.bytes_stream();
                    while let Some(chunk) = futures::StreamExt::next(&mut stream).await {
                        match chunk {
                            Ok(bytes) => yield Ok(bytes),
                            Err(e) => {
                                error!("Stream error: {}", e);
                                yield Err(anyhow::anyhow!("Stream error: {}", e));
                            }
                        }
                    }
                }
                Err(e) => {
                    error!("Failed to start stream: {}", e);
                    yield Err(anyhow::anyhow!("Failed to start stream: {}", e));
                }
            }
        });

        Self {
            inner: stream,
            buffer: String::new(),
        }
    }
}

impl Stream for ChatStream {
    type Item = Result<String>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<Option<Self::Item>> {
        let mut this = self.project();
        
        match this.inner.as_mut().poll_next(cx) {
            Poll::Ready(Some(Ok(bytes))) => {
                this.buffer.push_str(&String::from_utf8_lossy(&bytes));
                
                // Process complete JSON objects (newline-delimited)
                if let Some(newline_pos) = this.buffer.find('\n') {
                    let line = this.buffer.drain(..=newline_pos).collect::<String>();
                    let line = line.trim();
                    
                    if line.is_empty() {
                        return Poll::Pending;
                    }
                    
                    match serde_json::from_str::<ChatResponse>(line) {
                        Ok(response) => {
                            if !response.message.content.is_empty() {
                                Poll::Ready(Some(Ok(response.message.content)))
                            } else {
                                Poll::Pending
                            }
                        }
                        Err(e) => {
                            error!("Failed to parse JSON: {} - Line: {}", e, line);
                            Poll::Pending
                        }
                    }
                } else {
                    Poll::Pending
                }
            }
            Poll::Ready(Some(Err(e))) => Poll::Ready(Some(Err(e))),
            Poll::Ready(None) => Poll::Ready(None),
            Poll::Pending => Poll::Pending,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_ollama_client_creation() {
        let client = OllamaClient::new("http://localhost:11434");
        assert_eq!(client.base_url, "http://localhost:11434");
    }

    #[test]
    fn test_message_creation() {
        let msg = Message::user("Hello");
        assert_eq!(msg.role, "user");
        assert_eq!(msg.content, "Hello");
    }
}
