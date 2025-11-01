#!/usr/bin/env python3
import curses
import json
import os
import re

def validate_json_input(value):
    """Validate if input can be parsed as JSON (string, number, boolean, array, or object)."""
    try:
        # Handle quoted strings
        if value.startswith('"') and value.endswith('"'):
            return value[1:-1]  # Return unquoted string
        # Handle numbers
        if re.match(r'^-?\d+(\.\d+)?$', value):
            return float(value) if '.' in value else int(value)
        # Handle booleans
        if value.lower() in ['true', 'false']:
            return value.lower() == 'true'
        # Handle arrays or objects
        return json.loads(value)
    except json.JSONDecodeError:
        return value  # Treat as string if JSON parsing fails

def edit_config(stdscr, config, file_path):
    """Main TUI for editing HydraMesh config.json."""
    curses.start_color()
    curses.init_pair(1, curses.COLOR_GREEN, curses.COLOR_BLACK)  # Success
    curses.init_pair(2, curses.COLOR_RED, curses.COLOR_BLACK)    # Error
    curses.use_default_colors()
    curses.curs_set(1)
    current_row = 0
    sections = list(config.keys())
    status_msg = ""
    status_color = 0

    while True:
        stdscr.clear()
        stdscr.addstr(0, 0, "HydraMesh Config Editor", curses.A_BOLD)
        stdscr.addstr(1, 0, "Use UP/DOWN to navigate, ENTER to edit, s to save, q to quit", curses.A_DIM)
        stdscr.addstr(2, 0, "Config file: {}".format(file_path), curses.A_DIM)
        for idx, section in enumerate(sections):
            if idx == current_row:
                stdscr.addstr(idx + 4, 0, f"> {section}", curses.A_REVERSE)
            else:
                stdscr.addstr(idx + 4, 0, f"  {section}")
        if status_msg:
            stdscr.addstr(len(sections) + 5, 0, status_msg, curses.color_pair(status_color))
        stdscr.refresh()
        key = stdscr.getch()
        if key == ord('q'):
            stdscr.addstr(len(sections) + 5, 0, "Discard changes? (y/n): ", curses.A_BOLD)
            stdscr.refresh()
            if stdscr.getch() == ord('y'):
                break
        elif key == ord('s'):
            stdscr.addstr(len(sections) + 5, 0, "Save changes? (y/n): ", curses.A_BOLD)
            stdscr.refresh()
            if stdscr.getch() == ord('y'):
                try:
                    with open(file_path, 'w') as f:
                        json.dump(config, f, indent=4)
                    status_msg = "Config saved successfully!"
                    status_color = 1
                except Exception as e:
                    status_msg = f"Error saving config: {str(e)}"
                    status_color = 2
                stdscr.addstr(len(sections) + 5, 0, status_msg, curses.color_pair(status_color))
                stdscr.refresh()
                curses.napms(2000)
        elif key == curses.KEY_UP and current_row > 0:
            current_row -= 1
        elif key == curses.KEY_DOWN and current_row < len(sections) - 1:
            current_row += 1
        elif key == curses.KEY_ENTER or key in [10, 13]:
            status_msg, status_color = edit_section(stdscr, config, sections[current_row])
        else:
            status_msg = "Invalid key. Use UP/DOWN, ENTER, s, q."
            status_color = 2

def edit_section(stdscr, config, section):
    """Edit a specific section of the config."""
    current_row = 0
    keys = list(config[section].keys())
    status_msg = ""
    status_color = 0
    while True:
        stdscr.clear()
        stdscr.addstr(0, 0, f"Editing Section: {section}", curses.A_BOLD)
        stdscr.addstr(1, 0, "Use UP/DOWN to navigate, ENTER to edit value, q to back", curses.A_DIM)
        for idx, key in enumerate(keys):
            value = config[section][key]
            display_value = json.dumps(value, ensure_ascii=False)[:50]  # Truncate for display
            if idx == current_row:
                stdscr.addstr(idx + 3, 0, f"> {key}: {display_value}", curses.A_REVERSE)
            else:
                stdscr.addstr(idx + 3, 0, f"  {key}: {display_value}")
        if status_msg:
            stdscr.addstr(len(keys) + 4, 0, status_msg, curses.color_pair(status_color))
        stdscr.refresh()
        key = stdscr.getch()
        if key == ord('q'):
            return "", 0
        elif key == curses.KEY_UP and current_row > 0:
            current_row -= 1
        elif key == curses.KEY_DOWN and current_row < len(keys) - 1:
            current_row += 1
        elif key == curses.KEY_ENTER or key in [10, 13]:
            stdscr.addstr(len(keys) + 4, 0, f"Enter new value for {keys[current_row]} (JSON format, e.g., \"string\", 123, true, [1,2]): ")
            curses.echo()
            new_value = stdscr.getstr(len(keys) + 4, len(keys[current_row]) + 28, 60).decode()
            curses.noecho()
            try:
                config[section][keys[current_row]] = validate_json_input(new_value)
                status_msg = f"Updated {keys[current_row]} successfully!"
                status_color = 1
            except Exception as e:
                status_msg = f"Error updating {keys[current_row]}: {str(e)}
