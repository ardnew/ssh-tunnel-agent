# Makefile for ssh-tunnel-agent

# Installs configuration files and launch agent to appropriate system locations

SHELL := /bin/bash

# Detect OS
UNAME_S := $(shell uname -s)

# Installation directories
HOME_DIR := $(HOME)
XDG_CONFIG_HOME ?= $(HOME_DIR)/.config
CONFIG_BASE := $(if $(XDG_CONFIG_HOME),$(XDG_CONFIG_HOME),$(HOME_DIR)/.local/etc)
CONFIG_DIR := $(CONFIG_BASE)/ssh-tunnel-agent
BIN_DIR := $(HOME_DIR)/.local/bin

# Target paths
CONFIG_TARGET := $(CONFIG_DIR)/config
TMUX_TARGET := $(BIN_DIR)/ssh-tunnel-agent.tmux
PLIST_TARGET := $(HOME_DIR)/Library/LaunchAgents/ssh-tunnel-agent.plist

# Source files
CONFIG_SRC := config
TMUX_SRC := ssh-tunnel-agent.tmux
PLIST_SRC := ssh-tunnel-agent.plist

.PHONY: all install install-config install-tmux install-plist check-path enable clean uninstall help

all: install

help:
	@echo "ssh-tunnel-agent installation targets:"
	@echo ""
	@echo "  make install        - Install all files (default)"
	@echo "  make install-config - Install config file only"
	@echo "  make install-tmux   - Install tmux script only"
	@echo "  make install-plist  - Install launchd plist only (macOS)"
	@echo "  make enable         - Enable LaunchAgent via launchctl (macOS)"
	@echo "  make check-path     - Verify PATH configuration"
	@echo "  make uninstall      - Remove all installed files"
	@echo "  make clean          - Remove temporary files"
	@echo ""

install: install-config install-tmux install-plist check-path
	@echo ""
	@echo "✓ Installation complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Edit $(CONFIG_TARGET) to configure your tunnels"
	@echo "  2. macOS (one-time):"
	@echo "       Load the LaunchAgent: make enable"
	@echo "     Other OS (as-needed):"
	@echo "       Create the tunnel(s): ssh-tunnel-agent.tmux start"
	@echo "  3. Check status: ssh-tunnel-agent.tmux status"
	@echo ""

install-config: $(CONFIG_TARGET)
	@echo "✓ Config installed to: $(CONFIG_TARGET)"

install-tmux: $(TMUX_TARGET)
	@echo "✓ Tmux script installed to: $(TMUX_TARGET)"

install-plist: $(PLIST_TARGET)
	@echo "✓ Launch agent installed to: $(PLIST_TARGET)"

$(CONFIG_TARGET): $(CONFIG_SRC)
	@echo "Installing config file..."
	@mkdir -p "$(CONFIG_DIR)"
	@install -m 644 "$(CONFIG_SRC)" "$(CONFIG_TARGET)"

$(TMUX_TARGET): $(TMUX_SRC)
	@echo "Installing tmux script..."
	@mkdir -p "$(BIN_DIR)"
	@install -m 755 "$(TMUX_SRC)" "$(TMUX_TARGET)"

$(PLIST_TARGET): $(PLIST_SRC) $(TMUX_TARGET)
ifeq ($(UNAME_S),Darwin)
	@echo "Installing launch agent (macOS)..."
	@mkdir -p "$(HOME_DIR)/Library/LaunchAgents"
	@# Create modified plist with correct paths
	@sed -e 's|<string>/usr/local/bin/ssh-tunnel-agent</string>|<string>$(TMUX_TARGET)</string>|' \
	     -e 's|<string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>|<string>$(BIN_DIR):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>|' \
	     "$(PLIST_SRC)" > "$(PLIST_TARGET).tmp"
	@# Add config path to WatchPaths if not already present
	@if ! grep -q "<string>$(CONFIG_TARGET)</string>" "$(PLIST_TARGET).tmp"; then \
	    awk '/<key>WatchPaths<\/key>/ {print; getline; print; print "    <string>$(CONFIG_TARGET)</string>"; next} 1' \
	        "$(PLIST_TARGET).tmp" > "$(PLIST_TARGET).tmp2" && \
	    mv "$(PLIST_TARGET).tmp2" "$(PLIST_TARGET).tmp"; \
	fi
	@mv "$(PLIST_TARGET).tmp" "$(PLIST_TARGET)"
	@chmod 644 "$(PLIST_TARGET)"
else
	@echo "⚠ WARNING: Launch agent installation skipped (not macOS)"
	@echo "  The plist file is only supported on macOS systems."
	@echo "  For automatic startup on other systems, consider using:"
	@echo "    - systemd user services (Linux)"
	@echo "    - cron @reboot entries"
	@echo "    - your init system's user service manager"
