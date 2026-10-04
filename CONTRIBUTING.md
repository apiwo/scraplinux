# Contributing

Pull requests are welcome. I read through everything myself before merging,
so don't take a delay personally, I'm one person.

Package changes go to the recipe itself in
[scraplinux-ports](https://github.com/apiwo/scraplinux-ports), at
`ALL/<repo>/<name>/recipe`, not this repo. The recipe is the only source of
truth for a package: name, version, dependencies and how it builds. After
adding or renaming one, regenerate the index with `scraps-repo ports ALL`.

A dependency is what the program needs to run: the libraries it links and
anything it always executes. Companions, like a terminal for a window manager,
go in `recommend=`, which scraps prints after an install and never installs.

## TLS

LibreSSL only. Don't add OpenSSL as a dependency, and don't add a package
whose only TLS backend is OpenSSL-specific (the generic OpenSSL-API surface
that LibreSSL also implements is fine).

## Logo

There isn't one yet. If you want to take a shot at it: I want a penguin,
styled like CRUX Linux's penguin mascot, but in different colors and
wearing glasses. Source images (SVG preferred) welcome as a PR.
