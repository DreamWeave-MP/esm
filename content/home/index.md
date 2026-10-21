+++
title = "esm"
description = "Morrowind and OpenMW plugins and saves, the ESM record stream, read and written raw-preserving, as a Jess package in Luau."
date = 2026-10-21

[taxonomies]
tags = ["Jess", "Luau", "OpenMW"]

[extra]
sections = ["overview", "releases", "credits"]
+++

Morrowind and OpenMW plugins and saves, the ESM record stream, read and written raw-preserving, as a Jess package in Luau.

<!-- more -->

A [Jess](https://github.com/DreamWeave-MP/jess) package, `org.dreamweave.esm`. Add it to a `jess.toml` and
`jess workspace sync` pins it from this site:

```toml
[dependencies]
"org.dreamweave.esm" = "0.1"
```

Every release below is the package's own archive, with its content digest beside the archive's
SHA-256; `jess.lock` pins the first and checks both.
