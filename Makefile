# Build output stays out of iCloud: everything lands under ~/Library/Developer/SiverSol-DerivedData.
DD      := $(HOME)/Library/Developer/SiverSol-DerivedData
SPM     := $(DD)/spm
PKG     := Packages/SiverKit
# XcodeGen from PATH if present, else a copy built from source under the DerivedData folder.
XCODEGEN ?= $(shell command -v xcodegen || echo $(DD)/tools/XcodeGen/.build/release/xcodegen)
REL_SRC := /private/tmp/siversol/release-src
REL_DD  := /private/tmp/siversol/release-dd
ARGS    ?= --help

BIN     := $(DD)/bin

.PHONY: test kit ctl gen app app-test install compile-check run install-ctl release
test:           ## core logic tests
	swift test --package-path $(PKG) --scratch-path $(SPM)
kit:            ## build the package
	swift build --package-path $(PKG) --scratch-path $(SPM)
ctl:            ## make ctl ARGS="tail --once"
	@swift run --package-path $(PKG) --scratch-path $(SPM) siversolctl $(ARGS)
install-ctl: kit ## copy siversolctl to a stable place, so long runs survive rebuilds: $(BIN)/siversolctl
	@mkdir -p $(BIN)
	@rm -rf $(BIN)/siversolctl $(BIN)/SiverKit_SiverCore.bundle
	@cp $(SPM)/debug/siversolctl $(BIN)/siversolctl
	@cp -R $(SPM)/debug/SiverKit_SiverCore.bundle $(BIN)/
	@echo "installed $(BIN)/siversolctl"
gen:            ## project.yml -> SiverSol.xcodeproj
	$(XCODEGEN) generate
app: gen        ## signed Debug build (needs DEVELOPMENT_TEAM in project.yml)
	xcodebuild -project SiverSol.xcodeproj -scheme SiverSol -configuration Debug -derivedDataPath $(DD) build
app-test: gen   ## UI tests that need the real views (hosted in the Debug app)
	xcodebuild -project SiverSol.xcodeproj -scheme SiverSol -configuration Debug -derivedDataPath $(DD) test
install: gen    ## Release build with your own signing (Config/Signing.local.xcconfig if present), copied to /Applications in place
	xcodebuild -project SiverSol.xcodeproj -scheme SiverSol -configuration Release -derivedDataPath $(DD) build
	@pkill -x SiverSol || true
	@sleep 1
	@rm -rf /Applications/SiverSol.app
	@ditto $(DD)/Build/Products/Release/SiverSol.app /Applications/SiverSol.app
	@codesign -dv /Applications/SiverSol.app 2>&1 | grep -E 'Identifier|TeamIdentifier|Signature'
compile-check: gen  ## unsigned compile-only check in a throwaway folder; never launch this build
	xcodebuild -project SiverSol.xcodeproj -scheme SiverSol -configuration Debug -derivedDataPath /tmp/siversol/dd-compile-check CODE_SIGNING_ALLOWED=NO build
run:
	open $(DD)/Build/Products/Debug/SiverSol.app
release:        ## public Release: clean export of the tracked files (or of a branch: REF=<branch>), ad-hoc signed, built under /private/tmp, zipped into build/
	@rm -rf $(REL_SRC) $(REL_DD) && mkdir -p $(REL_SRC) build
	@if [ -n "$(REF)" ]; then git archive "$(REF)" | tar -x -C $(REL_SRC); else git ls-files -z | rsync -a --from0 --files-from=- . $(REL_SRC)/; fi
	cd $(REL_SRC) && $(XCODEGEN) generate --quiet && xcodebuild -project SiverSol.xcodeproj -scheme SiverSol -configuration Release \
	  -derivedDataPath $(REL_DD) CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
	  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES COPY_PHASE_STRIP=YES build
	@rm -f build/SiverSol-1.0.zip
	@ditto -c -k --norsrc --noextattr --keepParent $(REL_DD)/Build/Products/Release/SiverSol.app build/SiverSol-1.0.zip
	@shasum -a 256 build/SiverSol-1.0.zip
