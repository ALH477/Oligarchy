use std::io::{self, Write};
use std::path::Path;
use image::{DynamicImage, GenericImageView};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ImageProtocol {
    Kitty,
    ITerm2,
    Sixel,
    HalfBlocks,
    None,
}

pub struct ImageDisplay {
    protocol: ImageProtocol,
}

impl ImageDisplay {
    pub fn detect() -> Self {
        let protocol = Self::detect_protocol();
        Self { protocol }
    }
    
    pub fn get_protocol(&self) -> ImageProtocol {
        self.protocol
    }
    
    fn detect_protocol() -> ImageProtocol {
        // Check environment variables
        if let Ok(term) = std::env::var("TERM") {
            // Check for Kitty
            if term.contains("kitty") || std::env::var("KITTY_WINDOW_ID").is_ok() {
                return ImageProtocol::Kitty;
            }
            
            // Check for iTerm2
            if let Ok(term_program) = std::env::var("TERM_PROGRAM") {
                if term_program == "iTerm.app" || term_program == "WezTerm" {
                    return ImageProtocol::ITerm2;
                }
            }
            
            // Check for foot (sixel)
            if term.contains("foot") {
                return ImageProtocol::Sixel;
            }
        }
        
        // Check for specific terminal programs
        if let Ok(term_program) = std::env::var("TERM_PROGRAM") {
            match term_program.as_str() {
                "iTerm.app" => return ImageProtocol::ITerm2,
                "WezTerm" => return ImageProtocol::ITerm2,
                "ghostty" => return ImageProtocol::Kitty,
                _ => {}
            }
        }
        
        // Check COLORTERM
        if let Ok(colorterm) = std::env::var("COLORTERM") {
            if colorterm.contains("truecolor") || colorterm.contains("24bit") {
                return ImageProtocol::HalfBlocks;
            }
        }
        
        ImageProtocol::None
    }
    
    pub fn display_image(&self, path: &Path, max_width: Option<u32>, max_height: Option<u32>) -> io::Result<()> {
        match self.protocol {
            ImageProtocol::Kitty => self.display_kitty(path, max_width, max_height),
            ImageProtocol::ITerm2 => self.display_iterm2(path, max_width, max_height),
            ImageProtocol::Sixel => self.display_sixel(path, max_width, max_height),
            ImageProtocol::HalfBlocks => self.display_halfblocks(path, max_width, max_height),
            ImageProtocol::None => Ok(()),
        }
    }
    
    fn display_kitty(&self, path: &Path, max_width: Option<u32>, max_height: Option<u32>) -> io::Result<()> {
        let img = self.load_and_resize_image(path, max_width, max_height)?;
        let (width, height) = img.dimensions();
        
        // Convert to RGBA
        let rgba = img.to_rgba8();
        let raw_data = rgba.as_raw();
        
        // Base64 encode
        let base64_data = base64::encode(raw_data);
        
        // Build Kitty graphics protocol escape sequence
        let mut stdout = io::stdout();
        
        // Transmit and display command
        let transmit_cmd = format!(
            "\x1b_Ga=T,f=32,s={},v={},m=1;{}",
            width,
            height,
            &base64_data[..base64_data.len().min(4096)]
        );
        
        write!(stdout, "{}", transmit_cmd)?;
        
        // If data is larger than 4096 bytes, send in chunks
        if base64_data.len() > 4096 {
            for chunk in base64_data[4096..].as_bytes().chunks(4096) {
                let chunk_str = std::str::from_utf8(chunk).unwrap_or("");
                write!(stdout, "\x1b_Gm=1;{}\x1b\\", chunk_str)?;
            }
        }
        
        write!(stdout, "\x1b\\")?;
        stdout.flush()
    }
    
    fn display_iterm2(&self, path: &Path, max_width: Option<u32>, max_height: Option<u32>) -> io::Result<()> {
        let img = self.load_and_resize_image(path, max_width, max_height)?;
        
        // Save to temporary PNG
        let mut temp_path = std::env::temp_dir();
        temp_path.push("greeting_temp.png");
        img.save(&temp_path).map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        
        // Read and base64 encode
        let data = std::fs::read(&temp_path)?;
        let base64_data = base64::encode(&data);
        
        // iTerm2 inline image protocol
        let mut stdout = io::stdout();
        let (width, height) = img.dimensions();
        
        write!(
            stdout,
            "\x1b]1337;File=inline=1;width={};height={}:{}",
            width / 2, // iTerm2 uses character cells, not pixels
            height / 4,
            base64_data
        )?;
        write!(stdout, "\x07")?; // BEL character
        
        // Clean up temp file
        let _ = std::fs::remove_file(&temp_path);
        
        stdout.flush()
    }
    
