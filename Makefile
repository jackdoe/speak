.PHONY: build app install uninstall model clean linux linux-model linux-install linux-clean

APP_NAME = Speak
BIN_DIR = $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/arm64-apple-macosx/release)
APP_BUNDLE = .build/$(APP_NAME).app
INSTALL_DIR = /Applications
SIGN_ID ?= -

MODEL_REPO = FluidInference/parakeet-tdt-0.6b-v2-coreml
MODEL_REVISION = ee09c569f73759e6d44c9bd16766f477b2b36d39
MODEL_FILES = Preprocessor.mlmodelc Encoder.mlmodelc Decoder.mlmodelc JointDecision.mlmodelc parakeet_vocab.json
MODEL_DIR = $(HOME)/Library/Application Support/Speak/parakeet-tdt-0.6b-v2-coreml

build:
	swift build -c release

app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BIN_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	@cp Resources/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/"
	@codesign --force --sign "$(SIGN_ID)" --entitlements Resources/Speak.entitlements --options runtime "$(APP_BUNDLE)"
	@echo "Built and signed: $(APP_BUNDLE)"

install: app model
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME).app"

model:
	@scripts/model.sh $(MODEL_REPO) $(MODEL_REVISION) "$(MODEL_DIR)" $(MODEL_FILES)

uninstall:
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf .build

LINUX_BUILD = linux/build
LINUX_MODEL = $(or $(XDG_DATA_HOME),$(HOME)/.local/share)/speak/parakeet-tdt-0.6b-v2
LINUX_MODEL_URL = https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-fp16.tar.bz2
LINUX_MODEL_SHA256 = 37f67a1a6c942dae27d345ee395fbd19e25ee48996faf70fca25779026054cf0

linux:
	cmake -S linux -B $(LINUX_BUILD)
	cmake --build $(LINUX_BUILD) -j$$(nproc)

linux-model: $(LINUX_MODEL)/tokens.txt

$(LINUX_MODEL)/tokens.txt:
	@mkdir -p $(LINUX_MODEL)
	curl -L --progress-bar -o $(LINUX_MODEL).tar.bz2 $(LINUX_MODEL_URL)
	echo "$(LINUX_MODEL_SHA256)  $(LINUX_MODEL).tar.bz2" | sha256sum -c
	tar xjf $(LINUX_MODEL).tar.bz2 -C $(LINUX_MODEL) --strip-components=1 --exclude=test_wavs
	rm $(LINUX_MODEL).tar.bz2

linux-install: linux linux-model
	cmake --install $(LINUX_BUILD) --prefix $(HOME)/.local --component speak

linux-clean:
	rm -rf $(LINUX_BUILD)
