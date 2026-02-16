# NixOS User Greeting Module with Interactive TUI

A customizable NixOS flake module that displays a welcome greeting for new and existing users, featuring both a quick text greeting and a **full interactive TUI** (Terminal User Interface), similar to CachyOS and other modern Linux distributions.

## ✨ Features

### Text Greeting Mode
- 🎨 **Customizable ASCII Art Banner** - Display your own ASCII art or use the default
- 💬 **Welcome Messages** - Personalized greeting messages
- 📊 **System Information** - Show OS version, kernel, hostname, and uptime
- 🔗 **Quick Links** - Display helpful links and resources
- 💡 **Random Tips** - Show helpful tips on each login
- 🎯 **Multiple Shells** - Support for bash, zsh, and fish

### Interactive TUI Mode (NEW!)
- 🖥️ **Full Terminal UI** - Beautiful, interactive terminal interface built with Textual
- 📈 **Live System Stats** - Real-time system information including memory usage
- 🗂️ **Organized Panels** - System info, links, tips, and package search in organized columns
- ⌨️ **Keyboard Navigation** - Navigate with keyboard shortcuts
- 🎨 **Modern Design** - Colorful, readable interface with data tables
- 🔄 **Refreshable** - Update information on demand
- 📦 **Package Search Help** - Quick reference for NixOS package commands

## Installation

### 1. Add to your flake inputs

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    greeting.url = "github:yourusername/nixos-greeting";
  };
}
```

### 2. Import the module

```nix
outputs = { self, nixpkgs, greeting }: {
  nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      greeting.nixosModules.greeting
      ./configuration.nix
    ];
  };
};
```

### 3. Enable and configure in your configuration.nix

```nix
{
  services.userGreeting = {
    enable = true;
    welcomeMessage = "Welcome to NixOS! 🚀";
    showSystemInfo = true;
  };
}
```

## Configuration Options

### Display Modes

You can choose between three display modes:

1. **Text Greeting Only** (default) - Quick text-based greeting
2. **Text Greeting with TUI Launcher** - Show text, then offer to launch TUI
3. **Direct TUI Launch** - Launch interactive TUI immediately

### TUI Mode Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `tui.enable` | bool | `true` | Enable TUI application |
| `tui.showLauncher` | bool | `false` | Show "press any key for TUI" prompt after text greeting |
| `tui.launchOnStartup` | bool | `false` | Launch TUI directly, skip text greeting |

**Example: Launch TUI directly on login**
```nix
services.userGreeting = {
  enable = true;
  tui.enable = true;
  tui.launchOnStartup = true;  # Skip text, go straight to TUI
};
```

**Example: Show text with TUI launcher**
```nix
services.userGreeting = {
  enable = true;
  tui.enable = true;
  tui.showLauncher = true;  # Show "press any key for TUI" prompt
};
```

**Example: Text only (no TUI)**
```nix
services.userGreeting = {
  enable = true;
  tui.enable = false;  # Disable TUI completely
};
```

### Basic Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the greeting module |
| `showHeader` | bool | `true` | Show ASCII art header |
| `welcomeMessage` | string | `"Welcome to NixOS! 🚀"` | Custom welcome message |
| `showSystemInfo` | bool | `true` | Display system information |
| `showOnLogin` | bool | `true` | Show greeting on shell login |
| `showOnMotd` | bool | `false` | Show in MOTD |

### Advanced Options

#### Custom ASCII Art

```nix
services.userGreeting.asciiArt = ''
  ╔════════════════════════╗
  ║  Your Custom Banner!   ║
  ╚════════════════════════╝
'';
```

#### Custom Links

```nix
services.userGreeting.customLinks = [
  { name = "Documentation"; url = "https://nixos.org/manual/"; }
  { name = "Your Project"; url = "https://example.com"; }
  { name = "Support"; url = "https://discourse.nixos.org/"; }
];
```

#### Custom Tips

```nix
services.userGreeting.tips = [
  "Run 'nixos-rebuild switch' to apply changes"
  "Use 'nix-shell -p package' for temporary packages"
  "Check 'man configuration.nix' for help"
];
```

#### Custom Content

Add your own bash script content:

```nix
services.userGreeting.customContent = ''
  echo -e "\033[1;35mHappy coding! 💻\033[0m"
  
  # Check if updates are available
  if command -v nixos-version >/dev/null 2>&1; then
    echo "Current NixOS version: $(nixos-version)"
  fi
