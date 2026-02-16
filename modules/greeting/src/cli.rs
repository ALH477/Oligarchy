use crate::config::{Config, LayoutMode};
use crate::image::ImageDisplay;
use crate::system_info::SystemInfo;
use std::io::{self, Write};
use std::path::Path;

pub struct Cli {
    config: Config,
    image_display: ImageDisplay,
    term_width: u16,
}

impl Cli {
    pub fn new(config: Config) -> Self {
        let image_display = ImageDisplay::detect();
        let term_width = Self::get_terminal_width().unwrap_or(80);
        
        Self {
            config,
            image_display,
            term_width,
        }
    }
    
    pub fn run(&self) -> io::Result<()> {
        let mut stdout = io::stdout();
        
        // Clear screen and hide cursor
        write!(stdout, "\x1b[2J\x1b[H")?;
        stdout.flush()?;
        
        // Display images first
        self.display_images()?;
        
        // Display header/ASCII art if no image shown or as fallback
        if self.should_show_ascii() {
            self.display_header()?;
        }
        
        // Welcome message
        if !self.config.welcome_message.is_empty() {
            writeln!(stdout, "\n{}", self.config.welcome_message)?;
        }
        
        // System info
        if self.config.show_system_info {
            let sys_info = SystemInfo::gather();
            writeln!(stdout, "\n{}", sys_info)?;
        }
        
        // Links
        if !self.config.custom_links.is_empty() {
            writeln!(stdout, "Quick Links:")?;
            for link in &self.config.custom_links {
                writeln!(stdout, "  • {}: {}", link.name, link.url)?;
            }
            writeln!(stdout)?;
        }
        
        // Tips
        if !self.config.tips.is_empty() {
            if let Some(tip) = self.get_random_tip() {
                writeln!(stdout, "💡 Tip: {}", tip)?;
                writeln!(stdout)?;
            }
        }
        
        stdout.flush()
    }
    
    fn display_images(&self) -> io::Result<()> {
        let protocol = self.image_display.get_protocol();
        
        // Don't try to display images if terminal doesn't support it
        if matches!(protocol, crate::image::ImageProtocol::None) && !self.config.fallback_to_ascii {
            return Ok(());
        }
        
        match self.config.layout {
            LayoutMode::Adaptive => {
                if self.term_width >= 80 && self.config.images.banner.enabled {
                    // Show banner for wide terminals
                    self.display_banner()?;
                } else if self.config.images.logo.enabled {
                    // Show logo for narrow terminals
                    self.display_logo()?;
                }
            }
            LayoutMode::BannerOnly => {
                self.display_banner()?;
            }
            LayoutMode::LogoOnly => {
                self.display_logo()?;
            }
            LayoutMode::Both => {
                self.display_banner()?;
                self.display_logo()?;
            }
            LayoutMode::AsciiOnly => {
                // Don't display images
            }
        }
        
        Ok(())
    }
    
    fn display_banner(&self) -> io::Result<()> {
        let banner_path = &self.config.images.banner.path;
        if !banner_path.exists() {
            return Ok(());
        }
        
        let max_height = self.config.images.banner.max_height;
        let max_width = (self.term_width as f32 * 0.9) as u32; // 90% of terminal width
        
        self.image_display.display_image(
            banner_path,
            Some(max_width),
            Some(max_height)
        )?;
        
        writeln!(io::stdout())?;
        Ok(())
    }
    
    fn display_logo(&self) -> io::Result<()> {
        let logo_path = &self.config.images.logo.path;
        if !logo_path.exists() {
            return Ok(());
        }
        
        let max_size = self.config.images.logo.max_size;
        
        self.image_display.display_image(
            logo_path,
            Some(max_size),
            Some(max_size)
        )?;
        
        writeln!(io::stdout())?;
        Ok(())
    }
    
    fn should_show_ascii(&self) -> bool {
        match self.config.layout {
            LayoutMode::AsciiOnly => true,
            _ => {
                let protocol = self.image_display.get_protocol();
                matches!(protocol, crate::image::ImageProtocol::None) || 
                    (!self.config.images.banner.enabled && !self.config.images.logo.enabled)
            }
        }
    }
    
    fn display_header(&self) -> io::Result<()> {
        let mut stdout = io::stdout();
        
        // ANSI cyan color
        write!(stdout, "\x1b[36m")?;
        
        for line in self.config.ascii_art.lines() {
            writeln!(stdout, "{}", line)?;
        }
        
        // Reset color
        write!(stdout, "\x1b[0m")?;
        stdout.flush()
    }
    
    fn get_random_tip(&self) -> Option<&String> {
        use std::time::{SystemTime, UNIX_EPOCH};
        
        if self.config.tips.is_empty() {
            return None;
        }
        
        let seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        
        let index = (seed % self.config.tips.len() as u64) as usize;
        self.config.tips.get(index)
    }
    
    fn get_terminal_width() -> Option<u16> {
        unsafe {
            let mut size: libc::winsize = std::mem::zeroed();
            if libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) == 0 {
                Some(size.ws_col)
            } else {
                None
            }
        }
    }
}
