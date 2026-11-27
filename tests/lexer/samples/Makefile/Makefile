# Makefile lexer stress: variables, $(VAR), ${VAR}, define/endef, recipes with tabs, conditionals
# Comment with 'quotes' and "doubles" and $(not-expanded) and a trailing backslash \
  this line continues the comment

.DEFAULT_GOAL := all
.PHONY: all build test clean install help dist lint
.SUFFIXES:
.SUFFIXES: .c .o
.DELETE_ON_ERROR:
.ONESHELL:
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables --no-builtin-rules

# Variable flavors
CC       ?= gcc
CXX      ?= g++
CFLAGS   := -Wall -Wextra -O2 -std=c17
CFLAGS   += -DVERSION=\"$(VERSION)\" -DBUILD_DATE='"$(shell date +%F)"'
LDFLAGS  =
LDLIBS   = -lm -lpthread
VERSION  := 1.2.3
PREFIX   ?= /usr/local
DESTDIR  ?=
override OPT_LEVEL = 2
export PATH := $(CURDIR)/bin:$(PATH)
unexport SECRET
lazy     = $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
simple  := $(lazy)
appended += more
conditional ?= default value with spaces
shell_assign != echo "computed at parse time"
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
COMMA := ,
HASH := \#
DOLLAR := $$
PERCENT := %

SRC_DIR  := src
OBJ_DIR  := build/obj
BIN_DIR  := build/bin
SRCS     := $(wildcard $(SRC_DIR)/*.c) $(wildcard $(SRC_DIR)/**/*.c)
OBJS     := $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.o,$(SRCS))
DEPS     := $(OBJS:.o=.d)
HEADERS  = ${wildcard include/*.h}
TARGET   := $(BIN_DIR)/app
LIST     := one two three
UPPER    := $(shell echo '$(LIST)' | tr a-z A-Z)
JOINED   := $(subst $(SPACE),$(COMMA),$(LIST))
FIRST    := $(firstword $(LIST))
COUNT    := $(words $(LIST))
FILTERED := $(filter %.c %.h,$(SRCS) $(HEADERS))
SORTED   := $(sort $(LIST) zero)
DIRS     := $(sort $(dir $(OBJS)))
NOTDIRS  := $(notdir $(SRCS))
BASES    := $(basename $(NOTDIRS))
ABS      := $(abspath $(SRC_DIR)) $(realpath .)
FOREACH  := $(foreach x,$(LIST),item-$(x))
IFFUNC   := $(if $(DEBUG),debug,release)
ORFUNC   := $(or $(CUSTOM),$(CC))
ANDFUNC  := $(and $(CC),$(CXX))
ORIGIN   := $(origin CC) $(flavor CFLAGS)
VALUE    := $(value lazy)
NESTED   := $(patsubst %,$(OBJ_DIR)/%,$(notdir $(SRCS:.c=.o)))
CALLED   := $(call greet,World,!)
EVALED   := $(eval DYNAMIC := yes)

# Conditionals
ifeq ($(OS),Windows_NT)
    EXE := .exe
    RM  := del /Q
else ifeq ($(shell uname -s),Darwin)
    EXE :=
    LDFLAGS += -framework CoreFoundation
else
    EXE :=
endif

ifneq "$(DEBUG)" ""
    CFLAGS += -g -O0 -DDEBUG=1
endif

ifdef VERBOSE
    Q :=
else
    Q := @
endif

ifndef CI
    COLOR := \033[1;32m
    RESET := \033[0m
endif

ifeq '$(CC)' 'clang'
    CFLAGS += -Weverything
endif

# Multi-line variable with define/endef
define greet
Hello, $(1)$(2)
endef

define HELP_TEXT
Usage: make [target] [VAR=value]

Targets:
  all       Build everything (default)
  test      Run the test suite
  clean     Remove "build" artifacts
  install   Install to $(PREFIX) — it's safe
endef
export HELP_TEXT

define COMPILE_RULE =
$(OBJ_DIR)/$(1).o: $(SRC_DIR)/$(1).c | $(OBJ_DIR)
	$$(Q)$$(CC) $$(CFLAGS) -c $$< -o $$@
endef

$(foreach src,$(BASES),$(eval $(call COMPILE_RULE,$(src))))

# Rules
all: build

build: $(TARGET)$(EXE)

$(TARGET)$(EXE): $(OBJS) | $(BIN_DIR)
	@echo -e "$(COLOR)Linking$(RESET) $@ from $(words $^) objects"
	$(Q)$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS)

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c $(HEADERS) | $(OBJ_DIR)
	@mkdir -p $(@D)
	$(Q)$(CC) $(CFLAGS) -MMD -MP -Iinclude -c $< -o $@

$(OBJ_DIR) $(BIN_DIR):
	mkdir -p $@

%.txt: %.md ; pandoc $< -o $@

test: build
	@for t in tests/*.sh; do \
		echo "Running $$t"; \
		bash "$$t" || exit 1; \
	done
	$(Q)./$(TARGET) --self-test && echo 'self-test passed'
	-@rm -f core.*  # leading dash ignores errors
	+$(MAKE) -C tests VERBOSE=$(VERBOSE)

lint:
	@command -v clang-tidy >/dev/null || { echo "clang-tidy not found" >&2; exit 1; }
	clang-tidy $(SRCS) -- $(CFLAGS) -Iinclude
	@echo "dollar in shell: $${HOME} and $$(whoami) and `date`"

install: build
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 0755 $(TARGET)$(EXE) "$(DESTDIR)$(PREFIX)/bin/"

dist: VERSION_TAG = v$(VERSION)
dist: clean
	git archive --format=tar.gz --prefix=app-$(VERSION)/ -o app-$(VERSION).tar.gz $(VERSION_TAG)

clean:
	$(RM) -r build *.tar.gz
	@echo "cleaned"

help:
	@echo "$$HELP_TEXT"

print-%:
	@echo '$* = $($*)'

.PRECIOUS: $(OBJ_DIR)/%.o
.SECONDARY:
.INTERMEDIATE: generated.c

-include $(DEPS)
include config.mk
sinclude optional.mk

vpath %.c $(SRC_DIR)
vpath %.h include

$(info Building version $(VERSION) with $(CC))
$(warning This is a warning with a "quote")
ifeq ($(VERSION),)
$(error VERSION must be set)
endif
