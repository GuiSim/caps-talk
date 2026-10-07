#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p .build/tests
# Uses only Command Line Tools: no full Xcode installation or test frameworks required.
swiftc -o .build/tests/CapsTalkTests \
    Sources/CapsTalk/SessionStore.swift \
    Sources/CapsTalk/AudioHardware.swift \
    Sources/CapsTalk/Microphone.swift \
    Sources/CapsTalk/KeyRemapper.swift \
    Sources/CapsTalk/TalkAuthorization.swift \
    Sources/CapsTalk/SessionLock.swift \
    Sources/CapsTalk/StartupCoordinator.swift \
    Tests/CapsTalkTests/KeyMappingTests.swift \
    Tests/CapsTalkTests/MicrophoneTests.swift \
    Tests/CapsTalkTests/RuntimeTests.swift \
    Tests/main.swift
.build/tests/CapsTalkTests
