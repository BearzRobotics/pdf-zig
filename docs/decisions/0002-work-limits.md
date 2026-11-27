# 0002: Limits on the work an untrusted file can cause

Status: introduced while fixing defects found in a code review; extends decision 7 of 0001.

## Problem

0001 says every loop and recursion has a limit. Several limits counted the wrong
thing: depth where the number of visits grows exponentially, or operators where
the cost is bytes decoded or read again. Small files could exhaust memory, time
or the stack.

## Decision

Each limit counts the quantity that actually costs something, over the whole
operation rather than per nesting level, and is far above what real files need.

- **Load depth** (`document.zig`): at most 32 objects are read from inside one
  another (indirect `/Length`, object streams). Deeper reads give null for that
  chain only and are not cached, so results do not depend on access order.
- **Content scanner resynchronisation** (`content.zig`): after damage, retrying
  from the next byte may re-read at most `4 * length + 64 KiB` bytes. After
  that, scanning resumes where the failed read stopped.
- **Interpreted content** (`interp.Options.max_content_bytes`, 512 MiB per
  page): every run of a stream counts, including each reuse of a form, pattern
  cell or Type 3 glyph. Each distinct stream is decoded once per page and kept
  until the page is done. A page over the limit gives `error.LimitExceeded`.

## Alternatives considered

- Decode into an arena per invocation and free it on return: less memory held at
  once, but the same stream is decompressed again for every glyph.
- Count only operators: misses forms and glyph procedures that are all white
  space or comments.

## Consequences

Peak memory per page is bounded by the distinct streams it runs (at most the
byte budget). A page that legitimately needs more can raise the option.