endif

check-path:
	@echo "Checking PATH configuration..."
	@if echo "$$PATH" | grep -q "$(BIN_DIR)"; then \
	    echo "✓ $(BIN_DIR) is in your PATH"; \
	else \
	    echo ""; \
	    echo "⚠ WARNING: $(BIN_DIR) is not in your PATH"; \
	    echo ""; \
	    echo "To add it, you can:"; \
	    echo "  1. Add this line to your shell configuration file:"; \
	    echo ""; \
	    if [ -n "$$ZSH_VERSION" ] || [ "$$SHELL" = "/bin/zsh" ]; then \
	        echo "       echo 'export PATH=\"$(BIN_DIR):\$$PATH\"' >> ~/.zshrc"; \
	        echo ""; \
	        echo "  2. Then reload your configuration:"; \
	        echo "       source ~/.zshrc"; \
	        SHELL_RC="$$HOME/.zshrc"; \
	    elif [ -n "$$BASH_VERSION" ] || [ "$$SHELL" = "/bin/bash" ]; then \
	        echo "       echo 'export PATH=\"$(BIN_DIR):\$$PATH\"' >> ~/.bashrc"; \
	        echo ""; \
	        echo "  2. Then reload your configuration:"; \
	        echo "       source ~/.bashrc"; \
	        SHELL_RC="$$HOME/.bashrc"; \
	    else \
	        echo "       export PATH=\"$(BIN_DIR):\$$PATH\""; \
	        echo ""; \
	        echo "     (Add to your shell's configuration file)"; \
	        SHELL_RC=""; \
	    fi; \
	    echo ""; \
	    if [ -n "$$SHELL_RC" ]; then \
	        read -p "Would you like to add $(BIN_DIR) to PATH automatically? [y/N] " -n 1 -r; \
	        echo ""; \
	        if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
	            echo "export PATH=\"$(BIN_DIR):\$$PATH\"" >> "$$SHELL_RC"; \
	            echo "✓ Added to $$SHELL_RC"; \
	            echo "  Run: source $$SHELL_RC"; \
	        fi; \
	    fi; \
	fi

enable:
ifeq ($(UNAME_S),Darwin)
	@if [ ! -f "$(PLIST_TARGET)" ]; then \
	    echo "⚠ Launch agent not installed. Run 'make install' first."; \
	    exit 1; \
	fi
	@echo "Enabling launch agent..."
	@launchctl load -w "$(PLIST_TARGET)"
	@echo "✓ Launch agent enabled and will start automatically at login"
	@echo ""
	@echo "To check status: launchctl list | grep ssh-tunnel-agent"
	@echo "To view logs: tail -f /tmp/ssh-tunnel-agent/launchd-*.log"
else
	@echo "⚠ This target is only available on macOS"
	@exit 1
endif

uninstall:
	@echo "Uninstalling ssh-tunnel-agent..."
ifeq ($(UNAME_S),Darwin)
	@if [ -f "$(PLIST_TARGET)" ]; then \
	    launchctl unload "$(PLIST_TARGET)" 2>/dev/null || true; \
	    rm -f "$(PLIST_TARGET)"; \
	    echo "✓ Removed launch agent"; \
	fi
endif
	@rm -f "$(TMUX_TARGET)"
	@echo "✓ Removed tmux script"
	@if [ -f "$(CONFIG_TARGET)" ]; then \
	    read -p "Remove config file $(CONFIG_TARGET)? [y/N] " -n 1 -r; \
	    echo ""; \
	    if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
	        rm -f "$(CONFIG_TARGET)"; \
	        rmdir "$(CONFIG_DIR)" 2>/dev/null || true; \
	        echo "✓ Removed config file"; \
	    else \
	        echo "  Kept config file"; \
	    fi; \
	fi
	@echo "✓ Uninstall complete"

clean:
	@rm -f "$(PLIST_TARGET).tmp" "$(PLIST_TARGET).tmp2"
	@echo "✓ Cleaned temporary files"

.PHONY: show-paths
show-paths:
	@echo "Environment:"
	@echo "  OS:               $(UNAME_S)"
	@echo "  HOME:             $(HOME_DIR)"
	@echo "  XDG_CONFIG_HOME:  $(XDG_CONFIG_HOME)"
	@echo "Installation paths:"
	@echo "  config:           $(CONFIG_TARGET)"
	@echo "  tmux script:      $(TMUX_TARGET)"
	@echo "  LaunchAgent:      $(PLIST_TARGET)"
