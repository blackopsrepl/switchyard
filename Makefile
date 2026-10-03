PREFIX ?= $(HOME)/.local
APP_HOME ?= $(PREFIX)/share/switchyard
BIN_DIR ?= $(PREFIX)/bin

.PHONY: help test check syntax lint install-user uninstall

help:
	@printf '%s\n' \
		'switchyard targets:' \
		'  test                Run Ruby tests' \
		'  syntax              Ruby -wc over bin, lib and test' \
		'  lint                qmllint the QuickShell panel' \
		'  check               Syntax, tests, and config validation' \
		'  install-user        Install app under ~/.local and wire the Omarchy keybinding' \
		'  uninstall           Remove the installed app, link and keybinding'

test:
	ruby -Itest test/run.rb

# rg is required and its absence fails the gate rather than silently skipping the
# syntax check. Each file is checked on its own: `ruby -wc a.rb b.rb` only ever
# checks the FIRST file, so passing the whole list as one invocation would leave
# every other file unchecked.
syntax:
	@command -v rg >/dev/null || { echo "switchyard: ripgrep (rg) is required"; exit 1; }
	@files="$$(rg --files bin lib test -g '*.rb')"; \
	test -n "$$files" || { echo "switchyard: no Ruby files found to check"; exit 1; }; \
	failed=0; \
	for file in $$files; do \
	  ruby -wc "$$file" >/dev/null 2>&1 || { echo "switchyard: syntax error in $$file"; ruby -wc "$$file" >&2 || true; failed=1; }; \
	done; \
	test "$$failed" -eq 0

# qmllint can only resolve the Quickshell ShellRoot type where Quickshell is
# installed. With no usable import paths it warns on everything and exits
# non-zero on a clean panel, so this target is local-only and CI asserts the
# panel's structure through test/panel_test.rb instead.
lint:
	@command -v qmllint >/dev/null || { echo "switchyard: qmllint is required (qt6-declarative-dev-tools)"; exit 1; }
	qmllint frontend/quickshell/shell.qml

check: syntax
	ruby -Itest test/run.rb
	bin/switchyard config validate --config /dev/null

install-user:
	mkdir -p "$(APP_HOME)" "$(BIN_DIR)"
	cp -R bin lib frontend packaging docs README.md SKILL.md "$(APP_HOME)/"
	[ -f AGENTS.md ] && cp AGENTS.md "$(APP_HOME)/" || true
	ln -sf "$(APP_HOME)/bin/switchyard" "$(BIN_DIR)/switchyard"
	chmod +x "$(APP_HOME)/bin/switchyard"
	"$(APP_HOME)/packaging/install-user.sh"

uninstall:
	"$(APP_HOME)/packaging/uninstall-user.sh" || true
	rm -rf "$(APP_HOME)"
	rm -f "$(BIN_DIR)/switchyard"
