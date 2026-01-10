{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.dcf-tray;
  
  pyEnv = pkgs.python3.withPackages (ps: with ps; [ 
    pygobject3 
    psutil 
    requests
  ]);
  
  # DeMoD Color Palette
  demodColors = {
    cyan = "#00D4AA";
    cyanDim = "#00A888";
    red = "#FF6B6B";
    yellow = "#FFE66D";
    dark = "#1A1A2E";
    surface = "#16213E";
    text = "#EAEAEA";
  };
  
  dcfTrayPkg = pkgs.stdenv.mkDerivation {
    pname = "dcf-tray";
    version = "2.1-demod";
    
    nativeBuildInputs = [ pkgs.wrapGAppsHook3 pkgs.gobject-introspection ];
    buildInputs = [ pkgs.gtk3 pkgs.libappindicator-gtk3 pyEnv ];

    dontUnpack = true;

    installPhase = ''
      mkdir -p $out/bin $out/share/icons/dcf
      
      # DeMoD Online Icon (Cyan)
      cat > $out/share/icons/dcf/on.svg << 'ICON_ON'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <defs>
    <linearGradient id="grad1" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#00D4AA;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#4ECDC4;stop-opacity:1" />
    </linearGradient>
  </defs>
  <circle cx="24" cy="24" r="20" fill="url(#grad1)"/>
  <path d="M16 24l6 6 10-12" stroke="#1A1A2E" stroke-width="3" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="24" cy="24" r="22" stroke="#00D4AA" stroke-width="2" fill="none" opacity="0.5"/>
</svg>
ICON_ON
      
      # DeMoD Offline Icon (Gray)
      cat > $out/share/icons/dcf/off.svg << 'ICON_OFF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <circle cx="24" cy="24" r="20" fill="#4A4A6A"/>
  <path d="M18 18l12 12M30 18l-12 12" stroke="#1A1A2E" stroke-width="3" fill="none" stroke-linecap="round"/>
  <circle cx="24" cy="24" r="22" stroke="#4A4A6A" stroke-width="2" fill="none" opacity="0.3"/>
</svg>
ICON_OFF

      # DeMoD Partial Icon (Yellow)
      cat > $out/share/icons/dcf/partial.svg << 'ICON_PARTIAL'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <circle cx="24" cy="24" r="20" fill="#FFE66D"/>
  <path d="M24 14v12M24 30v4" stroke="#1A1A2E" stroke-width="3" fill="none" stroke-linecap="round"/>
  <circle cx="24" cy="24" r="22" stroke="#FFE66D" stroke-width="2" fill="none" opacity="0.5"/>
</svg>
ICON_PARTIAL
      
      cat > $out/bin/dcf-tray << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
DeMoD Compute Fabric Controller
System Tray Application
"""

import os
import signal
import subprocess
import threading
import gi

gi.require_version('Gtk', '3.0')
gi.require_version('AppIndicator3', '0.1')
from gi.repository import Gtk, AppIndicator3, GLib, GdkPixbuf, Gdk

APP_ID = "dcf-demod-control"
ID_SERVICE = "docker-dcf-id.service"
NODE_SERVICE = "docker-dcf-sdk.service"

# Icon paths
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
ICON_DIRS = [
    os.path.expanduser("~/dcf-icons"),
    os.path.join(SCRIPT_DIR, "../share/icons/dcf"),
    "/run/current-system/sw/share/icons/dcf",
]

def find_icon(name):
    for d in ICON_DIRS:
        path = os.path.join(d, f"{name}.svg")
        if os.path.exists(path):
            return path
    return "network-server-symbolic"

# DeMoD Colors
COLORS = {
    'cyan': '#00D4AA',
    'red': '#FF6B6B',
    'yellow': '#FFE66D',
    'dark': '#1A1A2E',
    'text': '#EAEAEA',
}


class ServiceStatus:
    def __init__(self):
        self.identity = False
        self.node = False
        self.ollama = False
    
    def refresh(self):
        self.identity = self._check("dcf-id")
        self.node = self._check("dcf-sdk")
        self.ollama = self._check("ollama")
    
    @staticmethod
    def _check(container):
        try:
            result = subprocess.run(
                ["docker", "ps", "--format", "{{.Names}}"],
                capture_output=True, text=True, timeout=5
            )
            return container in result.stdout.split()
        except:
            return False
    
    @property
    def any_dcf(self):
        return self.identity or self.node
    
    @property
    def all_dcf(self):
        return self.identity and self.node


class ControlWindow(Gtk.Window):
    def __init__(self, tray):
        Gtk.Window.__init__(self, title="DeMoD Compute Fabric")
        self.tray = tray
        
        # Window setup
        self.set_border_width(0)
        self.set_default_size(420, 380)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)
        
        # Apply DeMoD theme
        self._apply_css()
        
        # Main container
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(main_box)
        
        # Header
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        header.set_name("header")
        header.set_margin_top(20)
        header.set_margin_bottom(20)
        header.set_margin_start(20)
        header.set_margin_end(20)
        
        self.status_icon = Gtk.Image()
        header.pack_start(self.status_icon, False, False, 0)
        
        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        title = Gtk.Label()
        title.set_markup("<span size='large' weight='bold'>DeMoD Compute Fabric</span>")
        title.set_halign(Gtk.Align.START)
        self.status_label = Gtk.Label()
        self.status_label.set_halign(Gtk.Align.START)
        title_box.pack_start(title, False, False, 0)
        title_box.pack_start(self.status_label, False, False, 0)
        header.pack_start(title_box, True, True, 0)
        
        main_box.pack_start(header, False, False, 0)
        
        # Service buttons
        services_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        services_box.set_margin_start(20)
        services_box.set_margin_end(20)
        services_box.set_margin_bottom(20)
        
        # Identity Service
        self.id_btn = self._create_service_button(
            "Identity Service", 
            "Authentication & Billing",
            self._toggle_identity
        )
        services_box.pack_start(self.id_btn, False, False, 0)
        
        # Node Service
        self.node_btn = self._create_service_button(
            "Community Node",
            "Network Mesh Router", 
            self._toggle_node
        )
        services_box.pack_start(self.node_btn, False, False, 0)
        
        # Ollama
        self.ollama_btn = self._create_service_button(
            "Ollama AI",
            "Local LLM Inference",
            self._toggle_ollama
        )
        services_box.pack_start(self.ollama_btn, False, False, 0)
        
        main_box.pack_start(services_box, True, True, 0)
        
        # Footer
        footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        footer.set_margin_start(20)
        footer.set_margin_end(20)
        footer.set_margin_bottom(20)
        
        refresh_btn = Gtk.Button(label="Refresh")
        refresh_btn.connect("clicked", lambda w: self.update_ui())
        footer.pack_start(refresh_btn, True, True, 0)
        
        logs_btn = Gtk.Button(label="View Logs")
        logs_btn.connect("clicked", self._open_logs)
        footer.pack_start(logs_btn, True, True, 0)
        
        main_box.pack_start(footer, False, False, 0)
        
        self.connect("delete-event", self._hide)
    
    def _apply_css(self):
        css = b'''
        window {
            background-color: #1A1A2E;
        }
        #header {
            background-color: #16213E;
            border-radius: 8px;
        }
        label {
            color: #EAEAEA;
        }
        button {
            background: #16213E;
            border: 1px solid #4A4A6A;
            border-radius: 8px;
            padding: 12px;
            color: #EAEAEA;
        }
        button:hover {
            background: #00D4AA30;
            border-color: #00D4AA;
        }
        button.running {
            border-color: #00D4AA;
        }
        button.stopped {
            border-color: #4A4A6A;
        }
        '''
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
    
    def _create_service_button(self, title, desc, callback):
        btn = Gtk.Button()
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        
        indicator = Gtk.DrawingArea()
        indicator.set_size_request(12, 12)
        indicator.set_name(f"indicator-{title.lower().replace(' ', '-')}")
        box.pack_start(indicator, False, False, 0)
        
        text_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        name = Gtk.Label()
        name.set_markup(f"<b>{title}</b>")
        name.set_halign(Gtk.Align.START)
        description = Gtk.Label(label=desc)
        description.set_halign(Gtk.Align.START)
        description.set_opacity(0.7)
        text_box.pack_start(name, False, False, 0)
        text_box.pack_start(description, False, False, 0)
        box.pack_start(text_box, True, True, 0)
        
        status = Gtk.Label()
        status.set_name(f"status-{title.lower().replace(' ', '-')}")
        box.pack_end(status, False, False, 0)
        
        btn.add(box)
        btn.connect("clicked", callback)
        return btn
    
    def _toggle_identity(self, widget):
        self._toggle_service(ID_SERVICE, self.tray.status.identity)
    
    def _toggle_node(self, widget):
        self._toggle_service(NODE_SERVICE, self.tray.status.node)
    
    def _toggle_ollama(self, widget):
        if self.tray.status.ollama:
            threading.Thread(target=lambda: subprocess.run(
                ["docker", "stop", "ollama"], timeout=30
            ), daemon=True).start()
        else:
            threading.Thread(target=lambda: subprocess.run(
                ["docker", "start", "ollama"], timeout=30
            ), daemon=True).start()
        GLib.timeout_add(2000, self._delayed_refresh)
    
    def _toggle_service(self, service, is_running):
        cmd = "stop" if is_running else "start"
        threading.Thread(target=lambda: subprocess.run(
            ["sudo", "-n", "systemctl", cmd, service], timeout=30
        ), daemon=True).start()
        GLib.timeout_add(2000, self._delayed_refresh)
    
    def _delayed_refresh(self):
        self.tray.update_state()
        return False
    
    def _open_logs(self, widget):
        subprocess.Popen(["kitty", "-e", "bash", "-c", 
            "docker logs -f dcf-sdk & docker logs -f dcf-id & wait"])
    
    def _hide(self, widget, event):
        self.hide()
        return True
    
    def show_window(self):
        self.update_ui()
        self.show_all()
        self.present()
    
    def update_ui(self):
        status = self.tray.status
        
        # Update header icon
        if status.all_dcf:
            icon_path = find_icon("on")
            self.status_label.set_markup(f"<span color='{COLORS['cyan']}'>All Systems Online</span>")
        elif status.any_dcf:
            icon_path = find_icon("partial")
            self.status_label.set_markup(f"<span color='{COLORS['yellow']}'>Partial Online</span>")
        else:
            icon_path = find_icon("off")
            self.status_label.set_markup(f"<span color='{COLORS['text']}' alpha='50%'>All Systems Offline</span>")
        
        if os.path.exists(icon_path):
            try:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(icon_path, 48, 48, True)
                self.status_icon.set_from_pixbuf(pixbuf)
            except:
                pass


class DCFTray:
    def __init__(self):
        self.status = ServiceStatus()
        
        self.indicator = AppIndicator3.Indicator.new(
            APP_ID, 
            find_icon("off"),
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        
        self.window = ControlWindow(self)
        self._build_menu()
        
        self.update_state()
        GLib.timeout_add(5000, self.update_state)
    
    def _build_menu(self):
        menu = Gtk.Menu()
        
        item_open = Gtk.MenuItem(label="Open DeMoD Control")
        item_open.connect("activate", lambda _: self.window.show_window())
        menu.append(item_open)
        
        menu.append(Gtk.SeparatorMenuItem())
        
        self.item_id = Gtk.MenuItem(label="Identity: Checking...")
        self.item_id.connect("activate", lambda _: self._quick_toggle(ID_SERVICE, self.status.identity))
        menu.append(self.item_id)
        
        self.item_node = Gtk.MenuItem(label="Node: Checking...")
        self.item_node.connect("activate", lambda _: self._quick_toggle(NODE_SERVICE, self.status.node))
        menu.append(self.item_node)
        
        menu.append(Gtk.SeparatorMenuItem())
        
        item_quit = Gtk.MenuItem(label="Quit")
        item_quit.connect("activate", lambda _: Gtk.main_quit())
        menu.append(item_quit)
        
        menu.show_all()
        self.indicator.set_menu(menu)
    
    def _quick_toggle(self, service, is_running):
        cmd = "stop" if is_running else "start"
        threading.Thread(target=lambda: subprocess.run(
            ["sudo", "-n", "systemctl", cmd, service], timeout=30
        ), daemon=True).start()
        GLib.timeout_add(2000, self.update_state)
    
    def update_state(self):
        self.status.refresh()
        
        # Update tray icon
        if self.status.all_dcf:
            self.indicator.set_icon_full(find_icon("on"), "DCF Online")
        elif self.status.any_dcf:
            self.indicator.set_icon_full(find_icon("partial"), "DCF Partial")
        else:
            self.indicator.set_icon_full(find_icon("off"), "DCF Offline")
        
        # Update menu items
        self.item_id.set_label(f"Identity: {'Stop' if self.status.identity else 'Start'}")
        self.item_node.set_label(f"Node: {'Stop' if self.status.node else 'Start'}")
        
        if self.window.is_visible():
            self.window.update_ui()
        
        return True


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    DCFTray()
    Gtk.main()
PYTHON_SCRIPT
      chmod +x $out/bin/dcf-tray
    '';
  };

in {
  options.services.dcf-tray = {
    enable = mkEnableOption "DeMoD Compute Fabric Tray Controller";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ dcfTrayPkg ];

    # Passwordless sudo for DCF service control
    security.sudo.extraRules = [
      {
        groups = [ "wheel" ];
        commands = [
          { command = "/run/current-system/sw/bin/systemctl start docker-dcf-id.service"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/systemctl stop docker-dcf-id.service"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/systemctl restart docker-dcf-id.service"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/systemctl start docker-dcf-sdk.service"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/systemctl stop docker-dcf-sdk.service"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/systemctl restart docker-dcf-sdk.service"; options = [ "NOPASSWD" ]; }
        ];
      }
    ];

    # XDG Autostart entry
    environment.etc."xdg/autostart/dcf-tray.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=DeMoD Control
      Comment=DeMoD Compute Fabric Service Controller
      Exec=${dcfTrayPkg}/bin/dcf-tray
      Icon=network-server-symbolic
      Terminal=false
      Categories=System;Utility;
      X-GNOME-Autostart-enabled=true
      X-KDE-autostart-after=panel
      StartupNotify=false
    '';
  };
}
