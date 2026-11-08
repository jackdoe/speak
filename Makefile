.PHONY: whisper build run clean app install uninstall benchmark resolve linux linux-model linux-install linux-clean

APP_NAME = Speak
BIN_DIR = $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/arm64-apple-macosx/release)
APP_BUNDLE = .build/$(APP_NAME).app
INSTALL_DIR = /Applications
SIGN_ID ?= -

whisper:
	cd whisper.cpp && cmake -B build -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DGGML_OPENMP=OFF
	cmake --build whisper.cpp/build -j

build: whisper
	swift build -c release

debug:
	swift build

run: debug
	$(shell swift build --show-bin-path 2>/dev/null)/Speak

benchmark:
	swift build -c release --product SpeakBenchmark
	$(BIN_DIR)/SpeakBenchmark

app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources/models"
	@cp "$(BIN_DIR)/Speak" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	@[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/" || true
	@[ -d Resources/models ] && cp Resources/models/*.bin "$(APP_BUNDLE)/Contents/Resources/models/" || true
	@printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	@codesign --force --sign "$(SIGN_ID)" --entitlements Resources/Speak.entitlements --options runtime "$(APP_BUNDLE)"
	@echo ""
	@echo "Built and signed: $(APP_BUNDLE)"
	@echo "  Install: make install"
	@echo "  Run:     open $(APP_BUNDLE)"

install: app
	@echo "Installing to $(INSTALL_DIR)/$(APP_NAME).app..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed. Launch from Applications or Spotlight."

uninstall:
	@echo "Removing $(INSTALL_DIR)/$(APP_NAME).app..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Uninstalled."

resolve:
	swift package resolve

clean:
	swift package clean
	rm -rf .build

HF_BASE = https://huggingface.co/ggerganov/whisper.cpp/resolve/main

models: models-base.en models-medium.en models-large
	@echo ""
	@echo "All models downloaded to Resources/models/"
	@ls -lh Resources/models/*.bin

models-tiny.en:
	@mkdir -p Resources/models
	@echo "Downloading ggml-tiny.en.bin (75 MB)..."
	@curl -L --progress-bar -o Resources/models/ggml-tiny.en.bin "$(HF_BASE)/ggml-tiny.en.bin"

models-base.en:
	@mkdir -p Resources/models
	@echo "Downloading ggml-base.en.bin (142 MB)..."
	@curl -L --progress-bar -o Resources/models/ggml-base.en.bin "$(HF_BASE)/ggml-base.en.bin"

models-small.en:
	@mkdir -p Resources/models
	@echo "Downloading ggml-small.en.bin (466 MB)..."
	@curl -L --progress-bar -o Resources/models/ggml-small.en.bin "$(HF_BASE)/ggml-small.en.bin"

models-medium.en:
	@mkdir -p Resources/models
	@echo "Downloading ggml-medium.en.bin (1.5 GB)..."
	@curl -L --progress-bar -o Resources/models/ggml-medium.en.bin "$(HF_BASE)/ggml-medium.en.bin"

models-large:
	@mkdir -p Resources/models
	@echo "Downloading ggml-large-v3.bin (2.9 GB)..."
	@curl -L --progress-bar -o Resources/models/ggml-large-v3.bin "$(HF_BASE)/ggml-large-v3.bin"

models-large-turbo:
	@mkdir -p Resources/models
	@echo "Downloading ggml-large-v3-turbo.bin (~800 MB)..."
	@curl -L --progress-bar -o Resources/models/ggml-large-v3-turbo.bin "$(HF_BASE)/ggml-large-v3-turbo.bin"

models-large-turbo-q5:
	@mkdir -p Resources/models
	@echo "Downloading ggml-large-v3-turbo-q5_0.bin (547 MB)..."
	@curl -L --progress-bar -o Resources/models/ggml-large-v3-turbo-q5_0.bin "$(HF_BASE)/ggml-large-v3-turbo-q5_0.bin"

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
