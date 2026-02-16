#!/usr/bin/env python3
"""
Oligarchy NixOS Welcome TUI - Interactive terminal user interface for the War Machine
"""

from textual.app import App, ComposeResult
from textual.containers import Container, Horizontal, Vertical, VerticalScroll
from textual.widgets import Header, Footer, Static, Button, Label, DataTable, Tree
from textual.binding import Binding
from textual.screen import Screen
import subprocess
import platform
import socket
import os
import random
from datetime import datetime
from pathlib import Path


ASCII_ART = """.d88b. 8    888 .d88b     db    888b. .d88b 8   8 Yb  dP
8P  Y8 8     8  8P www   dPYb   8  .8 8P    8www8  YbdP
8b  d8 8     8  8b  d8  dPwwYb  8wwK' 8b    8   8   YP
`Y88P' 8888 888 `Y88P' dP    Yb 8  Yb `Y88P 8   8   88"""


class WelcomeBanner(Static):
    """Display the welcome banner with ASCII art"""
    
    def compose(self) -> ComposeResult:
        yield Static(ASCII_ART, id="ascii-art")
        yield Static("Welcome to Oligarchy NixOS — The Unstoppable War Machine", id="welcome-message")


class SystemInfo(Static):
    """Display system information"""
    
    def compose(self) -> ComposeResult:
        yield Label("[b cyan]System Information[/b cyan]")
        
        # Get system info
        try:
            with open('/etc/os-release') as f:
                os_info = dict(line.strip().split('=', 1) for line in f if '=' in line)
                os_name = os_info.get('PRETTY_NAME', 'Unknown').strip('"')
        except:
            os_name = "Unknown"
        
        kernel = platform.release()
        hostname = socket.gethostname()
        
        # Get uptime
        try:
            with open('/proc/uptime') as f:
                uptime_seconds = float(f.read().split()[0])
                days = int(uptime_seconds // 86400)
                hours = int((uptime_seconds % 86400) // 3600)
                minutes = int((uptime_seconds % 3600) // 60)
                if days > 0:
                    uptime = f"{days}d {hours}h {minutes}m"
                elif hours > 0:
                    uptime = f"{hours}h {minutes}m"
                else:
                    uptime = f"{minutes}m"
        except:
            uptime = "Unknown"
        
        # Get memory info
        try:
            with open('/proc/meminfo') as f:
                meminfo = dict((line.split()[0].rstrip(':'), int(line.split()[1])) 
                             for line in f.readlines() if len(line.split()) > 1)
                mem_total = meminfo.get('MemTotal', 0) // 1024  # MB
                mem_available = meminfo.get('MemAvailable', 0) // 1024  # MB
                mem_used = mem_total - mem_available
                mem_percent = (mem_used / mem_total * 100) if mem_total > 0 else 0
        except:
            mem_total = mem_used = mem_percent = 0
        
        info_table = DataTable(id="system-info-table")
        info_table.add_columns("Property", "Value")
        info_table.add_row("OS", os_name)
        info_table.add_row("Kernel", kernel)
        info_table.add_row("Hostname", hostname)
        info_table.add_row("Uptime", uptime)
        if mem_total > 0:
            info_table.add_row("Memory", f"{mem_used}MB / {mem_total}MB ({mem_percent:.1f}%)")
        info_table.add_row("Date/Time", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        
        yield info_table


class QuickLinks(Static):
    """Display quick links"""
    
    DEFAULT_LINKS = [
        ("📖 Oligarchy Docs", "https://github.com/ALH477/DeMoD-Framework16-NIXOS"),
        ("📚 NixOS Manual", "https://nixos.org/manual/nixos/stable/"),
        ("🔍 Search Packages", "https://search.nixos.org/packages"),
        ("🔧 Search Options", "https://search.nixos.org/options"),
        ("💬 NixOS Discourse", "https://discourse.nixos.org/"),
    ]
    
    def __init__(self, links=None):
        super().__init__()
        self.links = links or self.DEFAULT_LINKS
    
    def compose(self) -> ComposeResult:
        yield Label("[b cyan]Quick Links[/b cyan]")
        
        links_table = DataTable(id="links-table")
        links_table.add_columns("Resource", "URL")
        for name, url in self.links:
            links_table.add_row(name, url)
        
        yield links_table
        yield Label("\n[dim]Press Ctrl+C to copy selected URL[/dim]")


class TipsPanel(Static):
    """Display helpful tips"""
    
    DEFAULT_TIPS = [
        "💡 Run 'sudo nixos-rebuild switch --flake .' to apply config changes",
        "💡 Use 'ai-stack start' to launch the AI stack (Ollama + ROCm)",
        "💡 Use 'dcf-control' to manage the DeMoD Compute Fabric",
        "💡 Use 'docker-start' to start DCF services",
        "💡 Theme toggles: Super+F1-F7 for animations, blur, gaps, opacity, borders, rounding, colors",
        "💡 Use 'Super+Escape' for the power menu (wlogout)",
        "💡 Use 'Super+L' to lock the screen (hyprlock)",
        "💡 Check 'thermal-status' for Framework 16 temperature monitoring",
        "💡 Use 'nix flake update' to pull latest flake inputs",
        "💡 Run 'nix-collect-garbage -d' to clean old generations",
        "💡 Use 'net-status', 'net-fix', 'net-wifi' for network management",
        "💡 Use 'theme-switcher.sh' to cycle between DeMoD color palettes",
    ]
    
    def __init__(self, tips=None):
        super().__init__()
        self.tips = tips or self.DEFAULT_TIPS
    
    def compose(self) -> ComposeResult:
        yield Label("[b cyan]Helpful Tips[/b cyan]")
        
        # Show 3 random tips
        selected_tips = random.sample(self.tips, min(3, len(self.tips)))
        for tip in selected_tips:
            yield Label(f"  {tip}")


class PackageSearch(Static):
    """Quick package search widget"""
    
    def compose(self) -> ComposeResult:
        yield Label("[b cyan]Quick Package Search[/b cyan]")
        yield Label("Search NixOS packages from the command line:")
        yield Label("  [green]nix-env -qa <name>[/green]  - Search all packages")
        yield Label("  [green]nix search nixpkgs <name>[/green]  - Search with flakes")
        yield Label("  [green]nix-shell -p <name>[/green]  - Try a package temporarily")


class MainScreen(Screen):
    """Main screen with all panels"""
    
    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("s", "system_info", "System Info"),
        Binding("l", "links", "Links"),
        Binding("t", "tips", "Tips"),
        ("p", "packages", "Packages"),
    ]
    
    def __init__(self, config=None):
        super().__init__()
        self.config = config or {}
    
    def compose(self) -> ComposeResult:
        yield Header()
        
        with VerticalScroll():
            yield WelcomeBanner()
            yield Static("─" * 80, classes="divider")
            
            with Horizontal():
                with Vertical(classes="column"):
                    yield SystemInfo()
                    yield Static("─" * 38, classes="divider")
                    yield PackageSearch()
                
                with Vertical(classes="column"):
                    links = self.config.get('links', QuickLinks.DEFAULT_LINKS)
                    yield QuickLinks(links)
            
            yield Static("─" * 80, classes="divider")
            
            tips = self.config.get('tips', TipsPanel.DEFAULT_TIPS)
            yield TipsPanel(tips)
            
            yield Static("─" * 80, classes="divider")
            yield Static("\n[dim]Press 'q' to quit, 'r' to refresh[/dim]\n", classes="footer-text")
        
        yield Footer()
    
    def action_refresh(self) -> None:
        """Refresh the screen"""
        self.app.refresh()
    
    def action_quit(self) -> None:
        """Quit the application"""
        self.app.exit()


class WelcomeApp(App):
    """NixOS Welcome TUI Application"""
    
    CSS = """
    Screen {
        background: $surface;
    }
    
    #ascii-art {
        color: $accent;
        text-style: bold;
        content-align: center middle;
        padding: 1;
    }
    
    #welcome-message {
        color: $success;
        text-style: bold;
        content-align: center middle;
        padding: 0 1 1 1;
    }
    
    .divider {
        color: $primary-lighten-2;
        padding: 0 1;
    }
    
    .column {
        width: 1fr;
        padding: 1 2;
    }
    
    DataTable {
        height: auto;
        margin: 1 0;
    }
    
    Label {
        margin: 0 0 1 0;
    }
    
    .footer-text {
        content-align: center middle;
    }
    
    #system-info-table {
        height: auto;
    }
    
    #links-table {
        height: auto;
    }
    """
    
    TITLE = "NixOS Welcome"
    
    def __init__(self, config_path=None):
        super().__init__()
        self.config = self.load_config(config_path)
    
    def load_config(self, config_path):
        """Load configuration from file if it exists"""
        config = {}
        
        if config_path and Path(config_path).exists():
            try:
                import json
                with open(config_path) as f:
                    config = json.load(f)
            except:
                pass
        
        return config
    
    def on_mount(self) -> None:
        """Initialize the app"""
        self.push_screen(MainScreen(self.config))


def main():
    """Main entry point"""
    import sys
    
    config_path = None
    if len(sys.argv) > 1:
        config_path = sys.argv[1]
    
    app = WelcomeApp(config_path)
    app.run()


if __name__ == "__main__":
    main()