'';
```

## Example Configurations

### Minimal Setup

```nix
{
  services.userGreeting = {
    enable = true;
  };
}
```

### Full Customization

```nix
{
  services.userGreeting = {
    enable = true;
    showHeader = true;
    
    asciiArt = ''
      ██████╗ ███████╗██╗   ██╗
      ██╔══██╗██╔════╝██║   ██║
      ██║  ██║███████╗██║   ██║
      ██║  ██║╚════██║╚██╗ ██╔╝
      ██████╔╝███████║ ╚████╔╝ 
      ╚═════╝ ╚══════╝  ╚═══╝  
    '';
    
    welcomeMessage = "Welcome to DSP Dev Environment! 🎧";
    showSystemInfo = true;
    
    customLinks = [
      { name = "Internal Docs"; url = "https://docs.yourcompany.com"; }
      { name = "JIRA"; url = "https://jira.yourcompany.com"; }
      { name = "GitLab"; url = "https://gitlab.yourcompany.com"; }
    ];
    
    tips = [
      "Remember to commit your changes before EOD"
      "Run tests before pushing: nix flake check"
      "Use 'nix develop' for development shells"
      "Check Slack for daily standup updates"
    ];
    
    customContent = ''
      # Show if there are any system updates
      echo -e "\033[1;33m📦 Checking for updates...\033[0m"
      
      # Add your custom checks here
      if [ -d "$HOME/projects" ]; then
        PROJECT_COUNT=$(find "$HOME/projects" -maxdepth 1 -type d | wc -l)
        echo -e "Active projects: $((PROJECT_COUNT - 1))"
      fi
    '';
  };
}
```

### Company/Organization Setup

```nix
{
  services.userGreeting = {
    enable = true;
    
    asciiArt = ''
      ╔══════════════════════════════════╗
      ║   ACME Corp Development System   ║
      ║      Build. Test. Deploy.        ║
      ╚══════════════════════════════════╝
    '';
    
    welcomeMessage = "Welcome, Developer! Let's build something amazing.";
    
    customLinks = [
      { name = "Company Wiki"; url = "https://wiki.acme.corp"; }
      { name = "Engineering Docs"; url = "https://docs.acme.corp/engineering"; }
      { name = "On-Call Schedule"; url = "https://oncall.acme.corp"; }
    ];
    
    tips = [
      "New to NixOS? Check out our onboarding guide"
      "Need help? Ping #dev-support on Slack"
      "Weekly all-hands every Friday at 2pm"
      "Remember to update your status daily"
    ];
  };
}
```

## Manual Invocation

The greeting script is installed as a system package and can be run manually:

```bash
# Show text greeting
show-greeting

# Launch TUI directly
welcome-tui
```

## TUI Keyboard Shortcuts

When using the interactive TUI:

| Key | Action |
|-----|--------|
| `q` | Quit TUI |
| `r` | Refresh information |
| `Tab` / `Shift+Tab` | Navigate between elements |
| `↑` / `↓` | Scroll in tables |
| `Ctrl+C` | Copy selected URL (when in links table) |

## TUI Screenshot

```
┌─────────────────────────────── NixOS Welcome ───────────────────────────────┐
│                                                                              │
│     .d88b. 8    888 .d88b     db    888b. .d88b 8   8 Yb  dP                │
│     8P  Y8 8     8  8P www   dPYb   8  .8 8P    8www8  YbdP                 │
│     8b  d8 8     8  8b  d8  dPwwYb  8wwK' 8b    8   8   YP                  │
│     `Y88P' 8888 888 `Y88P' dP    Yb 8  Yb `Y88P 8   8   88                  │
│                                                                              │
│              Welcome to Your NixOS System! 🚀                                │
│ ──────────────────────────────────────────────────────────────────────────  │
│                                                                              │
│  System Information          │  Quick Links                                 │
│  ┌──────────┬───────────────┐│  ┌──────────────┬───────────────────────┐  │
│  │ Property │ Value         ││  │ Resource     │ URL                   │  │
│  │ OS       │ NixOS 24.05   ││  │ 📚 Manual    │ nixos.org/manual/...  │  │
│  │ Kernel   │ 6.6.8         ││  │ 📖 Wiki      │ nixos.wiki/           │  │
│  │ Hostname │ nixos-desktop ││  │ 🔍 Packages  │ search.nixos.org/...  │  │
│  │ Uptime   │ 2h 34m        ││  │ 🔧 Options   │ search.nixos.org/...  │  │
│  │ Memory   │ 4.2/16GB (26%)││  └──────────────┴───────────────────────┘  │
│  └──────────┴───────────────┘│                                             │
│                                                                              │
│  💡 Tip: Run 'nixos-rebuild switch' to apply configuration changes          │
│  💡 Tip: Use 'nix develop' for development environments                     │
│  💡 Tip: Check 'man configuration.nix' for all options                      │
│                                                                              │
│ ──────────────────────────────────────────────────────────────────────────  │
│  Press 'q' to quit, 'r' to refresh                                          │
└──────────────────────────────────────────────────────────────────────────── │
 q Quit  r Refresh  s System Info  l Links  t Tips  p Packages
```

## Manual Invocation (Legacy)

## Shell Support

The module automatically integrates with:
- **Bash** - via `programs.bash.interactiveShellInit`
- **Zsh** - via `programs.zsh.interactiveShellInit`
- **Fish** - via `programs.fish.interactiveShellInit`

The greeting shows once per session (not on every new terminal).

## MOTD Integration

To show the greeting as MOTD (e.g., on SSH login):

```nix
{
  services.userGreeting = {
    enable = true;
    showOnLogin = false;  # Disable shell integration
    showOnMotd = true;     # Enable MOTD
  };
}
```

## Disabling for Specific Users

Users can disable the greeting by adding to their shell profile:

```bash
export GREETING_SHOWN=1
```

## Development

### Local Testing

```bash
# Clone the repository
git clone https://github.com/yourusername/nixos-greeting
cd nixos-greeting

# Test the module
nix flake check

# Build locally
nix build
```

### File Structure

```
.
├── flake.nix                    # Flake definition
├── modules/
│   └── greeting.nix             # Main module
├── example-configuration.nix     # Example usage
└── README.md                    # This file
```

## Tips for ASCII Art

Generate ASCII art using:
- [patorjk.com](https://patorjk.com/software/taag/)
- [ASCII Art Generator](https://www.asciiart.eu/)
- `figlet` or `toilet` commands

Make sure to escape special characters in nix strings:
- Use single quotes `''` for multi-line strings
- Double `$` for literal dollar signs: `$$`

## License

MIT License - feel free to customize and distribute!

## Contributing

PRs welcome! Some ideas for contributions:
- Additional shell support (nushell, elvish, etc.)
- Weather information integration
- Package update notifications
- Calendar integration
- Resource usage warnings
- Custom themes

## Credits

Inspired by CachyOS and other modern Linux distributions that provide welcoming user experiences.
