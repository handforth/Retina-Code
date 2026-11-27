# rules.mk — second Makefile sample (detected via the .mk extension).
# Docker/Go project rules, target-specific vars, grouped targets, and an unterminated define at EOF.

GO          ?= go
GOFLAGS     ?= -trimpath
GOOS        ?= $(shell $(GO) env GOOS)
GOARCH      ?= $(shell $(GO) env GOARCH)
PKG         := github.com/example/app
CMDS        := $(notdir $(wildcard cmd/*))
GIT_SHA     := $(shell git rev-parse --short=12 HEAD 2>/dev/null)
GIT_DIRTY   := $(if $(shell git status --porcelain 2>/dev/null),-dirty)
VERSION     ?= $(or $(shell git describe --tags --abbrev=0 2>/dev/null),v0.0.0)$(GIT_DIRTY)
LDFLAGS     := -s -w \
               -X '$(PKG)/internal/version.Version=$(VERSION)' \
               -X "$(PKG)/internal/version.Commit=$(GIT_SHA)" \
               -X $(PKG)/internal/version.Date=$(shell date -u +%Y-%m-%dT%H:%M:%SZ)
IMAGE       ?= registry.example.com/app
PLATFORMS   := linux/amd64 linux/arm64 darwin/arm64 windows/amd64
COVER_FILE  := coverage.out
TOOLS_DIR   := $(CURDIR)/.tools
GOLANGCI    := $(TOOLS_DIR)/golangci-lint
TEST_FLAGS  ?= -race -count=1
comma       := ,
empty       :=
space       := $(empty) $(empty)

.PHONY: build test cover lint fmt tidy docker release tools $(CMDS)

# Static pattern rule
BINS := $(addprefix bin/,$(CMDS))
$(BINS): bin/%: $(shell find . -name '*.go' -not -path './vendor/*')
	@echo ">> building $* for $(GOOS)/$(GOARCH)"
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $@ ./cmd/$*

$(CMDS): %: bin/%

build: $(BINS)

# Target-specific and pattern-specific variables
test: TEST_FLAGS += -timeout=5m
test:
	$(GO) test $(TEST_FLAGS) ./...

cover: TEST_FLAGS += -coverprofile=$(COVER_FILE) -covermode=atomic
cover: test
	$(GO) tool cover -func=$(COVER_FILE) | tail -n 1
	$(GO) tool cover -html=$(COVER_FILE) -o coverage.html

%.pb.go: CGO_ENABLED = 0
%.pb.go: %.proto
	protoc --go_out=. --go_opt=paths=source_relative $<

# Grouped target (GNU make 4.3+)
gen/a.go gen/b.go &: schema.json
	$(GO) run ./tools/gen -in $< -out gen/

# Double-colon rules
check:: lint
check:: test

lint: $(GOLANGCI)
	$(GOLANGCI) run --timeout=5m ./...

fmt:
	gofmt -s -w $$(git ls-files '*.go' | grep -v '^vendor/')
	@test -z "$$(gofmt -l .)" || { echo "files need formatting"; exit 1; }

tidy:
	$(GO) mod tidy
	git diff --exit-code -- go.mod go.sum

$(GOLANGCI):
	@mkdir -p $(TOOLS_DIR)
	curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh \
		| sh -s -- -b $(TOOLS_DIR) v1.59.1

tools: $(GOLANGCI)

docker:
	docker buildx build \
		--platform $(subst $(space),$(comma),$(filter linux/%,$(PLATFORMS))) \
		--build-arg VERSION=$(VERSION) \
		--build-arg GIT_SHA=$(GIT_SHA) \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		--push .

# Recipe that uses a shell heredoc and make escapes
release: build
	@cat <<-EOF > release-notes.md
	# Release $(VERSION)

	Commit: $(GIT_SHA)
	Built by: $${USER:-ci} on $$(hostname)
	EOF
	@for p in $(PLATFORMS); do \
		os=$${p%/*}; arch=$${p#*/}; \
		ext=$$( [ "$$os" = windows ] && echo .exe ); \
		echo "  -> $$os/$$arch"; \
		GOOS=$$os GOARCH=$$arch $(MAKE) --no-print-directory build GOOS=$$os GOARCH=$$arch; \
		tar -czf dist/app-$(VERSION)-$$os-$$arch.tar.gz -C bin . ; \
	done

# Functions defined with define and used via call
define banner
	@printf '\n\033[1m== %s ==\033[0m\n' "$(1)"
endef

define go-run-tool
$(GO) run $(1)@$(2) $(3)
endef

banner-demo:
	$(call banner,Building $(VERSION))
	$(call go-run-tool,golang.org/x/vuln/cmd/govulncheck,latest,./...)

# Conditionals with complex expressions
ifeq ($(filter $(GOOS),linux darwin),)
  $(warning GOOS=$(GOOS) is not officially supported)
endif

ifneq ($(strip $(GIT_DIRTY)),)
  $(info Working tree is dirty; version will be $(VERSION))
endif

ifeq ($(origin VERSION),command line)
  VERSION_SOURCE := cli
else ifeq ($(origin VERSION),environment)
  VERSION_SOURCE := env
else
  VERSION_SOURCE := git
endif

# Edge cases
weird-target\:with\:colons:
	@echo "escaped colons in target name"

target\ with\ spaces:
	@echo 'escaped spaces'

$(VERSION_SOURCE)-info: ; @echo "inline recipe after semicolon: $@"

recipe-comment:
	# this is passed to the shell, not a make comment, because it starts with a tab
	@echo "hash in recipe: #not-a-comment"
	@echo '$$literal $(VERSION) $${braced}'

empty-recipe: ;

# This define is never terminated, so everything below belongs to it.
define UNTERMINATED_TEMPLATE
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-$(VERSION)
not-a-target:
	echo "not a recipe"
