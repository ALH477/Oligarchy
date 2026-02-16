use std::fs;
use std::time::Duration;

pub struct SystemInfo {
    pub os_name: String,
    pub kernel: String,
    pub hostname: String,
    pub uptime: String,
    pub memory_total: u64,
    pub memory_used: u64,
    pub memory_percent: f32,
}

impl SystemInfo {
    pub fn gather() -> Self {
        Self {
            os_name: Self::get_os_name(),
            kernel: Self::get_kernel(),
            hostname: Self::get_hostname(),
            uptime: Self::get_uptime(),
            memory_total: 0,
            memory_used: 0,
            memory_percent: 0.0,
        }
        .with_memory()
    }
    
    fn get_os_name() -> String {
        if let Ok(content) = fs::read_to_string("/etc/os-release") {
            for line in content.lines() {
                if line.starts_with("PRETTY_NAME=") {
                    return line
                        .trim_start_matches("PRETTY_NAME=")
                        .trim_matches('"')
                        .to_string();
                }
            }
        }
        "Unknown".to_string()
    }
    
    fn get_kernel() -> String {
        if let Ok(content) = fs::read_to_string("/proc/version") {
            content
                .split_whitespace()
                .nth(2)
                .map(|s| s.to_string())
                .unwrap_or_else(|| "Unknown".to_string())
        } else {
            "Unknown".to_string()
        }
    }
    
    fn get_hostname() -> String {
        if let Ok(hostname) = fs::read_to_string("/proc/sys/kernel/hostname") {
            hostname.trim().to_string()
        } else {
            "Unknown".to_string()
        }
    }
    
    fn get_uptime() -> String {
        if let Ok(content) = fs::read_to_string("/proc/uptime") {
            if let Some(seconds_str) = content.split_whitespace().next() {
                if let Ok(seconds) = seconds_str.parse::<f64>() {
                    let duration = Duration::from_secs_f64(seconds);
                    let days = duration.as_secs() / 86400;
                    let hours = (duration.as_secs() % 86400) / 3600;
                    let minutes = (duration.as_secs() % 3600) / 60;
                    
                    if days > 0 {
                        return format!("{}d {}h {}m", days, hours, minutes);
                    } else if hours > 0 {
                        return format!("{}h {}m", hours, minutes);
                    } else {
                        return format!("{}m", minutes);
                    }
                }
            }
        }
        "Unknown".to_string()
    }
    
    fn with_memory(mut self) -> Self {
        if let Ok(content) = fs::read_to_string("/proc/meminfo") {
            let mut mem_total = 0u64;
            let mut mem_available = 0u64;
            
            for line in content.lines() {
                if line.starts_with("MemTotal:") {
                    if let Some(kb) = Self::parse_kb(line) {
                        mem_total = kb;
                    }
                } else if line.starts_with("MemAvailable:") {
                    if let Some(kb) = Self::parse_kb(line) {
                        mem_available = kb;
                    }
                }
            }
            
            if mem_total > 0 {
                let mem_used = mem_total - mem_available;
                self.memory_total = mem_total / 1024; // MB
                self.memory_used = mem_used / 1024; // MB
                self.memory_percent = (mem_used as f32 / mem_total as f32) * 100.0;
            }
        }
        
        self
    }
    
    fn parse_kb(line: &str) -> Option<u64> {
        line.split_whitespace()
            .nth(1)
            .and_then(|s| s.parse::<u64>().ok())
    }
}

impl std::fmt::Display for SystemInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        writeln!(f, "System Information:")?;
        writeln!(f, "  OS: {}", self.os_name)?;
        writeln!(f, "  Kernel: {}", self.kernel)?;
        writeln!(f, "  Hostname: {}", self.hostname)?;
        writeln!(f, "  Uptime: {}", self.uptime)?;
        
        if self.memory_total > 0 {
            writeln!(
                f,
                "  Memory: {}MB / {}MB ({:.1}%)",
                self.memory_used,
                self.memory_total,
                self.memory_percent
            )?;
        }
        
        Ok(())
    }
}
