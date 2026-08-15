#!/bin/sh
# sources.list is "name url sha256" - a source with no verified sha256 on
# record never had integrity checking at all (any compromised mirror or MITM
# could swap the tarball silently for glibc/the kernel/etc., the most
# trusted, least-audited things in the whole build). Every fetch, and every
# already-cached file, is checked against it here.
#
# Reads build/sources.list straight from the source tree, not a copy - a
# separate, untracked copy in the build tree could (and did) go stale the
# moment sources.list changed in git without anyone re-copying it, silently
# losing checksums or falling behind on versions with nothing to say so.
: "${ARCTIC_BUILD:=/home/apiwo/arctic-build}"
: "${ARCTIC_TREE:=/home/apiwo/arctic}"
mkdir -p "$ARCTIC_BUILD/src"
cd "$ARCTIC_BUILD/src" || exit 1

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v sha256 >/dev/null 2>&1; then sha256 -q "$1"
  else openssl dgst -sha256 "$1" | sed 's/.*= //'
  fi
}

fail=0
while read -r name url want; do
  [ -n "$name" ] || continue
  if [ -s "$name" ]; then
    if [ -n "$want" ]; then
      got=$(sha256 "$name")
      if [ "$got" != "$want" ]; then
        echo "CHECKSUM MISMATCH $name (expected $want, got $got) - removing"
        rm -f "$name"; fail=1
      else
        echo "have $name (checksum ok)"
      fi
    else
      echo "have $name (no checksum on record)"
    fi
    continue
  fi
  echo "fetch $name"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$name.part" "$url"; then
    echo "FAIL $name"; fail=1; continue
  fi
  if [ -n "$want" ]; then
    got=$(sha256 "$name.part")
    if [ "$got" != "$want" ]; then
      echo "CHECKSUM MISMATCH $name (expected $want, got $got) - discarding"
      rm -f "$name.part"; fail=1; continue
    fi
  fi
  mv "$name.part" "$name"
done < "$ARCTIC_TREE/build/sources.list"
echo "=== FETCH DONE ==="
ls -la
exit $fail