    fn display_sixel(&self, _path: &Path, _max_width: Option<u32>, _max_height: Option<u32>) -> io::Result<()> {
        // Sixel support is complex - for now, fall back to half-blocks
        // In a full implementation, you'd convert the image to sixel format
        eprintln!("Sixel support coming soon - using fallback");
        Ok(())
    }
    
    fn display_halfblocks(&self, path: &Path, max_width: Option<u32>, max_height: Option<u32>) -> io::Result<()> {
        let img = self.load_and_resize_image(path, max_width, max_height)?;
        let (width, height) = img.dimensions();
        
        // Convert to RGB
        let rgb = img.to_rgb8();
        
        let mut stdout = io::stdout();
        
        // Use half-block characters to approximate image
        // Upper half block: ▀ (U+2580)
        for y in (0..height).step_by(2) {
            for x in 0..width {
                let pixel_top = rgb.get_pixel(x, y);
                let pixel_bottom = if y + 1 < height {
                    *rgb.get_pixel(x, y + 1)
                } else {
                    image::Rgb([0, 0, 0])
                };
                
                // ANSI escape codes for colors
                let fg = format!("\x1b[38;2;{};{};{}m", pixel_top[0], pixel_top[1], pixel_top[2]);
                let bg = format!("\x1b[48;2;{};{};{}m", pixel_bottom[0], pixel_bottom[1], pixel_bottom[2]);
                
                write!(stdout, "{}{}▀\x1b[0m", fg, bg)?;
            }
            writeln!(stdout)?;
        }
        
        stdout.flush()
    }
    
    fn load_and_resize_image(&self, path: &Path, max_width: Option<u32>, max_height: Option<u32>) -> io::Result<DynamicImage> {
        let img = image::open(path)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        
        let (width, height) = img.dimensions();
        
        // Calculate new dimensions
        let mut new_width = width;
        let mut new_height = height;
        
        if let Some(max_w) = max_width {
            if width > max_w {
                new_width = max_w;
                new_height = (height * max_w) / width;
            }
        }
        
        if let Some(max_h) = max_height {
            if new_height > max_h {
                new_height = max_h;
                new_width = (new_width * max_h) / new_height;
            }
        }
        
        // For terminal display, limit size
        let term_width = Self::get_terminal_width().unwrap_or(80) as u32;
        if new_width > term_width {
            new_height = (new_height * term_width) / new_width;
            new_width = term_width;
        }
        
        if new_width != width || new_height != height {
            Ok(img.resize(new_width, new_height, image::imageops::FilterType::Lanczos3))
        } else {
            Ok(img)
        }
    }
    
    fn get_terminal_width() -> Option<u16> {
        use std::os::unix::io::AsRawFd;
        
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

// Base64 encoding helper
mod base64 {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    
    pub fn encode(input: &[u8]) -> String {
        let mut result = String::with_capacity((input.len() + 2) / 3 * 4);
        
        for chunk in input.chunks(3) {
            let buf = match chunk.len() {
                1 => [chunk[0], 0, 0],
                2 => [chunk[0], chunk[1], 0],
                3 => [chunk[0], chunk[1], chunk[2]],
                _ => unreachable!(),
            };
            
            let b = ((buf[0] as u32) << 16) | ((buf[1] as u32) << 8) | (buf[2] as u32);
            
            result.push(ALPHABET[((b >> 18) & 0x3F) as usize] as char);
            result.push(ALPHABET[((b >> 12) & 0x3F) as usize] as char);
            
            if chunk.len() > 1 {
                result.push(ALPHABET[((b >> 6) & 0x3F) as usize] as char);
            } else {
                result.push('=');
            }
            
            if chunk.len() > 2 {
                result.push(ALPHABET[(b & 0x3F) as usize] as char);
            } else {
                result.push('=');
            }
        }
        
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_base64_encode() {
        assert_eq!(base64::encode(b"Hello"), "SGVsbG8=");
        assert_eq!(base64::encode(b"Man"), "TWFu");
    }
}
