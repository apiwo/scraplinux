# Contributing

Pull requests are welcome. I read through everything myself before merging,
so don't take a delay personally — I'm one person.

Package changes go through `ports/manifest.tsv` in
[arctic-linux-ports](https://github.com/apiwo/arctic-linux-ports), not this
repo. Recipes are generated from the manifest; edit that, not the recipe
file, unless the recipe needs a `recipe.local` hand fix.

## TLS

LibreSSL only. Don't add OpenSSL as a dependency, and don't add a package
whose only TLS backend is OpenSSL-specific (the generic OpenSSL-API surface
that LibreSSL also implements is fine).

## Logo

There isn't one yet. If you want to take a shot at it: I want a penguin,
styled like CRUX Linux's penguin mascot, but in different colors and
wearing glasses. Source images (SVG preferred) welcome as a PR.
