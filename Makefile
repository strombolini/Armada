# Armada — common tasks. `make` builds; `make install` builds+installs; `make test` runs unit tests; `make eval` runs the grounded evals.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' | head -1 | tr -d '"')
ifeq ($(IDENTITY),)
IDENTITY := -
endif
APP := build/Build/Products/Release/Armada.app
BIN := /Applications/Armada.app/Contents/MacOS/Armada

.PHONY: build install test eval clean package

build:
	@command -v xcodegen >/dev/null && xcodegen generate >/dev/null || true
	xcodebuild -project Armada.xcodeproj -scheme Armada -configuration Release -derivedDataPath build \
	  CODE_SIGN_IDENTITY="$(IDENTITY)" CODE_SIGNING_ALLOWED=YES build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

install: build
	-pkill -x "Armada"; sleep 1
	rm -rf "/Applications/Armada.app" && cp -R "$(APP)" "/Applications/Armada.app"
	open "/Applications/Armada.app"

test:
	xcodebuild -project Armada.xcodeproj -scheme Armada -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test 2>&1 \
	  | grep -E "error:|failed|Executed .* tests|TEST (SUCCEEDED|FAILED)" | tail -5

eval:
	python3 Tests/run_eval.py --set Tests/eval_set.json
	python3 Tests/run_eval.py --set Tests/eval_dates.json
	python3 Tests/run_eval.py --set Tests/eval_launcher.json

package:
	cd .. && rm -f Armada-package.zip && zip -qr Armada-package.zip Armada -x "Armada/build/*" "Armada/dist/*" "*/.DS_Store" "*/xcuserdata/*"

clean:
	rm -rf build dist
