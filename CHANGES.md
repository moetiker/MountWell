# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
except that the first subsection is called `New` rather than `Added`. The release
workflow matches on `### New`; renaming it silently drops the section from the
release notes.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### New

### Changed

### Fixed

## 0.0.3 - 2026-10-28
### Changed
- The window is as tall as the shares need, up to four; with more, the list scrolls.
- The log opens and closes like a drawer, and the window grows and shrinks with it.
- The update dialog shows release notes as plain text, without Markdown marks.

## 0.0.2 - 2026-10-28
### New
- Eject a share by hand from its card, its context menu or the menu bar. Mountwell leaves an ejected share alone until you mount it again or leave the network.
- Mount a reachable share right away, also when Automatic is off.

### Changed
- The Automatic switch in the toolbar is smaller.

### Fixed
- A host name that is the end of another one, such as `example.com` and `fileserver.example.com`, no longer counts as mounted.

## 0.0.1 - 2026-10-28
### New
- First release: mounts SMB shares while their server is reachable and unmounts them when it is not, with a configuration app, a menu bar icon, an installer package and updates from GitHub Releases. English and German UI.
