# FPGA programming via Lattice Radiant Programmer

# -----------------------------------------------------------------------
# User-configurable variables
# -----------------------------------------------------------------------
# File path configuration
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# DEVICE can be empty: the recipe will fallback to LATTICE_DEVICE_NAME from sys_env.xml
DEVICE    ?=
BIT       ?= $(wildcard ./*.bit)
TCK_DELAY ?= 4
CABLE     ?= USB2
PORT      ?= FTUSB-0
XCF_TMPL  ?= $(THIS_DIR)/template.xcf

# -----------------------------------------------------------------------
# Derived paths
# -----------------------------------------------------------------------
# Programmer paths: find pgrcmd from PATH
PGRCMD_BIN = $(shell command -v pgrcmd 2>/dev/null)
PROG_ROOT  = $(if $(strip $(PGRCMD_BIN)),$(shell dirname "$(PGRCMD_BIN)" | xargs dirname | xargs dirname),)

# Programmer-relative paths
XDF        = $(PROG_ROOT)/data/vmdata/database/Jedi/ispVM_027.xdf

# Local paths (Makefile könyvtárában)
OUT_XCF   ?= $(BUILD_DIR)/_out.xcf

# -----------------------------------------------------------------------
# Device lookup from XDF
# -----------------------------------------------------------------------
PROG_INFO_MK := $(BUILD_DIR)/prog_info.tmp

$(PROG_INFO_MK): $(LATTICE_SYS_ENV_VARS)
	$(if $(PROG_ROOT),,$(error 'ERROR: PROG_ROOT is empty (pgrcmd not found in PATH)'))
	$(call print,[Parsing programming info from: $(XDF) to $(PROG_INFO_MK) ...])
	@mkdir -p $(dir $@)
	@tmp="$@.tmp"; rm -f "$$tmp"; \
	{ \
	  . "$(LATTICE_SYS_ENV_VARS)"; \
	  dev_name="$(DEVICE)"; \
	  [ -n "$$dev_name" ] || dev_name="$$LATTICE_DEVICE_NAME"; \
	  [ -n "$$dev_name" ] || { echo "ERROR: device name is empty (set DEVICE or provide LATTICE_DEVICE_NAME in sys_env.xml)"; exit 1; }; \
	  [ -n "$(PGRCMD_BIN)" ] || { echo "ERROR: pgrcmd not found in PATH"; exit 1; }; \
	  [ -f "$(XDF)" ] || { echo "ERROR: XDF not found: $(XDF)"; exit 1; }; \
	  match=$$(awk -v dev="$$dev_name" '\
	    /Family name=/ { \
	      if (match($$0, /name="[^"]*"/)) \
	        fam = substr($$0, RSTART + 6, RLENGTH - 7); \
	    } \
	    index($$0, "Device name=\"" dev "\"") { in_dev = 1; next } \
	    in_dev && /<JtagID>/ { \
	      if (match($$0, /0x[0-9A-Fa-f]+/)) \
	        id = tolower(substr($$0, RSTART, RLENGTH)); \
	      print fam "|" id; \
	      exit; \
	    } \
	    END { if (!in_dev) print "|" } \
	  ' "$(XDF)"); \
	  family=$${match%%|*}; \
	  idcode=$${match#*|}; \
	  printf 'FAMILY=%s\nIDCODE=%s\nDEVICE_NAME=%s\nPON=%s\n' "$$family" "$$idcode" "$$dev_name" "$$dev_name"; \
	} > "$$tmp" && mv -f "$$tmp" "$@" || { rc=$$?; rm -f "$$tmp"; exit $$rc; }

# Convert BIT only on Cygwin; keep as-is on Linux.
IS_CYGWIN = $(filter CYGWIN%,$(shell uname -s 2>/dev/null))
BIT_PATH  = $(if $(IS_CYGWIN),$(if $(BIT),$(shell cygpath -m "$(BIT)"),),$(BIT))
XCF_PATH  = $(if $(IS_CYGWIN),$(if $(OUT_XCF),$(shell cygpath -m "$(abspath $(OUT_XCF))"),),$(OUT_XCF))

PHONY += program check-params

check-params: sys-env sys-env-check $(PROG_INFO_MK)
	$(call print,[Checking parameters for programming from: $(PROG_INFO_MK) ...])
	@. "$(LATTICE_SYS_ENV_VARS)"; \
	. "$(PROG_INFO_MK)"; \
	dev_name="$${DEVICE_NAME:-$$LATTICE_DEVICE_NAME}"; \
	echo "Device  : $$dev_name"; \
	echo "Family  : $$FAMILY"; \
	echo "IDCode  : $$IDCODE"; \
	echo "Bitfile : $(BIT_PATH)"; \
	echo "Cable   : $(CABLE)  Port: $(PORT)"; \
	[ -n "$$FAMILY" ]    || { echo "ERROR: device '$$dev_name' not found in XDF"; exit 1; }; \
	[ -n "$$IDCODE" ]    || { echo "ERROR: IDCode not found for '$$dev_name'"; exit 1; }
	@[ -n "$(BIT)" ]       || (echo "ERROR: no .bit file found (BIT is empty)"; exit 1)
	@[ -n "$(BIT_PATH)" ]  || (echo "ERROR: BIT_PATH is empty (cygpath conversion failed?)"; exit 1)
	@[ -n "$(XCF_PATH)" ]  || (echo "ERROR: XCF_PATH is empty (abspath/cygpath conversion failed?)"; exit 1)
	$(call print,[$(PROG_INFO_MK) OK])

$(OUT_XCF): $(XCF_TMPL) $(BIT) | check-params
	$(call print,[Patching XCF... input: $(XCF_TMPL), output: $(OUT_XCF) ...])
	@cp "$(XCF_TMPL)" "$(OUT_XCF)"
	@. "$(PROG_INFO_MK)"; \
	. "$(LATTICE_SYS_ENV_VARS)"; \
	dev_name="$${DEVICE_NAME:-$$LATTICE_DEVICE_NAME}"; \
	sed -i \
		-e 's|<Family>[^<]*</Family>|<Family>'"$$FAMILY"'</Family>|' \
		-e 's|<Name>[^<]*</Name>|<Name>'"$$dev_name"'</Name>|' \
		-e 's|<IDCode>[^<]*</IDCode>|<IDCode>'"$$IDCODE"'</IDCode>|' \
		-e 's|<PON>[^<]*</PON>|<PON>'"$$PON"'</PON>|' \
		-e 's|<File>[^<]*</File>|<File>$(BIT_PATH)</File>|' \
		-e 's|<TCKDelay>[^<]*</TCKDelay>|<TCKDelay>$(TCK_DELAY)</TCKDelay>|' \
		-e 's|<CableName>[^<]*</CableName>|<CableName>$(CABLE)</CableName>|' \
		-e 's|<PortAdd>[^<]*</PortAdd>|<PortAdd>$(PORT)</PortAdd>|' \
		"$(OUT_XCF)"
	$(call print,[XCF written to: $(OUT_XCF)])

program: $(OUT_XCF)
	@. "$(LATTICE_SYS_ENV_VARS)"; \
	. "$(PROG_INFO_MK)"; \
	dev_name="$${DEVICE_NAME:-$$LATTICE_DEVICE_NAME}"; \
	$(call print,[Downloading $(BIT_PATH) to $$dev_name ...]); \
	pgrcmd -infile "$(XCF_PATH)"
