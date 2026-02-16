# DSP Company Example Configuration

Example configuration for a Digital Signal Processing company workstation.

## Configuration

```nix
{
  description = "DSP Company Development Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    greeting.url = "github:yourcompany/nixos-greeting";
  };

  outputs = { self, nixpkgs, greeting }: {
    nixosConfigurations.dsp-workstation = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        greeting.nixosModules.greeting
        {
          services.userGreeting = {
            enable = true;
            
            # Launch TUI on startup for interactive experience
            tui = {
              enable = true;
              launchOnStartup = true;
            };
            
            # Company branding
            asciiArt = ''
    .d88b. 8    888 .d88b     db    888b. .d88b 8   8 Yb  dP
    8P  Y8 8     8  8P www   dPYb   8  .8 8P    8www8  YbdP
    8b  d8 8     8  8b  d8  dPwwYb  8wwK' 8b    8   8   YP
    `Y88P' 8888 888 `Y88P' dP    Yb 8  Yb `Y88P 8   8   88
    
                DSP Development Workstation
            '';
            
            welcomeMessage = "Welcome to the DSP Development Environment! 🎧";
            
            # DSP-specific links
            customLinks = [
              # Internal resources
              { name = "🏢 Company Wiki"; url = "https://wiki.yourcompany.com"; }
              { name = "📊 JIRA Dashboard"; url = "https://jira.yourcompany.com"; }
              { name = "💻 GitLab"; url = "https://gitlab.yourcompany.com"; }
              { name = "📞 On-Call Schedule"; url = "https://oncall.yourcompany.com"; }
              
              # DSP resources
              { name = "🎵 DSP Guide"; url = "https://dspguide.com"; }
              { name = "📚 FAUST Docs"; url = "https://faust.grame.fr"; }
              { name = "🔧 Audio Plugin Dev"; url = "https://juce.com/learn/documentation"; }
            ];
            
            # DSP development tips
            tips = [
              "Audio tools installed: Run 'qjackctl' to start JACK audio server"
              "Build DSP modules: Use 'nix develop .#dsp' for dev environment"
              "Run tests before commit: 'nix flake check' validates everything"
              "FAUST compiler available: 'faust2jaqt myfile.dsp' to build"
              "Python DSP: scipy, numpy, librosa all available in dev shell"
              "Check latency: 'cat /proc/asound/card*/pcm*/sub*/hw_params'"
              "Real-time priority: Your user is in 'audio' group for RT scheduling"
              "Plugin validation: Run 'pluginval' on new VST/AU builds"
              "Remember: Commit early, commit often, push before EOD"
              "Daily standup at 10am - check Slack for meeting link"
            ];
            
            showSystemInfo = true;
            
            # Custom content for DSP devs
            customContent = ''
              # Check if JACK is running
              if pgrep -x "jackd" > /dev/null; then
                echo -e "\033[1;32m✓ JACK Audio Server is running\033[0m"
              else
                echo -e "\033[1;33m⚠ JACK Audio Server not running - run 'qjackctl' to start\033[0m"
              fi
              
              # Show active audio devices
              if command -v aplay &> /dev/null; then
                AUDIO_DEVICES=$(aplay -l 2>/dev/null | grep -c "^card")
                if [ "$AUDIO_DEVICES" -gt 0 ]; then
                  echo -e "Audio devices detected: $AUDIO_DEVICES"
                fi
              fi
              
              # Check for pending PRs (example)
              if [ -d "$HOME/projects" ]; then
                echo -e "\033[1;36m📁 Active projects in ~/projects/\033[0m"
              fi
              
              echo ""
              echo -e "\033[1;35m🎧 Ready to process some signals! 🎧\033[0m"
            '';
          };
        }
      ];
    };
  };
}
```

## Features for DSP Development

This configuration includes:

### 🎵 Audio-Specific Tips
- JACK audio server status
- Audio device detection
- Real-time scheduling reminders
- Plugin development workflows
- Latency checking commands

### 🔗 Industry Resources
- DSP educational materials
- FAUST language documentation
- Audio plugin frameworks (JUCE)
- Internal company tools

### 📊 Development Workflow
- Git/JIRA integration reminders
- Build and test automation
- Code review prompts
- Standup meeting reminders

### 🛠️ Tools Integration
- JACK audio server monitoring
- Audio device enumeration
- Project directory awareness
- Real-time priority checks

## Additional Packages to Consider

Add these to your NixOS configuration for a complete DSP environment:

```nix
{
  environment.systemPackages = with pkgs; [
    # Audio frameworks
    jack2
    qjackctl
    pipewire
    
    # DSP languages & compilers
    faust
    supercollider
    csound
    
    # Audio plugins & tools
    helm
    vital
    distrho
    carla
    
    # Analysis tools
    audacity
    sonic-visualiser
    
    # Development
    python311Packages.scipy
    python311Packages.numpy
    python311Packages.librosa
    python311Packages.matplotlib
    
    # Plugin development
    juce
    steinberg-vst3sdk
  ];
  
  # Real-time audio group
  users.users.yourname.extraGroups = [ "audio" "jackaudio" ];
  
  # JACK configuration
  services.jack = {
    jackd.enable = true;
    alsa.enable = false;
  };
}
```

## VSCode/Editor Integration

Add this to help with DSP development in your editor:

```nix
{
  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      ms-python.python
      ms-vscode.cpptools
      # Add DSP-specific extensions
    ];
  };
}
```

## Customization for Team Members

Different greeting messages for different roles:

```nix
# For senior engineers
services.userGreeting.tips = [
  "Review open PRs: https://gitlab.yourcompany.com/merge_requests"
  "Architecture review meeting Thursday 2pm"
  "Remember to update the DSP wiki with new findings"
];

# For new hires
services.userGreeting.tips = [
  "New to the team? Check the onboarding guide on the wiki"
  "Ask questions in #engineering-help Slack channel"
  "Setup guide: https://wiki.yourcompany.com/onboarding"
];
```

## Legal Compliance Note

Since you handle legal too, add compliance reminders:

```nix
services.userGreeting.customContent = ''
  echo -e "\033[1;33m⚖️  Reminder: All audio samples must have proper licensing\033[0m"
  echo -e "\033[1;33m📝 Document any third-party DSP algorithms used\033[0m"
'';
```
