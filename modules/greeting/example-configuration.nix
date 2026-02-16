# Example NixOS configuration using the greeting module

{
  description = "Example NixOS configuration with greeting TUI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    greeting.url = "github:yourusername/nixos-greeting";  # Update with your repo URL
  };

  outputs = { self, nixpkgs, greeting }: {
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        greeting.nixosModules.greeting
        {
          # Enable the greeting module
          services.userGreeting = {
            enable = true;
            
            # TUI Configuration
            tui = {
              enable = true;              # Enable interactive TUI
              launchOnStartup = true;     # Launch TUI immediately on login
              # OR
              # showLauncher = true;      # Show "press any key" prompt after text greeting
            };
            
            # Customize the welcome message
            welcomeMessage = "Welcome to Your Custom NixOS! 🎉";
            
            # Custom ASCII art (this appears in both text and TUI modes)
            asciiArt = ''
    .d88b. 8    888 .d88b     db    888b. .d88b 8   8 Yb  dP
    8P  Y8 8     8  8P www   dPYb   8  .8 8P    8www8  YbdP
    8b  d8 8     8  8b  d8  dPwwYb  8wwK' 8b    8   8   YP
    `Y88P' 8888 888 `Y88P' dP    Yb 8  Yb `Y88P 8   8   88
            '';
            
            # Add custom links
            customLinks = [
              { name = "📚 Documentation"; url = "https://nixos.org/manual/nixos/stable/"; }
              { name = "🚀 Your Project"; url = "https://yourwebsite.com"; }
              { name = "💬 Support"; url = "https://discourse.nixos.org/"; }
              { name = "📦 Package Search"; url = "https://search.nixos.org/"; }
            ];
            
            # Custom tips
            tips = [
              "Welcome to your new NixOS system!"
              "Check out the documentation for more information"
              "Run 'nixos-rebuild switch' to apply changes"
              "Use 'nix-shell' for temporary development environments"
              "Press 'welcome-tui' to launch the TUI anytime"
              "Use 'nix develop' for flake-based dev shells"
            ];
            
            # Show system information
            showSystemInfo = true;
            
            # Show on login (default shell initialization)
            showOnLogin = true;
            
            # Optional: Add custom bash content (for text mode)
            customContent = ''
              echo -e "\033[1;32mHappy hacking! 🚀\033[0m"
            '';
          };
        }
      ];
    };
  };
}
