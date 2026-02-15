{ config, pkgs, lib, theme ? {}, ... }:

{
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "eza -la --icons --git";
      ls = "eza --icons";
      la = "eza -a --icons";
      lt = "eza --tree --icons --level=2";
      cat = "bat";
      grep = "rg";
      ".." = "cd ..";
      "..." = "cd ../..";
      rebuild = "sudo nixos-rebuild switch --flake .";
      rebuild-test = "sudo nixos-rebuild test --flake .";
      nix-clean = "sudo nix-collect-garbage -d";
      dps = "docker ps --format 'table {{.Names}}\t{{.Status}}'";
      dpa = "docker ps -a --format 'table {{.Names}}\t{{.Status}}'";
      ports = "ss -tulanp";
      myip = "curl -s ifconfig.me";
    };
    
    initExtra = ''
      # ══════════════════════════════════════════════════════════════════════════
      # DeMoD Terminal Configuration - Theme-Aware
      # ══════════════════════════════════════════════════════════════════════════
      
      # Load theme colors from JSON (runtime theme switching support)
      load_theme_colors() {
        local theme_file="$HOME/.config/demod/theme.json"
        if [[ -f "$theme_file" ]]; then
          local accent=$(jq -r '.accent // "#00F5D4"' "$theme_file")
          local text=$(jq -r '.text // "#FFFFFF"' "$theme_file")
          local dim=$(jq -r '.textDim // "#808080"' "$theme_file")
          local purple=$(jq -r '.purple // "#8B5CF6"' "$theme_file")
          local green=$(jq -r '.success // "#39FF14"' "$theme_file")
          
          # Convert hex to RGB for terminal escape codes
          hex_to_rgb() {
            local hex=$1
            printf "%d;%d;%d" "0x${hex:1:2}" "0x${hex:3:2}" "0x${hex:5:2}"
          }
          
          CYAN=$(printf '\033[38;2;%sm' "$(hex_to_rgb "$accent")")
          VIOLET=$(printf '\033[38;2;%sm' "$(hex_to_rgb "$purple")")
          GREEN=$(printf '\033[38;2;%sm' "$(hex_to_rgb "$green")")
          WHITE=$(printf '\033[38;2;%sm' "$(hex_to_rgb "$text")")
          DIM=$(printf '\033[38;2;%sm' "$(hex_to_rgb "$dim")")
          RESET=$'\033[0m'
        else
          # Fallback to DeMoD default colors
          CYAN=$'\033[38;2;0;245;212m'
          VIOLET=$'\033[38;2;139;92;246m'
          GREEN=$'\033[38;2;57;255;20m'
          WHITE=$'\033[38;2;255;255;255m'
          DIM=$'\033[38;2;128;128;128m'
          RESET=$'\033[0m'
        fi
      }
      
      load_theme_colors
      
      # Clean prompt with theme colors
      PS1="\[''${CYAN}\]╭─\[''${VIOLET}\][\[''${WHITE}\]\u\[''${CYAN}\]@\[''${WHITE}\]\h\[''${VIOLET}\]]\[''${RESET}\] \[''${GREEN}\]\w\[''${RESET}\]\n\[''${CYAN}\]╰─\[''${VIOLET}\]▶\[''${RESET}\] "
      
      # History configuration
      HISTSIZE=50000
      HISTFILESIZE=100000
      HISTCONTROL=ignoreboth:erasedups
      shopt -s histappend
      
      # Shell options
      shopt -s cdspell autocd dirspell checkwinsize
      
      # FZF integration
      command -v fzf &>/dev/null && eval "$(fzf --bash)"
      
      # Reload theme colors on theme switch (for theme-switch.sh)
      reload_theme() {
        load_theme_colors
        PS1="\[''${CYAN}\]╭─\[''${VIOLET}\][\[''${WHITE}\]\u\[''${CYAN}\]@\[''${WHITE}\]\h\[''${VIOLET}\]]\[''${RESET}\] \[''${GREEN}\]\w\[''${RESET}\]\n\[''${CYAN}\]╰─\[''${VIOLET}\]▶\[''${RESET}\] "
      }
      
      # Welcome message (only for first login)
      if [[ -z "$SSH_CONNECTION" ]] && [[ ! -f "$HOME/.config/welcome-shown" ]]; then
        touch "$HOME/.config/welcome-shown"
        echo ""
        echo -e "''${CYAN}  ╔══════════════════════════════════════════╗''${RESET}"
        echo -e "''${CYAN}  ║''${RESET}  ''${VIOLET}󰎚''${RESET}  ''${WHITE}DeMoD Workstation''${RESET}                   ''${CYAN}║''${RESET}"
        echo -e "''${CYAN}  ║''${RESET}  ''${DIM}Turquoise • Violet • Abstract''${RESET}          ''${CYAN}║''${RESET}"
        echo -e "''${CYAN}  ╚══════════════════════════════════════════╝''${RESET}"
        echo ""
      fi
    '';
  };
}
