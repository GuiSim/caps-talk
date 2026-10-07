#!/usr/bin/env swift
import AppKit

// Finder custom icons update metadata without changing the signed executable.
guard CommandLine.arguments.count == 3,
      let icon = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Usage: swift scripts/apply-finder-icon.swift ICON APP\n", stderr)
    exit(1)
}
guard NSWorkspace.shared.setIcon(icon, forFile: CommandLine.arguments[2], options: []) else {
    fputs("Could not apply the Finder icon.\n", stderr)
    exit(1)
}
