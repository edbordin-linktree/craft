PREFIX ?= $(HOME)/.local

.PHONY: install uninstall version test

install:
	@mkdir -p $(PREFIX)/bin
	@ln -sf $(CURDIR)/bin/craft $(PREFIX)/bin/craft
	@echo "Installed craft → $(PREFIX)/bin/craft"
	@echo ""
	@echo "Make sure $(PREFIX)/bin is in your PATH:"
	@echo '  export PATH="$(PREFIX)/bin:$$PATH"'
	@echo ""
	@echo "Then run: craft doctor"

uninstall:
	@rm -f $(PREFIX)/bin/craft
	@echo "Removed $(PREFIX)/bin/craft"

version:
	@cat VERSION

test:
	@echo "Running tests..."
	@bash $(CURDIR)/test/test-queue.sh
	@bash $(CURDIR)/test/test-plugins.sh
