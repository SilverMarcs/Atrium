#!/bin/bash
xcodebuild -project Atrium.xcodeproj -scheme Atrium -destination 'generic/platform=macOS' -configuration Release archive -archivePath /tmp/Atrium.xcarchive && cp -R /tmp/Atrium.xcarchive/Products/Applications/*.app ~/Downloads/ && rm -rf /tmp/Atrium.xcarchive
