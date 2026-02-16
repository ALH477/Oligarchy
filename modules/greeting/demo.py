#!/usr/bin/env python3
"""
Standalone demo of the NixOS Welcome TUI
Run this to see what the TUI looks like without installing on NixOS
"""

import sys
import os

# Add the tui directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'tui'))

from welcome_tui import WelcomeApp

if __name__ == "__main__":
    print("Starting NixOS Welcome TUI Demo...")
    print("Note: Some system info may be inaccurate on non-NixOS systems\n")
    
    app = WelcomeApp()
    app.run()
