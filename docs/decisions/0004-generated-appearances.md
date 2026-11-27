# 0004: Appearances made while rendering

Status: part of stage 1 of `docs/ROADMAP.md`, which the maintainer accepted.

## Problem

An annotation or form field can come without an appearance stream (12.5.5), and a form can
ask the viewer to make its fields' appearances (`NeedAppearances`, 12.7.2). pdf-zig drew
only stored appearances, so such fields looked blank and such marks were missing.

## Decision

A module, `appearance.zig`, makes a form XObject **in memory** for one annotation. The
interpreter draws it as it draws a stored one. The file is not changed.

- **When:** a visible annotation without a normal appearance; and, in a form with
  `NeedAppearances`, a text or choice field with a value, whose stored appearance may be
  out of date. `interp.Options.generate_appearances` turns it off.
- **What:** text, combo and list fields; check boxes and radio buttons; push buttons;
  highlight, underline, squiggly, strike-out, square, circle, line, polygon, polyline,
  ink, free text and note annotations. Signature fields get only their background and
  border: pdf-zig must not draw anything that looks like a signature. Links, stamps,
  carets, attachments and sounds are not drawn, and are still reported in
  `Omissions.no_appearance`.
- **Check marks are drawn as paths**, so they need no ZapfDingbats font.
- **One source for both uses.** Filling a field (`form.zig`) and adding a text box or
  markup (`annot.zig`) build their streams with the same functions.
- **Fonts.** A field uses the font its `/DA` names if that font can write the text, else
  Helvetica. The renderer caches fonts by the address of a direct dictionary, so the
  built-in Helvetica is a constant of the program: an address is never reused for
  something else.
- **Limits.** What is made is interpreted like any content, so it counts toward the
  page's limits. The numbers read from one annotation and the text drawn in one are
  capped, since many annotations can share one large object.

## Consequences

Text extraction now includes the values of fields that had no appearance, as it did for
fields that had one. A generated appearance follows pdf-zig's choices (padding, automatic
size, border); other viewers make their own, so they will not match to the pixel.

## Alternatives

Writing appearances into the file at open would change what the user opened, and needs a
writable, unencrypted file. Leaving it to the viewer would repeat the field and font rules
the library already has.
