{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.dcf-tray;
  
  # Python Environment
  pyEnv = pkgs.python3.withPackages (ps: with ps; [ pygobject3 psutil ]);
  
  # The Package Derivation
  dcfTrayPkg = pkgs.stdenv.mkDerivation {
    pname = "dcf-tray";
    version = "1.0";
    
    nativeBuildInputs = [ pkgs.wrapGAppsHook3 pkgs.gobject-introspection ];
    buildInputs = [ pkgs.gtk3 pkgs.libappindicator-gtk3 pyEnv ];

    dontUnpack = true;

    installPhase = ''
      mkdir -p $out/bin
      cat > $out/bin/dcf-tray <<EOF
      #!${pyEnv}/bin/python3
      import os
      import signal
      import subprocess
      import threading
      import gi
      
      gi.require_version('Gtk', '3.0')
      gi.require_version('AppIndicator3', '0.1')
      from gi.repository import Gtk, AppIndicator3, GLib, GdkPixbuf

      APP_ID = "dcf-identity-control"
      SERVICE = "docker-dcf-id.service"
      HOME = os.path.expanduser("~")
      ON_ICON_PATH = os.path.join(HOME, "dcf-icons/on.svg")
      OFF_ICON_PATH = os.path.join(HOME, "dcf-icons/off.svg")
      FALLBACK_ICON = "network-server-symbolic" 

      class ControlWindow(Gtk.Window):
          def __init__(self, tray_app):
              Gtk.Window.__init__(self, title="DCF Controller")
              self.tray_app = tray_app
              self.set_border_width(24)
              self.set_default_size(320, 250)
              self.set_resizable(False)
              self.set_position(Gtk.WindowPosition.CENTER)
              self.set_icon_name("preferences-system-network")
              
              vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
              self.add(vbox)

              self.image = Gtk.Image()
              vbox.pack_start(self.image, True, True, 0)

              self.status_label = Gtk.Label()
              self.status_label.set_use_markup(True)
              vbox.pack_start(self.status_label, False, False, 0)

              self.toggle_btn = Gtk.Button()
              self.toggle_btn.set_size_request(-1, 50) 
              self.toggle_btn.connect("clicked", self.on_btn_clicked)
              vbox.pack_start(self.toggle_btn, False, False, 0)

              self.connect("delete-event", self.hide_on_delete)
              self.update_ui_state()

          def hide_on_delete(self, widget, event):
              self.hide()
              return True

          def on_btn_clicked(self, widget):
              self.toggle_btn.set_sensitive(False)
              self.tray_app.toggle_service_thread(None)

          def update_ui_state(self):
              active = self.tray_app.is_active()
              icon_file = ON_ICON_PATH if active else OFF_ICON_PATH
              
              if os.path.exists(icon_file):
                  try:
                      pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(icon_file, 96, 96, True)
                      self.image.set_from_pixbuf(pixbuf)
                  except:
                      self.image.set_from_icon_name(FALLBACK_ICON, Gtk.IconSize.DIALOG)
              else:
                  self.image.set_from_icon_name(FALLBACK_ICON, Gtk.IconSize.DIALOG)

              context = self.toggle_btn.get_style_context()
              if active:
                  self.status_label.set_markup("<span size='large' weight='bold'>System Online</span>")
                  self.toggle_btn.set_label("Stop Service")
                  context.remove_class("suggested-action")
                  context.add_class("destructive-action") 
              else:
                  self.status_label.set_markup("<span size='large' color='gray'>System Offline</span>")
                  self.toggle_btn.set_label("Start Service")
                  context.remove_class("destructive-action")
                  context.add_class("suggested-action") 
              
              self.toggle_btn.set_sensitive(True)

      class DCFTray:
          def __init__(self):
              self.icon_on = ON_ICON_PATH if os.path.exists(ON_ICON_PATH) else FALLBACK_ICON
              self.icon_off = OFF_ICON_PATH if os.path.exists(OFF_ICON_PATH) else FALLBACK_ICON

              self.indicator = AppIndicator3.Indicator.new(
                  APP_ID, self.icon_off, AppIndicator3.IndicatorCategory.APPLICATION_STATUS
              )
              self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)

              self.window = ControlWindow(self)
              self.menu = Gtk.Menu()
              
              item_show = Gtk.MenuItem(label="Open Controls")
              item_show.connect("activate", self.show_window)
              self.menu.append(item_show)
              
              item_toggle = Gtk.MenuItem(label="Toggle Service")
              item_toggle.connect("activate", self.toggle_service_thread)
              self.menu.append(item_toggle)
              
              self.menu.append(Gtk.SeparatorMenuItem())
              
              item_quit = Gtk.MenuItem(label="Quit")
              item_quit.connect("activate", self.quit)
              self.menu.append(item_quit)
              
              self.menu.show_all()
              self.indicator.set_menu(self.menu)
              
              self.update_state()
              GLib.timeout_add(5000, self.update_state)

          def show_window(self, _):
              self.window.present()

          def is_active(self):
              try:
                  subprocess.check_call(["systemctl", "is-active", "--quiet", SERVICE])
                  return True
              except:
                  return False

          def update_state(self):
              active = self.is_active()
              icon = self.icon_on if active else self.icon_off
              self.indicator.set_icon(icon)
              self.menu.get_children()[1].set_label("Stop Service" if active else "Start Service")
              if self.window.is_visible():
                  self.window.update_ui_state()
              return True

          def toggle_service_thread(self, _):
              t = threading.Thread(target=self._run_toggle)
              t.daemon = True
              t.start()

          def _run_toggle(self):
              cmd = "stop" if self.is_active() else "start"
              try:
                  subprocess.run(["pkexec", "systemctl", cmd, SERVICE], check=True)
                  GLib.idle_add(self.update_state)
              except:
                  print("Action cancelled")
                  GLib.idle_add(self.window.update_ui_state)

          def quit(self, _):
              Gtk.main_quit()

      if __name__ == "__main__":
          signal.signal(signal.SIGINT, signal.SIG_DFL)
          DCFTray()
          Gtk.main()
      EOF
      chmod +x $out/bin/dcf-tray
    '';
  };

in {
  options.services.dcf-tray = {
    enable = mkEnableOption "DCF Identity Tray Controller";
  };

  config = mkIf cfg.enable {
    # 1. Install the package
    environment.systemPackages = [ dcfTrayPkg ];

    # 2. Add XDG Autostart Entry (Works on Plasma & Hyprland automatically)
    environment.etc."xdg/autostart/dcf-tray.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=DCF Tray
      Exec=${dcfTrayPkg}/bin/dcf-tray
      Icon=network-server-symbolic
      Terminal=false
      Categories=Utility;
      X-GNOME-Autostart-enabled=true
    '';
  };
}
