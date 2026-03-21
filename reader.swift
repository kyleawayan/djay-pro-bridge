#!/usr/bin/env swift
// djay_reader.swift — Polls djay Pro's Accessibility tree for deck info
// Usage: swift djay_reader.swift
// Requires: Accessibility permission granted to Terminal (or whatever runs this)
//   System Settings → Privacy & Security → Accessibility → add Terminal.app

import Cocoa
import ApplicationServices

// MARK: - Find djay Pro's AXUIElement

func findDjayPro() -> AXUIElement? {
				let apps = NSWorkspace.shared.runningApplications
				guard let djay = apps.first(where: { $0.bundleIdentifier?.contains("algoriddim") == true || $0.localizedName?.contains("djay") == true }) else {
								print("❌ djay Pro is not running")
								return nil
				}
				print("✅ Found djay Pro (PID: \(djay.processIdentifier))")
				return AXUIElementCreateApplication(djay.processIdentifier)
}

// MARK: - AX Helpers

func getAttr(_ element: AXUIElement, _ attr: String) -> AnyObject? {
				var value: AnyObject?
				let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
				return result == .success ? value : nil
}

func getChildren(_ element: AXUIElement) -> [AXUIElement] {
				guard let children = getAttr(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
				return children
}

func getRole(_ element: AXUIElement) -> String? {
				return getAttr(element, kAXRoleAttribute) as? String
}

func getLabel(_ element: AXUIElement) -> String? {
				return getAttr(element, kAXDescriptionAttribute) as? String
}

func getValue(_ element: AXUIElement) -> String? {
				return getAttr(element, kAXValueAttribute) as? String
}

func getTitle(_ element: AXUIElement) -> String? {
				return getAttr(element, kAXTitleAttribute) as? String
}

// MARK: - Recursive search for labeled elements

struct DeckInfo {
				var key: String?
				var title: String?
				var artist: String?
				var bpm: String?
}

func findLabeledElements(_ element: AXUIElement, prefix: String, depth: Int = 0) -> [String: String] {
				var results: [String: String] = [:]
				
				let label = getLabel(element) ?? ""
				let value = getValue(element) ?? getTitle(element) ?? ""
				
				// Match elements whose label starts with the prefix (e.g., "Key, Deck 1")
				if !label.isEmpty && label.contains(prefix) && !value.isEmpty {
								results[label] = value
				}
				
				// Recurse into children (limit depth to avoid going too deep)
				if depth < 6 {
								for child in getChildren(element) {
												let childResults = findLabeledElements(child, prefix: prefix, depth: depth + 1)
												results.merge(childResults) { _, new in new }
								}
				}
				
				return results
}

func getDeckInfo(app: AXUIElement, deckNumber: Int) -> DeckInfo {
				let prefix = "Deck \(deckNumber)"
				let allElements = findLabeledElements(app, prefix: prefix)
				
				var info = DeckInfo()
				for (label, value) in allElements {
								let lower = label.lowercased()
								if lower.starts(with: "key,") { info.key = value }
								else if lower.starts(with: "title,") { info.title = value }
								else if lower.starts(with: "artist,") { info.artist = value }
								else if lower.starts(with: "bpm") || lower.contains("tempo") { info.bpm = value }
				}
				return info
}

// MARK: - Main loop

guard let app = findDjayPro() else { exit(1) }

// Check accessibility permission
let checkResult = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, UnsafeMutablePointer<AnyObject?>.allocate(capacity: 1))
if checkResult == .cannotComplete || checkResult == .apiDisabled {
				print("❌ Accessibility permission not granted!")
				print("   Go to: System Settings → Privacy & Security → Accessibility")
				print("   Add Terminal.app (or your terminal emulator)")
				exit(1)
}

print("🎧 Polling djay Pro every 500ms... (Ctrl+C to stop)\n")

var lastDeck1Key = ""
var lastDeck2Key = ""

while true {
				let deck1 = getDeckInfo(app: app, deckNumber: 1)
				let deck2 = getDeckInfo(app: app, deckNumber: 2)
				
				let d1Key = deck1.key ?? "—"
				let d2Key = deck2.key ?? "—"
				
				// Only print when something changes
				if d1Key != lastDeck1Key || d2Key != lastDeck2Key {
								let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
								print("[\(timestamp)]")
								print("  Deck 1: \(deck1.title ?? "—") by \(deck1.artist ?? "—") | Key: \(d1Key)")
								print("  Deck 2: \(deck2.title ?? "—") by \(deck2.artist ?? "—") | Key: \(d2Key)")
								print("")
								
								lastDeck1Key = d1Key
								lastDeck2Key = d2Key
				}
				
				usleep(50_000) // 50ms
}