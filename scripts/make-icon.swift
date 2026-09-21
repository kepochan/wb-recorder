#!/usr/bin/env swift
// Dessine l'icône de l'app : un disque rouge sur fond sombre arrondi.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
             xRadius: size * 0.22, yRadius: size * 0.22).fill()

NSColor(calibratedRed: 0.90, green: 0.22, blue: 0.24, alpha: 1).setFill()
let diameter = size * 0.46
NSBezierPath(ovalIn: NSRect(x: (size - diameter) / 2, y: (size - diameter) / 2,
                            width: diameter, height: diameter)).fill()

image.unlockFocus()

let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = representation.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon-1024.png"))
print("icon-1024.png écrit")
